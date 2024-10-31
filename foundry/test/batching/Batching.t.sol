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
import {VaultCollateral} from "src/vaults/VaultCollateral.sol";
import {ERC20Mintable} from "src/ERC20/ERC20Mintable.sol";
import {IRMMock} from "test/mocks/IRMMock.sol";

interface IERC20Extensions is IERC20 {
    function decimals() external view returns (uint8);
}

contract BatchingTest is Test, BalancerSepoliaAddresses, ChainLinkFeedAddresses {
    Fiat USDC;
    ERC20Mintable eUSD;
    Fiat DAI;
    IBalancerPool poolToken;

    BalancerAdapter balancerAdapter;

    IEVC evc;

    VaultCollateral collateralVault;
    VaultMintable mintableVault;

    uint256 constant MAX_VAL = type(uint256).max;

    // we use this to track all deposits for stables (with 18 decimals)
    // it provides a benchmark for USD deposit value
    uint256 APPROX_PRICE_TRACKER;

    function setUp() public {
        vm.createSelectFork({blockNumber: 5_388_756, urlOrAlias: "https://eth-sepolia.public.blastapi.io"});

        // stablecoins creation, they already mint to the caller
        USDC = new Fiat("USDC", "USD Coin", 6);
        console2.log("USDC address: ", address(USDC));
        eUSD = new ERC20Mintable("eUSD", "Euler Vault Dollars", 18);
        console2.log("eUSD address: ", address(eUSD));
        DAI = new Fiat("DAI", "Dai Stablecoin", 18);
        console2.log("DAI address: ", address(DAI));

        eUSD.mint(address(this), 10_000_000e18);

        // EVC
        evc = new EthereumVaultConnector();

        // balancer contracts
        balancerAdapter = new BalancerAdapter(CSP_FACTORY, BALANCER_VAULT, address(evc));

        console2.log("Create");
        create();

        console2.log("Init");
        init();

        console2.log("JoinPool");
        joinPool();

        // vault contract
        IRMMock irm = new IRMMock();
        mintableVault =
            new VaultMintable(evc, address(eUSD), irm, balancerAdapter, address(USDC), "eUSD Liability Vault", "EUSDLV");

        collateralVault = new VaultCollateral(evc, address(poolToken), "Pool Token Collateral Vault", "PTCV");

        irm.setInterestRate(10); // 10% APY

        // transfer ownership
        eUSD.transferOwnership(address(mintableVault));
    }

    function test_Leverage_Pool_Position(
        address alice
    ) public {
        address caller = alice;

        console2.log("Assume");
        vm.assume(caller != address(0));
        vm.assume(caller != address(evc) && caller != address(mintableVault) && caller != address(collateralVault));

        USDC.transfer(caller, 200e6);
        assertEq(USDC.balanceOf(caller), 200e6);

        console2.log("setCollateralFactor");
        mintableVault.setCollateralFactor(address(mintableVault), 0); // cf = 0, self-collateralization
        mintableVault.setCollateralFactor(address(collateralVault), 90); // cf = 0.9, 90% collateralization

        uint256 borrowAmount = 300e18; // eUSD

        address depositAsset = address(USDC);
        uint256 depositAmount = 50e6;

        address vault = address(collateralVault);
        address recipient = caller;

        console2.log("Create Batch");
        // deposits collaterals, enables them, enables controller and borrows
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](4);

        items[0] = IEVC.BatchItem({
            targetContract: address(evc),
            onBehalfOfAccount: address(0),
            value: 0,
            data: abi.encodeWithSelector(IEVC.enableController.selector, caller, address(mintableVault))
        });

        items[1] = IEVC.BatchItem({
            targetContract: address(evc),
            onBehalfOfAccount: address(0),
            value: 0,
            data: abi.encodeWithSelector(IEVC.enableCollateral.selector, caller, address(collateralVault))
        });

        items[2] = IEVC.BatchItem({
            targetContract: address(mintableVault),
            onBehalfOfAccount: caller,
            value: 0,
            data: abi.encodeWithSelector(VaultMintable.borrow.selector, borrowAmount, address(balancerAdapter))
        });

        items[3] = IEVC.BatchItem({
            targetContract: address(balancerAdapter),
            onBehalfOfAccount: caller,
            value: 0,
            data: abi.encodeWithSelector(
                BalancerAdapter.facilitateLeveragedDeposit.selector, depositAsset, depositAmount, vault, recipient
            )
        });

        console2.log("Approve Collateral");
        vm.prank(caller);
        USDC.approve(address(balancerAdapter), type(uint256).max);

        console2.log("Batch");
        vm.prank(caller);
        evc.batch(items);

        assertEq(eUSD.balanceOf(address(mintableVault)), 0);
        assertEq(eUSD.balanceOf(caller), 0);
        assertEq(mintableVault.maxWithdraw(caller), 0);
        assertEq(mintableVault.debtOf(caller), borrowAmount);
        assertEq(poolToken.balanceOf(caller), 0);

        uint256 collateralBalance = poolToken.balanceOf(address(collateralVault));
        uint256 poolTokenAmountInUSDC = balancerAdapter.getQuote(collateralBalance, address(0), address(USDC));
        uint256 usdAmountDepositAndBorrow = (
            borrowAmount + depositAmount * 10 ** (eUSD.decimals() - IERC20Extensions(depositAsset).decimals())
        ) / 10 ** (eUSD.decimals() - USDC.decimals());
        assertApproxEqRel(
            poolTokenAmountInUSDC,
            usdAmountDepositAndBorrow,
            0.01e18 // 1% deviation
        );
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
    }

    function init() private {
        uint256[] memory amounts = new uint256[](4);

        address adapter = address(balancerAdapter);

        uint256 eusdAmount = 10.0e18;
        APPROX_PRICE_TRACKER += eusdAmount;
        amounts[1] = eusdAmount;
        eUSD.transfer(adapter, eusdAmount);

        uint256 usdcAmount = 10.0e6;
        APPROX_PRICE_TRACKER += usdcAmount * 1e12;
        amounts[2] = usdcAmount;
        USDC.transfer(adapter, usdcAmount);

        uint256 daiAmount = 10.0e18;
        APPROX_PRICE_TRACKER += daiAmount;
        amounts[3] = daiAmount;
        DAI.transfer(adapter, daiAmount);

        console2.log("initialize");
        address recipient = address(this);
        balancerAdapter.initializePool(amounts, recipient);

        poolToken = IBalancerPool(balancerAdapter.pool());
        console2.log("PoolToken: ", address(poolToken));
    }

    function joinPool() internal {
        uint256[] memory amounts = new uint256[](3);
        address adapter = address(balancerAdapter);

        uint256 eusdAmount = 1_200_000.0e18;
        APPROX_PRICE_TRACKER += eusdAmount;
        amounts[0] = eusdAmount;
        eUSD.transfer(adapter, eusdAmount);

        uint256 usdcAmount = 1_020_000.0e6;
        APPROX_PRICE_TRACKER += usdcAmount * 1e12;
        amounts[1] = usdcAmount;
        USDC.transfer(adapter, usdcAmount);

        uint256 daiAmount = 900_000.0e18;
        APPROX_PRICE_TRACKER += daiAmount;
        amounts[2] = daiAmount;
        DAI.transfer(adapter, daiAmount);
        console2.log("Join Pool");
        // deposit balances to pool
        balancerAdapter.depositTo(amounts, address(this));
    }
}
