// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.19;

import {SafeTransferLib, ERC20} from "solmate/utils/SafeTransferLib.sol";
import {ERC4626} from "solmate/tokens/ERC4626.sol";
import {IEVC} from "evc/interfaces/IEthereumVaultConnector.sol";

/**
 * @title SimpleWithdrawOperator
 * @notice This contract allows anyone, in exchange for a tip, to pull liquidity out
 * of a heavily utilized vault on behalf of someone else. Thanks to this operator,
 * a user can delegate the monitoring of their vault to someone else and go on with their life
 */
contract SimpleWithdrawOperator {
    using SafeTransferLib for ERC20;

    IEVC public immutable evc;

    constructor(
        IEVC _evc
    ) {
        evc = _evc;
    }

    /**
     * @notice Allows anyone to withdraw on behalf of a onBehalfOfAccount from a targetContract
     * @dev Assumes that the onBehalfOfAccount owner had authorized the operator to withdraw on their behalf
     * @param vault the address of the vault
     * @param onBehalfOfAccount the address of the account on behalf of which the operation is to be performed
     */
    function withdrawOnBehalf(address vault, address onBehalfOfAccount) external {
        ERC20 asset = ERC4626(vault).asset();
    }
}
