// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.19;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {IIRM} from "src/helpers/interfaces/IIRM.sol";
import {IPriceOracle} from "src/helpers/interfaces/IPriceOracle.sol";
import {VaultSimple, Math, ERC20, IEVC, IERC20} from "src/helpers/open-zeppelin/VaultSimple.sol";

/**
 * @title VaultRegularBorrowable
 * @notice This contract extends the VaultSimple contract to add borrowing functionality along with interest rate
 * accrual
 * recognition of external collateral vaults and liquidation of undercollateralized accounts
 * @notice In this contract, the EVC is authenticated before any action that may affect the state of the vault of an
 * account
 * This is done to ensure that if it's EVC calling, the account is correctly authorized and the vault is
 * enabled as a controller if needed. This contract does not take the account health into account when calculating max
 * withdraw and max redeem values
 */
contract VaultRegularBorrowable is VaultSimple {
    using Math for uint256;

    uint256 internal constant COLLATERAL_FACTOR_SCALE = 100;
    uint256 internal constant MAX_LIQUIDATION_INCENTIVE = 20;
    uint256 internal constant TARGET_HEALTH_FACTOR = 125;
    uint256 internal constant ONE = 1e27;

    uint256 public borrowCap;
    uint256 internal _totalBorrowed;
    uint96 internal interestRate;
    uint256 internal lastinterestUpdate;
    uint256 internal interestAccumulator;

    mapping(address account => uint256 assets) internal owed;
    mapping(address account => uint256) internal userInterestAccumulator;
    mapping(address asset => uint256) internal collateralFactor;

    // IRM
    IIRM public irm;

    // oracle
    ERC20 public referenceAsset; // this is the asset that we use to calculate the value of all other assets
    IPriceOracle public oracle;

    event BorrowCapSet(uint256 newBorrowCap);
    event Borrow(address indexed caller, address indexed owner, uint256 assets);
    event Repay(address indexed caller, address indexed receiver, uint256 assets);

    error BorrowCapExceeded();
    error AccountUnhealthy();
    error OutstandingDebt();
    error InvalidCollateralFactor();
    error SelfLiquidation();
    error VaultStatusCheckDeferred();
    error ViolatorStatusCheckDeferred();
    error NoLiquidationOpportunity();
    error RepayAssetsInsufficient();
    error RepayAssetsExceeded();
    error CollateralDisabled();

    constructor(
        IEVC _evc,
        IERC20 _asset,
        IIRM _irm,
        IPriceOracle _oracle,
        ERC20 _referenceAsset,
        string memory _name,
        string memory _symbol
    ) VaultSimple(_evc, _asset, _name, _symbol) {
        irm = _irm;
        oracle = _oracle;
        referenceAsset = _referenceAsset;
        lastinterestUpdate = block.timestamp;
        interestAccumulator = ONE;
    }

    /**
     * @notice Sets the borrow cap
     * @param newBorrowCap The new borrow cap
     */
    function setBorrowCap(
        uint256 newBorrowCap
    ) external onlyOwner {
        borrowCap = newBorrowCap;
        emit BorrowCapSet(newBorrowCap);
    }

    /**
     * @notice Sets the IRM of the vault
     * @param newIrm The new IRM
     */
    function setIrm(
        IIRM newIrm
    ) external onlyOwner {
        irm = newIrm;
    }

    /**
     * @notice Sets the price oracle of the vault
     * @param newOracle The new price oracle
     */
    function setOracle(
        IPriceOracle newOracle
    ) external onlyOwner {
        oracle = newOracle;
    }

    /**
     * @notice Sets the collateral factor of an asset
     * @param asset_ The asset
     * @param collateralFactor_ The collateral factor
     */
    function setCollateralFactor(address asset_, uint256 collateralFactor_) external onlyOwner {
        if (collateralFactor_ > COLLATERAL_FACTOR_SCALE) {
            revert InvalidCollateralFactor();
        }

        collateralFactor[asset_] = collateralFactor_;
    }

    /**
     * @notice Gets the current interest rate of the vault
     * @dev Reverts if the vault status check is deferred because the interest rate is calculated in the
     * checkVaultStatus function
     * @return The current interest rate
     */
    function getInterestRate() external view returns (uint256) {
        if (isVaultStatusCheckDeferred(address(this))) {
            revert VaultStatusCheckDeferred();
        }

        return interestRate;
    }

    /**
     * @notice Gets the collateral factor of an asset
     * @param asset The asset
     * @return The collateral factor
     */
    function getCollateralFactor(
        address asset
    ) external view returns (uint256) {
        return collateralFactor[asset];
    }

    /**
     * @notice Returns the total borrowed assets from the vault
     * @return The total borrowed assets from the vault
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
     * @notice Returns the maximum amount of assets that can be withdrawn from the vault
     * @dev This function is overridden to take into account the fact that some of the assets may be borrowed
     * @param owner The account that will receive the assets
     * @return The maximum amount of assets that can be withdrawn from the vault
     */
    function maxWithdraw(
        address owner
    ) public view virtual override returns (uint256) {
        uint256 totalAssets = _totalAssets;
        uint256 ownerAssets = _convertToAssets(balanceOf(owner), Math.Rounding.Floor);

        return ownerAssets > totalAssets ? totalAssets : ownerAssets;
    }

    /**
     * @notice Returns the maximum amount that can be redeemed by an account
     * @dev This function is overridden to take into account the fact that some of the assets may be borrowed
     * @param owner The account that will receive the assets
     * @return The maximum amount that can be redeemed by an account
     */
    function maxRedeem(
        address owner
    ) public view virtual override returns (uint256) {
        uint256 totalAssets = _totalAssets;
        uint256 ownerShares = balanceOf(owner);

        return _convertToAssets(ownerShares, Math.Rounding.Floor) > totalAssets
            ? _convertToShares(totalAssets, Math.Rounding.Floor)
            : ownerShares;
    }

    /// @dev This function is overridden to take into account the fact that some of the assets may be borrowed
    function _convertToShares(
        uint256 assets,
        Math.Rounding rounding
    ) internal view virtual override returns (uint256) {
        (uint256 currentTotalBorrowed,,) = _accrueInterestCalculate();

        return
            assets.mulDiv(totalSupply() + 10 ** _decimalsOffset(), totalAssets() + currentTotalBorrowed + 1, rounding);
    }

    /// @dev This function is overridden to take into account the fact that some of the assets may be borrowed
    function _convertToAssets(
        uint256 shares,
        Math.Rounding rounding
    ) internal view virtual override returns (uint256) {
        (uint256 currentTotalBorrowed,,) = _accrueInterestCalculate();

        return
            shares.mulDiv(totalAssets() + currentTotalBorrowed + 1, totalSupply() + 10 ** _decimalsOffset(), rounding);
    }

    /**
     * @notice Creates a snapshot of the vault
     * @dev This function is called before any action that may affect the vault's state. Considering that and the fact
     * that this function is only called once per the EVC checks deferred context, it can be also used to accrue
     * interest
     * @return A snapshot of the vault's state
     */
    function doCreateVaultSnapshot() internal virtual override returns (bytes memory) {
        (uint256 currentTotalBorrowed,) = _accrueInterest();

        // make total assets and total borrows snapshot
        return abi.encode(_totalAssets, currentTotalBorrowed);
    }

    /**
     * @notice Checks the vault's status
     * @dev This function is called after any action that may affect the vault's state. Considering that and the fact
     * that this function is only called once per the EVC checks deferred context, it can be also used to update the
     * interest rate
     * `IVault.checkVaultStatus` can only be called from the EVC and only while checks are in progress because of the
     * `onlyEVCWithChecksInProgress` modifier.
     * So it can't be called at any other time to reset the snapshot mid-batch.
     * @param oldSnapshot The snapshot of the vault's state before the action
     */
    function doCheckVaultStatus(
        bytes memory oldSnapshot
    ) internal virtual override {
        // sanity check in case the snapshot is not created
        if (oldSnapshot.length == 0) revert SnapshotNotTaken();

        // use the vault status hook to update the interest rate (it should happen only once per transaction).
        // EVC.forgiveVaultStatus check should never be used for this vault, otherwise the interest rate will not be
        // updated.
        // this contract doesn't implement the interest accrual, so this function does nothing. needed for the sake of
        // inheritance
        _updateInterest();

        // validate the vault status
        (uint256 initialAssets, uint256 initialBorrowed) = abi.decode(oldSnapshot, (uint256, uint256));
        uint256 finalAssets = _totalAssets;
        uint256 finalBorrowed = _totalBorrowed;

        // the supply cap can be implemented in the derived contracts
        if (
            supplyCap != 0 && finalAssets + finalBorrowed > supplyCap
                && finalAssets + finalBorrowed > initialAssets + initialBorrowed
        ) {
            revert SupplyCapExceeded();
        }

        // the borrow cap can be implemented in the derived contracts
        if (borrowCap != 0 && finalBorrowed > borrowCap && finalBorrowed > initialBorrowed) {
            revert BorrowCapExceeded();
        }
    }

    /**
     * @notice Checks the status of an account
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
     * @notice Calculates the liability and collateral of an account
     * @param account The account to check
     * @param collaterals The collaterals of the account
     * @param skipCollateralIfNoLiability A flag that indicates whether the collateral should be skipped if there is no
     * liability
     * @return liabilityAssets The liability of the account
     * @return liabilityValue The value of the liability
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
            // calculate the value of the liability in terms of the reference asset
            liabilityValue = IPriceOracle(oracle).getQuote(liabilityAssets, asset(), address(referenceAsset));
        }

        // calculate the aggregated value of the collateral in terms of the reference asset
        for (uint256 i = 0; i < collaterals.length; ++i) {
            address collateral = collaterals[i];
            uint256 cf = collateralFactor[collateral];

            // collaterals with a collateral factor of 0 are not considered
            if (cf != 0) {
                uint256 collateralAssets = ERC20(collateral).balanceOf(account);

                if (collateralAssets > 0) {
                    collateralValue += (
                        IPriceOracle(oracle).getQuote(collateralAssets, collateral, address(referenceAsset)) * cf
                    ) / COLLATERAL_FACTOR_SCALE;
                }
            }
        }
    }

    /**
     * @notice Returns the debt of an account
     * @dev This function is overridden to take into account the interest rate accrual
     * @param account The account to check
     * @return The debt of the account
     */
    function _debtOf(
        address account
    ) internal view virtual returns (uint256) {
        uint256 debt = owed[account];

        if (debt == 0) return 0;

        (, uint256 currentInterestAccumulator,) = _accrueInterestCalculate();

        return debt.mulDiv(currentInterestAccumulator, userInterestAccumulator[account], Math.Rounding.Ceil);
    }

    /**
     * @notice Accrues the interest and updates the total borrowed amount
     * @return The current values of total borrowed and interest accumulator
     */
    function _accrueInterest() internal virtual returns (uint256, uint256) {
        (uint256 currentTotalBorrowed, uint256 currentInterestAccumulator, bool update) = _accrueInterestCalculate();

        if (update) {
            _totalBorrowed = currentTotalBorrowed;
            interestAccumulator = currentInterestAccumulator;
            lastinterestUpdate = block.timestamp;
        }

        return (currentTotalBorrowed, currentInterestAccumulator);
    }

    /**
     * @notice Calculates the accrued interest
     * @return The total borrowed amount, the interest accumulator and a boolean value that indicates whether the data
     * should be updated
     */
    function _accrueInterestCalculate() internal view virtual returns (uint256, uint256, bool) {
        uint256 timeElapsed = block.timestamp - lastinterestUpdate;
        uint256 oldTotalBorrowed = _totalBorrowed;
        uint256 oldInterestAccumulator = interestAccumulator;

        if (timeElapsed == 0) {
            return (oldTotalBorrowed, oldInterestAccumulator, false);
        }

        /// @dev Calculated using FixedPointMathLib.rpow - which computes the power function in fixed-point math
        /// @dev This function uses the following formula:
        /// @dev newInterestAccumulator = (interestRate + 1) ^ timeElapsed * oldInterestAccumulator
        uint256 newInterestAccumulator =
            (FixedPointMathLib.rpow(uint256(interestRate) + ONE, timeElapsed, ONE) * oldInterestAccumulator) / ONE;

        /// @dev adjust the total borrowed amount based on the new interest accumulator using mulDiv with ceiling
        /// rounding
        /// to avoid underestimating the total borrowed amount
        uint256 newTotalBorrowed =
            oldTotalBorrowed.mulDiv(newInterestAccumulator, oldInterestAccumulator, Math.Rounding.Ceil);

        return (newTotalBorrowed, newInterestAccumulator, true);
    }

    /// @notice Updates the interest rate
    function _updateInterest() internal virtual {
        uint256 borrowed = _totalBorrowed;
        uint256 poolAssets = _totalAssets + borrowed;

        uint32 utilization;
        if (poolAssets != 0) {
            utilization = uint32((borrowed * type(uint32).max) / poolAssets);
        }

        interestRate = irm.computeInterestRate(address(this), asset(), utilization);
    }
}
