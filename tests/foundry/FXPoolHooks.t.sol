// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import {IVault} from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import {
    IRouter
} from "@balancer-labs/v3-interfaces/contracts/vault/IRouter.sol";
import {
    IVaultErrors
} from "@balancer-labs/v3-interfaces/contracts/vault/IVaultErrors.sol";
import "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import {
    ArrayHelpers
} from "@balancer-labs/v3-solidity-utils/contracts/test/ArrayHelpers.sol";

import {
    BalancerPoolToken
} from "@balancer-labs/v3-vault/contracts/BalancerPoolToken.sol";
import {
    BaseVaultTest
} from "@balancer-labs/v3-vault/test/foundry/utils/BaseVaultTest.sol";

import {FXPoolFactory} from "../../contracts/FXPoolFactory.sol";
import {FXPool} from "../../contracts/FXPool.sol";
import {
    QuoteAssimilator
} from "../../contracts/assimilators/QuoteAssimilator.sol";
import {
    BaseAssimilator
} from "../../contracts/assimilators/BaseAssimilator.sol";
import {
    StaticPriceOracle
} from "../../contracts/periphery/StaticPriceOracle.sol";
import {IOracle} from "../../contracts/core/interfaces/IOracle.sol";
import {IFXPool} from "../../contracts/core/interfaces/IFXPool.sol";
import {
    FXAssets,
    FXGreeks,
    NewPoolParams
} from "../../contracts/core/FXPoolTypes.sol";
import {FXPoolBaseTest} from "./FXPoolBaseTest.sol";

contract FXPoolHooksTest is FXPoolBaseTest {
    using ArrayHelpers for *;

    address public FX_POOL;
    uint256 maxAmount = 100e18;

    function setUp() public override {
        super.setUp();
        DeployFXPoolParams memory params = DeployFXPoolParams({
            name: "FX_DAI_USDC",
            lp: lp,
            protocolPercentFee: 60,
            depositNumeraire: 100 * 1e18,
            quoteToken: address(usdc),
            baseToken: address(dai),
            quoteOracleName: "USDC / USD",
            quoteOraclePrice: 100_000_000,
            baseOracleName: "DAI / USD",
            baseOraclePrice: 100_000_000,
            greeks: _fxDefaultGreeks()
        });

        (FX_POOL, , ) = _deployAndInitializeFXPool(params);
        approveForPool(IERC20(FX_POOL));
    }

    function testAddLiquidityCustom() public {
        vm.startPrank(lp);
        _addLiquidity(
            "FXPoolHooks: testAddLiquidityCustom",
            FX_POOL,
            1001e18,
            lp
        );
        vm.stopPrank();
        // FXPool specific asserts are tested in other tests
    }

    function testRemoveLiquidityCustom() public {
        // lp user already has tokens from pool initialization
        uint256 lpToBurn = IFXPool(FX_POOL).balanceOf(lp);

        vm.startPrank(lp);
        _removeLiquidity(
            "FXPoolHooks: testRemoveLiquidityCustom",
            FX_POOL,
            lpToBurn,
            lp
        );
        vm.stopPrank();
        // FXPool specific asserts are tested in other tests
    }

    function testAddLiquidityProportional() public {
        vm.prank(lp);
        vm.expectRevert();
        router.addLiquidityProportional(
            FX_POOL,
            [maxAmount, maxAmount].toMemoryArray(),
            0,
            false,
            abi.encode(10e18)
        );
    }

    function testAddLiquiditySingleTokenExactOut() public {
        vm.prank(lp);
        vm.expectRevert();
        router.addLiquiditySingleTokenExactOut(
            FX_POOL,
            dai,
            type(uint256).max,
            10,
            false,
            abi.encode(10e18)
        );
    }

    function testAddLiquidityUnbalanced() public {
        vm.prank(lp);
        vm.expectRevert();
        router.addLiquidityUnbalanced(
            FX_POOL,
            [maxAmount, maxAmount].toMemoryArray(),
            0,
            false,
            abi.encode(10e18)
        );
    }

    function testDonate() public {
        vm.prank(lp);
        vm.expectRevert();
        router.donate(
            FX_POOL,
            [maxAmount, maxAmount].toMemoryArray(),
            false,
            abi.encode(10e18)
        );
    }
}
