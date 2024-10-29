// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.19;

import {Test, console2} from "forge-std/Test.sol";
import {ICSPFactory, IRateProvider} from "src/balancer-adapter/interfaces/ICSPFactory.sol";
import {
    IBalancerVaultGeneral,
    JoinPoolRequest,
    SingleSwap,
    SwapKind,
    FundManagement
} from "src/balancer-adapter/interfaces/IVaultGeneral.sol";
import {BalancerSepoliaAddresses} from "./BalancerSepoliaAddresses.sol";
import {ChainLinkFeedAddresses} from "./ChainlinkFeedAddresses.sol";
import {Fiat} from "../ERC20/Fiat.sol";
import "evc/EthereumVaultConnector.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBalancerPool} from "src/balancer-adapter/interfaces/IBalancerPool.sol";
import {StablePoolUserData} from "src/balancer-adapter/interfaces/StablePoolUserData.sol";
import {BalancerAdapter, IMinimalVault} from "src/balancer-adapter/BalancerAdapter.sol";
import {WrappedRateProvider} from "src/balancer-adapter/WrappedRateProvider.sol";
import {MockVault} from "test/mocks/MockVault.sol";

contract BalancerAdapterTest is Test, BalancerSepoliaAddresses, ChainLinkFeedAddresses {
    Fiat USDC;
    Fiat eUSD;
    Fiat DAI;

    EthereumVaultConnector evc;
    BalancerAdapter balancerAdapter;

    ICSPFactory cspFactory;
    IBalancerVaultGeneral balancerVault;
    address userVault;
    uint256 constant MAX_VAL = type(uint256).max;
    address balancerPool;
}
