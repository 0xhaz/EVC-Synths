// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.19;

import {
    VaultSimple,
    SafeTransferLib,
    FixedPointMathLib,
    ERC20,
    IEVC,
    EVCClient
} from "src/helpers/vaults/solmate/VaultSimple.sol";

/**
 * @title VaultSimpleBorrowable
 * @notice This contract extends VaultSimple to add borrowing capabilities
 * @notice In this contract, the EVC is authenticated before any action that may affect the state of the vault or an
 * account. This is done to ensure that if it's EVC calling, the account is correctly authorized and the vault is
 * enabled as a controller if needed. This contract does not take the account health into account when calculating max
 * withdraw and max redeem values. This contract does not implement the interest accrual hence it returns raw values
 * of total borrows and 0 for the interest accumulator in the interest accrual-related functions.
 */
contract VaultSimpleBorrowable is VaultSimple {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    event BorrowCapSet(uint256 newBorrowCap);
    event Borrow(address indexed caller, address indexed owner, uint256 assets);
    event Repay(address indexed caller, address indexed receiver, uint256 assets);

    error BorrowCapExceeded();
    error AccountUnhealthy();
    error OutstandingDebt();

    uint256 public borrowCap;
    uint256 internal _totalBorrowed;
    mapping(address account => uint256 assets) internal owed;

    constructor(
        IEVC _evc,
        ERC20 _asset,
        string memory _name,
        string memory _symbol
    ) VaultSimple(_evc, _asset, _name, _symbol) {}

    /**
     * @notice Sets the borrow cap of the vault
     * @param newBorrowCap The new borrow cap
     */
    function setBorrowCap(
        uint256 newBorrowCap
    ) external onlyOwner {
        borrowCap = newBorrowCap;
        emit BorrowCapSet(newBorrowCap);
    }

    /**
     * @notice Returns the total borrowed assets in the vault
     * @return The total borrowed assets
     */
    function totalBorrowed() public view virtual returns (uint256) {
        (uint256 currentTotalBorrowed,,) = _accrueInterestCalculate();
        return currentTotalBorrowed;
    }

    /**
     * @notice Returns the debt of an account
     * @param account The account to check
     * @return The debt of the account
     */
    function debtOf(
        address account
    ) public view virtual returns (uint256) {
        return _debtOf(account);
    }

    /**
     * @notice Returns the maximum amount that can be withdrawn by an account
     * @dev This function is overridden to take into account the fact that some of the assets may be borrowed
     * @param owner The owner of the assets
     * @return The maximum amount that can be withdrawn
     */
    function maxWithdraw(
        address owner
    ) public view virtual override returns (uint256) {
        uint256 totalAssets = _totalAssets;
        uint256 ownerAssets = _convertToAssets(balanceOf[owner], false);

        return ownerAssets > totalAssets ? totalAssets : ownerAssets;
    }

    /**
     * @notice Returns the maximum amount that can be redeemed by an account
     * @dev This function is overridden to take into account the fact that some of the assets may be borrowed
     * @param owner The owner of the assets
     * @return The maximum amount that can be redeemed
     */
    function maxRedeem(
        address owner
    ) public view virtual override returns (uint256) {
        uint256 totalAssets = _totalAssets;
        uint256 ownerShares = balanceOf[owner];

        return _convertToAssets(ownerShares, false) > totalAssets ? _convertToShares(totalAssets, false) : ownerShares;
    }

    /**
     * @notice Creates a snapshot of the vault state
     * @dev This function is called before any action that may affect the vault's state. Considering that and the fact
     * that this function is only called once per the EVC checks deferred context, it can be also used to accrue
     * interest
     * @return The snapshot of the vault state
     */
    function doCreateVaultSnapshot() internal virtual override returns (bytes memory) {
        (uint256 currentTotalBorrowed,) = _accrueInterest();

        // make total assets and total borrows snapshot
        return abi.encode(_totalAssets, currentTotalBorrowed);
    }

    /**
     * @notice Checks the vault's status
     * @dev This function is called after ny action that may affect the vault's state. Considering that and the fact
     * that this function is only called once per the EVC checks deferred context, it can be also used to accrue
     * interest rate. `IVault.checkVaultStatus` can only be called from the EVC and only while checks are in progress
     * because of the
     * `onlyEVCWithChecksInProgress` modifier. So it can't be called at any other time to reset the snapshot mid-batch.
     * @param oldSnapshot The snapshot of the vault state
     */
    function doCheckVaultStatus(
        bytes memory oldSnapshot
    ) internal virtual override {
        // sanity check in case the snapshot hasn't been taken
        if (oldSnapshot.length == 0) revert SnapshotNotTaken();

        // use the vault status hook to update the interest rate (it should happen only once per transaction)
        // EVC.forgiveVaultStatus check should never be used for this vault, otherwise the interest rate will not be
        // updated
        // this contract doesn't implement the interest accrual, so this function does nothing. Needed for the sake of
        // inheritance
        _updateInterest();

        // validate the vault state here
        (uint256 initialAssets, uint256 initialBorrowed) = abi.decode(oldSnapshot, (uint256, uint256));
        uint256 finalAssets = _totalAssets;
        uint256 finalBorrowed = _totalBorrowed;

        // the supply cap can be implemented here
        if (
            supplyCap != 0 && finalAssets + finalBorrowed > supplyCap
                && finalAssets + finalBorrowed > initialAssets + initialBorrowed
        ) {
            revert SupplyCapExceeded();
        }

        // or the borrow cap can be implemented here
        if (borrowCap != 0 && finalBorrowed > borrowCap && finalBorrowed > initialBorrowed) {
            revert BorrowCapExceeded();
        }
    }

    /**
     * @notice Checks the status of an account
     * @dev This function is called after any action that may affect the account's state
     * @param account The account to check
     * @param collaterals The collaterals of the account
     */
    function doCheckAccountStatus(address account, address[] calldata collaterals) internal view virtual override {
        (, uint256 liabilityValue, uint256 collateralValue) =
            _calculateLiabilityAndCollateral(account, collaterals, true);

        if (liabilityValue > collateralValue) {
            revert AccountUnhealthy();
        }
    }

    /**
     * @notice Disables the controller
     * @dev The controller is only disabled if the account has no debt. If the account has outstanding debt, the
     * function reverts
     */
    function disableController() external virtual override nonReentrant {
        // ensure that the account has no debt before disabling the controller
        address msgSender = _msgSender();
        if (_debtOf(msgSender) == 0) {
            EVCClient.disableController(msgSender);
        } else {
            revert OutstandingDebt();
        }
    }

    /**
     * @notice Retrieves the liability and collateral value of a given account
     * @dev Account status is considered healthy if the collateral value is greater than or equal to the liability
     * @param account The address of the account to retrieve the liability and collateral value for
     * @return liabilityValue The total liability value of the account
     * @return collateralValue The total collateral value of the account
     */
    function getAccountLiabilityStatus(
        address account
    ) external view virtual onlyEVCAccountOwner returns (uint256 liabilityValue, uint256 collateralValue) {
        (, liabilityValue, collateralValue) = _calculateLiabilityAndCollateral(account, getCollaterals(account), false);
    }

    /**
     * @notice Borrows assets from the vault
     * @param assets The amount of assets to borrow
     * @param receiver The address that will receive the borrowed assets
     */
    function borrow(uint256 assets, address receiver) external callThroughEVC nonReentrant {
        address msgSender = _msgSenderForBorrow();

        createVaultSnapshot();

        require(assets != 0, "VaultSimpleBorrowable: zero assets");

        // user might input an EVC subaccount, in which case we want to send tokens to the owner
        // receiver = _getAccountOwner(receiver);

        _increaseOwed(msgSender, assets);

        emit Borrow(msgSender, receiver, assets);

        asset.safeTransfer(receiver, assets);

        _totalAssets -= assets;

        requireAccountAndVaultStatusCheck(msgSender);
    }

    /**
     * @notice Repays the borrowed assets
     * @dev This function transfers the specified amount of assets from the caller to the vault and decreases the debt
     * @param assets The amount of assets to repay
     * @param receiver The address that will receive the repaid assets
     */
    function repay(uint256 assets, address receiver) external callThroughEVC nonReentrant {
        address msgSender = _msgSender();

        // sanity check: the receiver must be under control of the EVC. Otherwise, we allowed to disble this vault
        // as the controller for the account with outstanding debt
        if (!isControllerEnabled(receiver, address(this))) {
            revert ControllerDisabled();
        }

        createVaultSnapshot();

        require(assets != 0, "VaultSimpleBorrowable: zero assets");

        asset.safeTransferFrom(msgSender, address(this), assets);

        _totalAssets += assets;

        _decreaseOwed(receiver, assets);

        emit Repay(msgSender, receiver, assets);

        requireAccountAndVaultStatusCheck(address(0));
    }

    /**
     * @notice Pulls debt from the account
     * @dev This function decreases the debt of the account and increases the total borrowed amount
     * @dev Despite the lack of asset transfers, this function emits the `Repay` event to keep the interface consistent
     * @param from The account to pull the debt from
     * @param assets The amount of assets to pull
     * @return A boolean value that indicates whether the debt was successfully pulled
     */
    function pullDebt(address from, uint256 assets) external callThroughEVC nonReentrant returns (bool) {
        address msgSender = _msgSender();

        // sanity check: tthe account from which the debt is pulled must be under control of the EVC.
        // _msgSenderForBorrow() checks that `msgSender` is controlled by this vault
        if (!isControllerEnabled(from, address(this))) {
            revert ControllerDisabled();
        }

        createVaultSnapshot();

        require(assets != 0, "VaultSimpleBorrowable: zero assets");
        require(msgSender != from, "VaultSimpleBorrowable: self-pull");

        _decreaseOwed(from, assets);
        _increaseOwed(msgSender, assets);

        emit Repay(msgSender, from, assets);
        emit Borrow(msgSender, msgSender, assets);

        requireAccountAndVaultStatusCheck(msgSender);

        return true;
    }

    /**
     * @notice Calculates the liability and collateral value of an account
     * @param account The account to calculate the liability and collateral value for
     * @param collaterals The collaterals of the account
     * @param skipCollateralIfNoLiability A flag indicating whether to skip collateral calculation if the account has no
     * liability
     * @return liabilityAssets The liability assets
     * @return liabilityValue The liability value
     * @return collateralValue The risk-adjusted collateral value
     */
    function _calculateLiabilityAndCollateral(
        address account,
        address[] memory collaterals,
        bool skipCollateralIfNoLiability
    ) internal view virtual returns (uint256 liabilityAssets, uint256 liabilityValue, uint256 collateralValue) {
        liabilityAssets = _debtOf(account);

        if (liabilityAssets == 0 && skipCollateralIfNoLiability) {
            return (0, 0, 0);
        } else if (liabilityAssets > 0) {
            // pricing doesnt matter here, as we are only interested in the value of the collateral
            liabilityValue = liabilityAssets;
        }

        // in this simple example, let's say that it's only possible to borrow against
        // the same asset up to 90% of its value
        for (uint256 i = 0; i < collaterals.length; ++i) {
            if (collaterals[i] == address(this)) {
                // calculate the value of the collateral (e.g 90% of the balance)
                collateralValue = _convertToAssets(balanceOf[account], false) * 9 / 10;
                break;
            }
        }
    }

    /// @dev This function is overridden to take into account the fact that some of the assets may be borrowed
    function _convertToShares(uint256 assets, bool roundUp) internal view virtual override returns (uint256) {
        (uint256 currentTotalBorrowed,,) = _accrueInterestCalculate();

        return roundUp
            ? assets.mulDivUp(totalSupply + 1, _totalAssets + currentTotalBorrowed + 1)
            : assets.mulDivDown(totalSupply + 1, _totalAssets + currentTotalBorrowed + 1);
    }

    /// @dev This function is overridden to take into account the fact that some of the assets may be borrowed
    function _convertToAssets(uint256 shares, bool roundUp) internal view virtual override returns (uint256) {
        (uint256 currentTotalBorrowed,,) = _accrueInterestCalculate();

        return roundUp
            ? shares.mulDivUp(_totalAssets + currentTotalBorrowed + 1, totalSupply + 1)
            : shares.mulDivDown(_totalAssets + currentTotalBorrowed + 1, totalSupply + 1);
    }

    /**
     * @notice Returns the debt of an account
     * @param account The account to check
     * @return The debt of the account
     */
    function _debtOf(
        address account
    ) internal view virtual returns (uint256) {
        return owed[account];
    }

    /**
     * @notice Increases the debt of an account
     * @param account The account to increase the debt for
     * @param assets The amount of assets to increase the debt by
     */
    function _increaseOwed(address account, uint256 assets) internal virtual {
        owed[account] = _debtOf(account) + assets;
        _totalBorrowed += assets;
    }

    /**
     * @notice Decreases the debt of an account
     * @param account The account to decrease the debt for
     * @param assets The amount of assets to decrease the debt by
     */
    function _decreaseOwed(address account, uint256 assets) internal virtual {
        owed[account] = _debtOf(account) - assets;

        uint256 __totalBorrowed = _totalBorrowed;
        _totalBorrowed = __totalBorrowed >= assets ? __totalBorrowed - assets : 0;
    }

    /**
     * @notice Accrues the interest
     * @dev Because this contract does not implement the interest accrual, this function does not need to update the
     * state, but only returns the current value of total borrows and 0 for the interest accumulator. This function is
     * needed so that it can be overriden by child contracts without a need to override other functions which use it.
     * @return The current values of total borrowed and interest accumulator.
     */
    function _accrueInterest() internal virtual returns (uint256, uint256) {
        return (_totalBorrowed, 0);
    }

    /**
     * @notice Calculates the accrued interest
     * @dev Because this contract does not implement interest accrual, this function does not need to calculate the
     * interest, but only returns the current value of total borrows and 0 for the interest accumulator. This function
     * is needed so that it can be overridden by child contracts without a need to override other functions wnich use it
     * @return The total borrowed amount and the interest accumulator
     */
    function _accrueInterestCalculate() internal view virtual returns (uint256, uint256, bool) {
        return (_totalBorrowed, 0, false);
    }

    /// @notice Updates the interest rate
    function _updateInterest() internal virtual {}
}
