// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.19;

import {VaultRegularBorrowable, ERC20} from "src/helpers/open-zeppelin/VaultRegularBorrowable.sol";
import {ERC20Mintable} from "src/ERC20/ERC20Mintable.sol";
import {IEVC} from "src/helpers/utils/EVCClient.sol";
import {IIRM} from "src/helpers/interfaces/IIRM.sol";
import {IPriceOracle} from "src/helpers/interfaces/IPriceOracle.sol";
import {console} from "forge-std/console.sol";

/**
 * @title VaultMintable
 * @notice This contract extends the VaultRegularBorrowable contract to add minting functionality
 */
contract VaultMintable is VaultRegularBorrowable {
    constructor(
        IEVC _evc,
        address _asset,
        IIRM _irm,
        IPriceOracle _oracle,
        address _referenceAsset,
        string memory _name,
        string memory _symbol
    ) VaultRegularBorrowable(_evc, ERC20Mintable(_asset), _irm, _oracle, ERC20(_referenceAsset), _name, _symbol) {}

    /**
     * @notice Borrow assets from the vault
     * @param assets The amount of assets to borrow
     * @param receiver The address that will receive the borrowed assets
     */
    function borrow(
        uint256 assets,
        address receiver
    ) external override callThroughEVC nonReentrant onlyEVCAccountOwner {
        address msgSender = _msgSenderForBorrow();

        createVaultSnapshot();

        require(assets != 0, "VaultMintable: cannot borrow 0 assets");

        _increaseOwed(msgSender, assets);

        emit Borrow(msgSender, receiver, assets);

        ERC20Mintable(asset()).mint(receiver, assets);

        requireAccountAndVaultStatusCheck(msgSender);
    }

    /**
     * @notice Repays a debt
     * @dev This function burns the specified amount of assets from the caller's balance
     * @param assets The amount of assets to repay
     * @param receiver The address that will receive the repaid assets
     */
    function repay(uint256 assets, address receiver) external override callThroughEVC nonReentrant {
        address msgSender = _msgSender();

        // sanity check: the receiver must be under control of the EVC. Otherwise, we allowed to disable this vault as
        // the controller for an account with debt
        if (!isControllerEnabled(receiver, address(this))) {
            revert ControllerDisabled();
        }

        createVaultSnapshot();

        require(assets != 0, "VaultMintable: cannot repay 0 assets");

        ERC20Mintable(asset()).burnFrom(msgSender, assets);

        _totalAssets += assets;

        _decreaseOwed(receiver, assets);

        emit Repay(msgSender, receiver, assets);

        requireAccountAndVaultStatusCheck(address(0));
    }
}
