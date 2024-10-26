// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @dev This is an empty interface used to represent either ERC20-conforming token contracts or ETH
 * (using the zero address sentinel value). We're just relying on the fact that `interface` can be
 * used to declare new address-like types.
 *
 * This concept is unrelated to a Pool's Asset Managers
 */
interface IAsset {
// solhint-disable-previous-line no-empty-blocks
}

struct JoinPoolRequest {
    IAsset[] assets;
    uint256[] maxAmountsIn;
    bytes userData;
    bool fromInternalBalance;
}

enum SwapKind {
    GIVEN_IN,
    GIVEN_OUT
}

/**
 * @dev Data for a single swap executed by `swap`, `amount` is either `amountIn` or `amountOut` depending on `kind`
 * value
 *
 * `assetIn` and `assetOut` are either token addresses, or the IAsset sentinel value for ETH (the zero address)
 * Note the Pools never interact with ETH directly, it will be wrapped to or unwrapped from WETH by the Vault
 *
 * The `userData` field is ignored by the Vault, but forwarded to the Pool in the `onSwap` hook, and may be used to
 * extend swap behavior
 */
struct SingleSwap {
    bytes32 poolId;
    SwapKind kind;
    IAsset assetIn;
    IAsset assetOut;
    uint256 amount;
    bytes userData;
}

/**
 * @dev All tokens in a swap are either sent from the `sender` account to the Vault, or from the Vault to the
 * `recepient` account
 *
 * If the caller is not `sender`, it must be an authorized relayer for them
 *
 * If `fromInternalBalance` is true, the `sender`'s Internal Balance will be preferred, performing an ERC20
 * transfer for the difference between amount and the User's Internal Balance (if any). The `sender` must have
 * allowed the Vault to use their tokens via `IERC20.approve()`. This matches the behavior of `joinPool`.
 *
 * If `toInternalBalance` is true, tokens will be deposited to `recipient`'s Internal Balance instead of transferred.
 * This matches the behavior of `exitPool`.
 *
 * Note that ETH cannot be deposited to or withdrawn from Internal Balance: attempting to do so will revert.
 */
struct FundManagement {
    address sender;
    bool fromInternalBalance;
    address payable recipient;
    bool toInternalBalance;
}

interface IBalancerVault {
    function getPoolTokens(
        bytes32 poolId
    ) external view returns (IERC20[] memory tokens, uint256[] memory balances, uint256 lastChangeBlock);

    function joinPool(
        bytes32 poolId,
        address sender,
        address recipient,
        JoinPoolRequest memory request
    ) external payable;

    /**
     * @dev Performs a swap with a single pool
     *
     * If the swap is 'given in' (the number of tokens to send to the Pool is known), it returns the amount of tokens
     * taken from the Pool, which must be greater than or equal to 'limit'
     *
     * If the swap is 'given out' (the number of tokens to take from the Pool is known), it returns the amount of tokens
     * sent to the Pool, which must be less than or equal to 'limit'
     *
     * Internal Balance usage and the recipient are determined by the 'funds' struct
     *
     * Emits a `Swap` event
     */
    function swap(
        SingleSwap memory singleSwap,
        FundManagement memory funds,
        uint256 limit,
        uint256 deadline
    ) external payable returns (uint256);
}

interface IBalancerVaultGeneral {
    function getPoolTokens(
        bytes32 poolId
    ) external view returns (address[] memory tokens, uint256[] memory balances, uint256 lastChangeBlock);

    function joinPool(
        bytes32 poolId,
        address sender,
        address recipient,
        JoinPoolRequest memory request
    ) external payable;

    /**
     * @dev Performs a swap with a single pool
     *
     * If the swap is 'given in' (the number of tokens to send to the Pool is known), it returns the amount of tokens
     * taken from the Pool, which must be greater than or equal to 'limit'
     *
     * If the swap is 'given out' (the number of tokens to take from the Pool is known), it returns the amount of tokens
     * sent to the Pool, which must be less than or equal to 'limit'
     *
     * Internal Balance usage and the recipient are determined by the 'funds' struct
     *
     * Emits a `Swap` event
     */
    function swap(
        SingleSwap memory singleSwap,
        FundManagement memory funds,
        uint256 limit,
        uint256 deadline
    ) external payable returns (uint256);
}
