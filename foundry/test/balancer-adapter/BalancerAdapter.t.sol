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

    // we use this to track all deposits for stables (with 18 decimals)
    // it provides a benchmark for USD deposit value
    uint256 APPROX_PRICE_TRACKER;

    function setUp() public {
        vm.createSelectFork({blockNumber: 5_388_756, urlOrAlias: "https://eth-sepolia.public.blastapi.io"});

        // stablecoins creation, they already mint to the caller
        USDC = new Fiat("USDC", "USD Coin", 6);
        console2.log("USDC address: ", address(USDC));
        eUSD = new Fiat("eUSD", "Euler Vault Dollars", 18);
        console2.log("eUSD address: ", address(eUSD));
        DAI = new Fiat("DAI", "Dai Stablecoin", 18);
        console2.log("DAI address: ", address(DAI));

        // balancer contracts
        cspFactory = ICSPFactory(CSP_FACTORY);
        balancerVault = IBalancerVaultGeneral(BALANCER_VAULT);
        evc = new EthereumVaultConnector();
        console2.log("EVC address: ", address(evc));
        balancerAdapter = new BalancerAdapter(CSP_FACTORY, BALANCER_VAULT, address(evc));
    }

    function test_Adapter_Create_CS_Pool() public {
        create();
        console2.log("Balancer Adapter Pool: ", balancerAdapter.pool());
    }

    function test_Adapter_Init_CS_Pool() public {
        create();
        console2.log("Balancer Adapter Init CS Pool: ", balancerAdapter.pool());
        init();
    }

    function test_Adapter_Join_CS_Pool() public {
        create();
        init();
        address pool = balancerAdapter.pool();
        uint256 balance = IERC20(pool).balanceOf(address(this));
        // deposit balances to pool
        joinPool();

        balance = IERC20(pool).balanceOf(address(this)) - balance;
        // we assert that enough BPTs were minted
        assert(balance >= 3000.0e18);
    }

    function test_Adapter_Pricing() public {
        create();
        init();
        address pool = balancerAdapter.pool();
        // deposit balances to pool
        joinPool();

        // this is the total supply
        uint256 balance = IERC20(pool).balanceOf(address(this));
        uint256 price = balancerAdapter.getPrice();

        console2.log("Price in USD: ", price);

        address quoteAsset = address(USDC);
        uint256 quoteAll = balancerAdapter.getQuote(balance, address(0), quoteAsset);

        assertApproxEqAbs(
            quoteAll * 1e12,
            APPROX_PRICE_TRACKER,
            (APPROX_PRICE_TRACKER * 1) / 100 // allow 5% deviation
        );
        uint256 halfBalance = balance / 2;
        uint256 quote = balancerAdapter.getQuote(halfBalance, address(0), quoteAsset);

        console2.log("Quote in USDC: ", quote);

        quoteAsset = address(DAI);
        quoteAll = balancerAdapter.getQuote(balance, address(0), quoteAsset);

        assertApproxEqAbs(
            quoteAll,
            APPROX_PRICE_TRACKER,
            (APPROX_PRICE_TRACKER * 1) / 100 // allow 5% deviation
        );

        console2.log("Quote All in DAI: ", quoteAll);
        halfBalance = balance / 2;
        quote = balancerAdapter.getQuote(halfBalance, address(0), quoteAsset);
        console2.log("Quote in DAI: ", quote);
    }

    function test_Adapter_EVC() public {
        create();
        init();
        joinPool();

        userVault = address(new MockVault(balancerAdapter.pool(), address(evc)));
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        // parameters for adapter
        address depositAsset = address(USDC);
        uint256 depositAmount = 10.0e6;
        address vault = userVault;
        address recipient = address(this);

        // item definition
        items[0] = IEVC.BatchItem({
            targetContract: address(balancerAdapter),
            onBehalfOfAccount: address(this),
            value: 0,
            data: abi.encodeWithSelector(
                BalancerAdapter.facilitateLeveragedDeposit.selector, depositAsset, depositAmount, vault, recipient
            )
        });
        USDC.approve(address(balancerAdapter), type(uint256).max);
        evc.batch(items);
        uint256 shares = MockVault(userVault).shares(address(this));
        console2.log("Shares: ", shares);
        assert(MockVault(userVault).shares(address(this)) > 0);
    }

    function joinPool() internal {
        uint256[] memory amounts = new uint256[](3);
        address adapter = address(balancerAdapter);

        (address[] memory assets, uint256[] memory scales) = balancerAdapter.getDecimalScalesAndTokens();

        for (uint256 i = 0; i < assets.length; i++) {
            uint256 amountRaw = (1000.0 + i * 10);
            APPROX_PRICE_TRACKER += amountRaw * 1e18;
            uint256 amount = amountRaw * scales[i];
            amounts[i] = amount;
            IERC20(assets[i]).transfer(adapter, amount);
        }

        console2.log("Join Pool");
        // deposit balances to pool
        balancerAdapter.depositTo(amounts, address(this));
        console2.log("Tracked after join: ", APPROX_PRICE_TRACKER);
    }

    function init() private {
        uint256[] memory amounts = new uint256[](4);

        address adapter = address(balancerAdapter);

        (address[] memory assets, uint256[] memory scales) = balancerAdapter.getOriginalDecimalScalesAndTokens();
        console2.log("Pre-init");

        for (uint256 i = 0; i < assets.length; i++) {
            address token = assets[i];
            if (token != balancerPool) {
                uint256 amountRaw = (10.0 + i * 10) * 1e18;
                uint256 amount = amountRaw / scales[i];
                APPROX_PRICE_TRACKER += amountRaw;
                amounts[i] = amount;
                IERC20(assets[i]).transfer(adapter, amount);
            }
        }

        console2.log("initialize");
        address recipient = address(this);
        balancerAdapter.initializePool(amounts, recipient);
        console2.log("Tracked after init: ", APPROX_PRICE_TRACKER);
    }

    function create() private {
        address[] memory tokens = new address[](3);
        tokens[0] = address(eUSD);
        tokens[1] = address(USDC);
        tokens[2] = address(DAI);

        address[] memory rateProvider = new address[](3);
        rateProvider[0] = address(0);
        rateProvider[1] = address(new WrappedRateProvider(USDC_FEED));
        rateProvider[2] = address(new WrappedRateProvider(DAI_FEED));

        balancerAdapter.createPool(tokens, rateProvider);

        balancerPool = balancerAdapter.pool();
    }
}
