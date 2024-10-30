// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.19;

import {Test, console2} from "forge-std/Test.sol";
import {ICSPFactory} from "src/balancer-adapter/interfaces/ICSPFactory.sol";
import {IBalancerVaultGeneral} from "src/balancer-adapter/interfaces/IVaultGeneral.sol";
import {BalancerSepoliaAddresses} from "../balancer-adapter/BalancerSepoliaAddresses.sol";
import {ChainLinkFeedAddresses} from "../balancer-adapter/ChainlinkFeedAddresses.sol";
import {Fiat} from "../ERC20/Fiat.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBalancerPool} from "src/balancer-adapter/interfaces/IBalancerPool.sol";
import {BalancerAdapter} from "src/balancer-adapter/BalancerAdapter.sol";
import {WrappedRateProvider} from "src/balancer-adapter/WrappedRateProvider.sol";
import "evc/EthereumVaultConnector.sol";
import {VaultMintable} from "src/vaults/VaultMintable.sol";
