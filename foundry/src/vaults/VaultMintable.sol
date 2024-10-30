// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.19;

import {VaultRegularBorrowable, ERC20} from "src/helpers/open-zeppelin/VaultRegularBorrowable.sol";
import {ERC20Mintable} from "src/ERC20/ERC20Mintable.sol";
import {IEVC} from "src/helpers/utils/EVCClient.sol";
import {IIRM} from "src/helpers/interfaces/IIRM.sol";
import {IPriceOracle} from "src/helpers/interfaces/IPriceOracle.sol";

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
    function borrow(uint256 assets, address receiver) external override callThroughEVC nonReentrant {
        address msgSender = _msgSenderForBorrow();
    }
}
