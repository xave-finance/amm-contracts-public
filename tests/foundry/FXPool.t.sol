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
    IERC20Metadata
} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

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
    NewPoolParams,
    PoolBoundaries
} from "../../contracts/core/FXPoolTypes.sol";
import {FXPoolBaseTest} from "./FXPoolBaseTest.sol";
import {NewPoolParams} from "./../../contracts/core/FXPoolTypes.sol";

contract FXPoolTest is FXPoolBaseTest {
    using ArrayHelpers for *;

    address public FX_POOL;
    uint256 maxAmount = 100e18;

    function testInitialize() public {
        uint256 daiBal = _getScaledUserBalance(lp, address(dai));
        uint256 usdcBal = _getScaledUserBalance(lp, address(usdc2));
        _deployDaiUsdcPool(100 * 1e18);

        uint256 daiBalDelta = daiBal - _getScaledUserBalance(lp, address(dai));
        uint256 usdcBalDelta = usdcBal -
            _getScaledUserBalance(lp, address(usdc2));

        assertEq(
            address(IFXPool(FX_POOL).getVault()),
            address(vault),
            "correct vault set"
        );
        assertEq(
            IFXPool(FX_POOL).quoteToken(),
            address(usdc2),
            "correct quote token"
        );
        assertEq(
            IFXPool(FX_POOL).baseToken(),
            address(dai),
            "correct base token"
        );

        // copy paste from internal constant in `ERC20MultiToken`
        uint256 _POOL_MINIMUM_TOTAL_SUPPLY = 1e6;

        assertLeBoundedPercentMax(
            IERC20(FX_POOL).balanceOf(lp),
            daiBalDelta + usdcBalDelta - _POOL_MINIMUM_TOTAL_SUPPLY,
            "minted equal or slightly less LP tokens"
        );
    }

    function testGetAssetIndex() public {
        _deployDaiUsdcPool(100 * 1e18);
        bool quoteIndexZero = IFXPool(FX_POOL).isQuoteIndexZero();

        assertEq(
            IFXPool(FX_POOL).getAssetIndex(address(usdc2)),
            quoteIndexZero ? 0 : 1,
            "correct index for USDC2"
        );
        assertEq(
            IFXPool(FX_POOL).getAssetIndex(address(dai)),
            quoteIndexZero ? 1 : 0,
            "correct index for DAI"
        );
    }

    function testGetAssimilator() public {
        _deployDaiUsdcPool(100 * 1e18);

        address baseAssimilator = IFXPool(FX_POOL).assimilator(address(dai));
        address quoteAssimilator = IFXPool(FX_POOL).assimilator(address(usdc2));

        assertEq(
            address(BaseAssimilator(baseAssimilator).quoteToken()),
            address(usdc2),
            "correct quote token in base assimilator"
        );
        assertEq(
            address(BaseAssimilator(baseAssimilator).baseToken()),
            address(dai),
            "correct base token in base assimilator"
        );
        assertEq(
            address(QuoteAssimilator(quoteAssimilator).quoteToken()),
            address(usdc2),
            "correct quote token in quote assimilator"
        );
    }

    function testGetRate() public {
        (address fxPool, , ) = _deployToken13DecToken2DecPool(100_000 * 1e18);

        assertApproxEqPctAbsMax(
            IFXPool(fxPool).getRate(),
            1e18,
            "[inital state] correct rate"
        );

        {
            // add liquidity
            uint256 depositNumeraire = 1000 * 1e18;
            vm.startPrank(charlie);
            _addLiquidity(
                "FXPoolTest: testGetRate",
                fxPool,
                depositNumeraire,
                charlie
            );
            vm.stopPrank();
        }

        {
            for (uint256 i = 0; i < 15; i++) {
                PoolBoundaries memory b = IFXPool(fxPool).getPoolBoundaries();
                address tokenIn = b.betaSwapAmtMaxToken;
                address tokenOut = tokenIn == address(token13Dec)
                    ? address(token2Dec)
                    : address(token13Dec);
                vm.startPrank(eve);
                _swapExactIn(
                    "FXPoolTest::testGetRate",
                    fxPool,
                    IERC20(tokenIn),
                    IERC20(tokenOut),
                    IFXPool(fxPool).convertNumeraireToRaw(
                        tokenIn,
                        b.betaSwapAmtMax
                    ),
                    0,
                    eve
                );
                vm.stopPrank();

                _remove1LPTokenReport(
                    "[testGetRate] 1LP numeraire:",
                    fxPool,
                    charlie
                );
            }
        }
    }

    function _add1LpTokenReport(
        string memory,
        /*_label*/ address _fxpool,
        address _user,
        uint256 _depositNumeraire
    ) private returns (uint256) {
        uint256 userBalNumeraireBefore = _userTotalBalancesNumeraire(
            _fxpool,
            _user
        );
        vm.startPrank(_user);
        _addLiquidity(
            "[testGetRate] addLiq:",
            _fxpool,
            _depositNumeraire,
            _user
        );
        vm.stopPrank();

        uint256 userBalNumeraireAfter = _userTotalBalancesNumeraire(
            _fxpool,
            _user
        );
        uint256 delta = userBalNumeraireAfter - userBalNumeraireBefore;
        // console2.log(_label, delta);
        return delta;
    }

    function _remove1LPTokenReport(
        string memory,
        /*_label*/ address _fxpool,
        address _user
    ) private returns (uint256) {
        uint256 userBalNumeraireBefore = _userTotalBalancesNumeraire(
            _fxpool,
            _user
        );
        vm.startPrank(_user);
        (, , uint256 lpBurnt) = _removeLiquidity(
            "[testGetRate] removeLiq:",
            _fxpool,
            1e18,
            _user
        );
        vm.stopPrank();
        assertEq(lpBurnt, 1e18, "burnt 1 LP Token");

        uint256 userBalNumeraireAfter = _userTotalBalancesNumeraire(
            _fxpool,
            _user
        );
        uint256 delta = userBalNumeraireAfter - userBalNumeraireBefore;
        return delta;
    }

    function testRawNumeraireConversion() public {
        (address fxPool, , ) = _deployToken13DecToken2DecPool(100 * 1e18);

        uint256 rawAmount = IFXPool(fxPool).convertNumeraireToRaw(
            address(token13Dec),
            100 * 1e18
        );
        assertEq(rawAmount, 100 * 1e13, "[13Dec] correct raw amount");
        uint256 numeraireAmount = IFXPool(fxPool).convertRawToNumeraire(
            address(token13Dec),
            rawAmount
        );
        assertEq(
            numeraireAmount,
            100 * 1e18,
            "[13Dec] correct numeraire amount"
        );

        rawAmount = IFXPool(fxPool).convertNumeraireToRaw(
            address(token2Dec),
            100 * 1e18
        );
        assertEq(rawAmount, 100 * 1e2, "[2Dec] correct raw amount");
        numeraireAmount = IFXPool(fxPool).convertRawToNumeraire(
            address(token2Dec),
            rawAmount
        );
        assertEq(
            numeraireAmount,
            100 * 1e18,
            "[2Dec] correct numeraire amount"
        );

        ///// large amounts
        rawAmount = IFXPool(fxPool).convertNumeraireToRaw(
            address(token13Dec),
            1e18 * 1e18
        );
        assertEq(rawAmount, 1e13 * 1e18, "[13Dec][1e36] correct raw amount");
        numeraireAmount = IFXPool(fxPool).convertRawToNumeraire(
            address(token13Dec),
            rawAmount
        );
        assertEq(
            numeraireAmount,
            1e18 * 1e18,
            "[13Dec][1e36] correct numeraire amount"
        );

        rawAmount = IFXPool(fxPool).convertNumeraireToRaw(
            address(token2Dec),
            1e18 * 1e18
        );
        assertEq(rawAmount, 1e2 * 1e18, "[2Dec][1e36] correct raw amount");
        numeraireAmount = IFXPool(fxPool).convertRawToNumeraire(
            address(token2Dec),
            rawAmount
        );
        assertEq(
            numeraireAmount,
            1e18 * 1e18,
            "[2Dec][1e36] correct numeraire amount"
        );

        vm.expectRevert(bytes("FXP#532"));
        IFXPool(fxPool).convertRawToNumeraire(address(dai), rawAmount);
        vm.expectRevert(bytes("FXP#532"));
        IFXPool(fxPool).convertNumeraireToRaw(address(usdc2), 100 * 1e18);
    }

    function testZeroFees() public {
        uint256 depositNumeraire = 100_000e18;
        _deployZeroFeeDaiUsdcPool(depositNumeraire);

        uint256 swapAmount = 5_000;

        uint256 daiBalBefore = _getScaledUserBalance(charlie, address(dai));
        uint256 usdcBalBefore = _getScaledUserBalance(charlie, address(usdc2));

        for (uint256 i; i < 3; i++) {
            // perform swaps
            uint256 daiSwapAmount = tokenAmount(swapAmount, address(dai));
            uint256 usdcSwapAmount = tokenAmount(swapAmount, address(usdc2));
            vm.startPrank(charlie);
            _swapExactIn(
                "FXPoolTest::testZeroFees",
                FX_POOL,
                dai,
                usdc2,
                daiSwapAmount,
                0,
                charlie
            );

            _swapExactIn(
                "FXPoolTest::testZeroFees",
                FX_POOL,
                usdc2,
                dai,
                usdcSwapAmount,
                0,
                charlie
            );
            vm.stopPrank();
        }
        uint256 daiBalAfter = _getScaledUserBalance(charlie, address(dai));
        uint256 usdcBalAfter = _getScaledUserBalance(charlie, address(usdc2));

        assertApproxEqAbs(
            daiBalBefore,
            daiBalAfter,
            errMarginForScaled18(daiBalBefore),
            "dai balance unchanged"
        );
        assertApproxEqAbs(
            usdcBalBefore,
            usdcBalAfter,
            errMarginForScaled18(usdcBalBefore),
            "usdc2 balance unchanged"
        );
    }

    function testMultiplePools() public {
        _deployDaiUsdcPool(100 * 1e18);
        _deployDaiUsdcPool(100 * 1e18);
    }

    function testAddLiquidityCustom() public {
        _deployDaiUsdcPool(100 * 1e18);
        (uint256 totalLiquidity, uint256[] memory fxBalances) = IFXPool(FX_POOL)
            .liquidity();
        assertLeBoundedPercentMax(
            100 * 1e18,
            totalLiquidity,
            "initial total liquidity is ~100"
        );
        assertEq(fxBalances.length, 2, "initial fxBalances length is 2");
        assertLeBoundedPercentMax(
            50 * 1e18,
            fxBalances[0],
            "initial fxBalances[0] is ~50"
        );
        assertLeBoundedPercentMax(
            50 * 1e18,
            fxBalances[1],
            "initial fxBalances[1] is ~50"
        );

        uint256 lpBal = IFXPool(FX_POOL).balanceOf(lp);
        uint256 daiBal = _getScaledUserBalance(lp, address(dai));
        uint256 usdcBal = _getScaledUserBalance(lp, address(usdc2));
        uint256 depositNumeraire = 100_000e18;

        vm.startPrank(lp);
        router.addLiquidityCustom(
            FX_POOL,
            [uint256(1e27), uint256(1e27)].toMemoryArray(),
            0,
            false,
            abi.encode(depositNumeraire)
        );
        vm.stopPrank();

        (totalLiquidity, fxBalances) = IFXPool(FX_POOL).liquidity();
        assertLeBoundedPercentMax(
            100_100 * 1e18,
            totalLiquidity,
            "correct total liquidity"
        );
        assertEq(fxBalances.length, 2, "correct fxBalances length");
        assertLeBoundedPercentMax(
            50_050 * 1e18,
            fxBalances[0],
            "correct fxBalances[0]"
        );
        assertLeBoundedPercentMax(
            50_050 * 1e18,
            fxBalances[1],
            "correct fxBalances[1]"
        );

        uint256 daiBalDelta = daiBal - _getScaledUserBalance(lp, address(dai));
        uint256 usdcBalDelta = usdcBal -
            _getScaledUserBalance(lp, address(usdc2));
        uint256 lpMinted = IFXPool(FX_POOL).balanceOf(lp) - lpBal;

        // oracle rate is 1:1 so in this case it's ok to do this
        assertLeBoundedPercentMax(
            lpMinted,
            daiBalDelta + usdcBalDelta,
            "correct amount of LP tokens minted"
        );
        assertLeBoundedPercentMax(
            50_000 * 1e18,
            daiBalDelta,
            "Correct amount of DAI tokens taken"
        );
        assertLeBoundedPercentMax(
            50_000 * 1e18,
            usdcBalDelta,
            "Correct amount of USDC2 tokens taken"
        );
    }

    function testRemoveLiquidityCustom() public {
        _deployDaiUsdcPool(100 * 1e18);

        uint256 lpToBurn = 50e18;

        vm.startPrank(lp);
        IFXPool(FX_POOL).approve(address(router), lpToBurn);
        (
            uint256 quoteTokenDelta,
            uint256 baseTokenDelta,
            uint256 lpBalDelta
        ) = _removeLiquidity(
                "FXPoolTest: testRemoveLiquidityCustom",
                FX_POOL,
                lpToBurn,
                lp
            );
        vm.stopPrank();
        assertApproxEqPctAbsMax(
            IFXPool(FX_POOL).convertRawToNumeraire(
                IFXPool(FX_POOL).quoteToken(),
                quoteTokenDelta
            ),
            25 * 1e18,
            "correct amount of quote tokens received"
        );
        assertApproxEqPctAbsMax(
            IFXPool(FX_POOL).convertRawToNumeraire(
                IFXPool(FX_POOL).baseToken(),
                baseTokenDelta
            ),
            25 * 1e18,
            "correct amount of base tokens received"
        );

        // will receive slightly less tokens than expected because of rounding errors
        assertLeBoundedPercentMax(
            IFXPool(FX_POOL).convertRawToNumeraire(
                IFXPool(FX_POOL).quoteToken(),
                quoteTokenDelta
            ) +
                IFXPool(FX_POOL).convertRawToNumeraire(
                    IFXPool(FX_POOL).baseToken(),
                    baseTokenDelta
                ),
            lpToBurn,
            "correct amount of DAI + USDC2 tokens received"
        );

        assertEq(lpBalDelta, lpToBurn, "correct amount of LP tokens burned");
    }

    function testRemoveLiquidityCustom2() public {
        _deployDaiUsdcPool(100 * 1e18);

        vm.startPrank(lp);

        // add $1oo more worth of liquidity to the pool
        _addLiquidity(
            "FXPoolTest: testRemoveLiquidityCustom2",
            FX_POOL,
            100 * 1e18,
            lp
        );

        // burn all the balance
        uint256 lpToBurn = IFXPool(FX_POOL).balanceOf(lp);
        assertApproxEqPctAbsMax(
            lpToBurn,
            200 * 1e18,
            "correct amount of LP tokens minted"
        );

        (
            uint256 quoteTokenDelta,
            uint256 baseTokenDelta,
            uint256 lpBalDelta
        ) = _removeLiquidity(
                "FXPoolTest: testRemoveLiquidityCustom2",
                FX_POOL,
                lpToBurn,
                lp
            );

        vm.stopPrank();

        // will receive slightly less tokens than expected because of rounding errors
        // we need to ensure that the rounding error is always in favour of the vault
        assertApproxEqPctAbsMax(
            IFXPool(FX_POOL).convertRawToNumeraire(
                IFXPool(FX_POOL).quoteToken(),
                quoteTokenDelta
            ),
            100 * 1e18,
            "correct amount of quote tokens received"
        );
        assertApproxEqPctAbsMax(
            IFXPool(FX_POOL).convertRawToNumeraire(
                IFXPool(FX_POOL).baseToken(),
                baseTokenDelta
            ),
            100 * 1e18,
            "correct amount of base tokens received"
        );
        assertEq(lpBalDelta, lpToBurn, "correct amount of LP tokens burned");

        assertLeBoundedPercentMax(
            IFXPool(FX_POOL).convertRawToNumeraire(
                IFXPool(FX_POOL).quoteToken(),
                quoteTokenDelta
            ) +
                IFXPool(FX_POOL).convertRawToNumeraire(
                    IFXPool(FX_POOL).baseToken(),
                    baseTokenDelta
                ),
            lpToBurn,
            "correct amount of DAI + USDC2 tokens received"
        );
    }

    function testSwapExactIn() public {
        _deployDaiUsdcPool(100 * 1e18);
        uint256 swapAmount = 10 * 1e18;
        uint256 expectedAmountOut = 9.995 * 1e6;
        // fee is 5 bips (default EPSILON value is 0.0005)
        // therefore we expect to receive 9.995 USDC2
        // here we receive slightly less because of rounding errors
        // as long as the rounding error is in favour of the vault, we're good
        uint256 actualAmountOutRounding = 9.995 * 1e6 - 1;

        vm.startPrank(charlie);

        vm.expectRevert(
            abi.encodeWithSelector(
                IVaultErrors.SwapLimit.selector,
                actualAmountOutRounding,
                expectedAmountOut
            )
        );
        // need to call the router directly
        // cannot use _swap because expectRevert does not work in that case
        router.swapSingleTokenExactIn(
            FX_POOL,
            dai,
            usdc2,
            swapAmount,
            expectedAmountOut,
            block.timestamp + 1000,
            false,
            abi.encode("")
        );

        (uint256 inBalDelta, uint256 amountOut) = _swapExactIn(
            "FXPoolTest: testSwapExactIn",
            FX_POOL,
            dai,
            usdc2,
            swapAmount,
            actualAmountOutRounding,
            charlie
        );

        vm.stopPrank();

        assertEq(
            amountOut,
            actualAmountOutRounding,
            "correct amount of USDC2 tokens received"
        );
        assertEq(inBalDelta, swapAmount, "correct amount of DAI tokens taken");
    }

    function testSwapSameToken() public {
        _deployDaiUsdcPool(100 * 1e18);

        vm.startPrank(charlie);
        vm.expectRevert(
            abi.encodeWithSelector(IVaultErrors.CannotSwapSameToken.selector)
        );
        // need to call the router directly
        // cannot use _swap because expectRevert does not work in that case
        router.swapSingleTokenExactIn(
            FX_POOL,
            dai,
            dai,
            3 * 1e18,
            0,
            block.timestamp + 1000,
            false,
            abi.encode("")
        );
        vm.stopPrank();
    }

    function testSwapExactOut() public {
        _deployDaiUsdcPool(100 * 1e18);
        uint256 exactAmountOut = 10 * 1e6; // usdc2: 6 decimals
        // fee is 5 bips (default EPSILON value is 0.0005)
        uint256 maxAmountIn = 10.005 * 1e18 + 9; // with rounding errors; dai 18 decimals
        // 10.011001799640072002

        vm.startPrank(charlie);

        vm.expectRevert(
            abi.encodeWithSelector(
                IVaultErrors.SwapLimit.selector,
                maxAmountIn,
                exactAmountOut
            )
        );
        // need to call the router directly
        // cannot use _swap because expectRevert does not work in that case
        router.swapSingleTokenExactOut(
            FX_POOL,
            dai,
            usdc2,
            exactAmountOut,
            exactAmountOut, // do not account 5 bips
            block.timestamp + 1000,
            false,
            abi.encode("")
        );

        // paying maxAmountIn of DAI for exactAmountOut of USDC2
        // outBalDelta is USDC2 and amountIn is DAI
        (uint256 outBalDelta, uint256 amountIn) = _swapExactOut(
            "FXPoolTest: testSwapExactOut",
            FX_POOL,
            dai,
            usdc2,
            exactAmountOut,
            maxAmountIn,
            charlie
        );
        vm.stopPrank();

        assertEq(
            amountIn,
            maxAmountIn,
            "correct amount of USDC2 tokens received"
        );
        assertEq(
            outBalDelta,
            exactAmountOut,
            "correct amount of DAI tokens taken"
        );
    }

    function testHaltsReverts() public {
        _deployDaiUsdcPool(10000 * 1e18);

        PoolBoundaries memory b = IFXPool(FX_POOL).getPoolBoundaries();

        uint256 swapAmt = IFXPool(FX_POOL).convertNumeraireToRaw(
            b.haltSwapAmtMaxToken,
            b.haltSwapAmtMax
        );

        vm.startPrank(charlie);
        vm.expectRevert("FXP#530");
        router.swapSingleTokenExactIn(
            FX_POOL,
            IERC20(b.haltSwapAmtMaxToken),
            IERC20(b.haltSwapAmtMinToken),
            // @TODO 7% more than the max halt swap amount is a high margin
            (swapAmt * 107) / 100,
            0,
            block.timestamp + 1000,
            false,
            abi.encode("")
        );

        swapAmt = IFXPool(FX_POOL).convertNumeraireToRaw(
            b.haltSwapAmtMinToken,
            b.haltSwapAmtMin
        );

        vm.expectRevert("FXP#531");
        router.swapSingleTokenExactIn(
            FX_POOL,
            IERC20(b.haltSwapAmtMinToken),
            IERC20(b.haltSwapAmtMaxToken),
            // @TODO 7% more than the max halt swap amount
            (swapAmt * 107) / 100,
            0,
            block.timestamp + 1000,
            false,
            abi.encode("")
        );
        vm.stopPrank();
    }

    /// forge-config: default.fuzz.runs = 512
    /// forge-config: ci.fuzz.runs = 2048
    function testLargeAmounts(uint256 depositNumeraire) public {
        vm.assume(depositNumeraire > 1e18);
        vm.assume(depositNumeraire < 10_000_000_000 * 1e18);
        address[] memory _tokens = new address[](2);
        _tokens[0] = address(dai);
        _tokens[1] = address(usdc2);
        for (uint256 i = 0; i < _tokens.length; ++i) {
            uint256 tokenDecimals = IERC20Metadata(address(_tokens[i]))
                .decimals();
            deal(
                address(_tokens[i]),
                charlie,
                1_000_000_000_000 * (10 ** tokenDecimals)
            );
            deal(
                address(_tokens[i]),
                lp,
                1_000_000_000_000 * (10 ** tokenDecimals)
            );
        }

        _deployDaiUsdcPool(depositNumeraire);

        for (uint256 i = 0; i < 5; i++) {
            PoolBoundaries memory b = IFXPool(FX_POOL).getPoolBoundaries();
            uint256 swapAmountNumeraire;
            uint256 swapAmountRaw;
            address tokenIn;
            address tokenOut;
            if (i / 2 == 0) {
                // swap to beta edge
                tokenIn = b.betaSwapAmtMaxToken;
                swapAmountNumeraire = b.betaSwapAmtMax;
            } else {
                // swap to halt edge
                tokenIn = b.haltSwapAmtMaxToken;
                swapAmountNumeraire = b.haltSwapAmtMax;
            }
            tokenOut = tokenIn == address(dai) ? address(usdc2) : address(dai);
            swapAmountRaw = IFXPool(FX_POOL).convertNumeraireToRaw(
                tokenIn,
                swapAmountNumeraire
            );

            vm.startPrank(charlie);
            _swapExactIn(
                "FXPoolTest: testLargeAmounts",
                FX_POOL,
                IERC20(tokenIn),
                IERC20(tokenOut),
                swapAmountRaw,
                0, // check
                charlie
            );

            // add a bit more liquidity
            _addLiquidity(
                "FXPoolTest: testLargeAmounts add more liq",
                FX_POOL,
                10_000 * 1e18,
                charlie
            );
            vm.stopPrank();
        }
    }

    function testSwapDiffDecimalsUsdcInXsgdOut() public {
        _deployXsgdUsdcPool();
        uint256 swapAmount = 10 * 1e6; // usdc2: 6 decimals

        vm.startPrank(charlie);
        _swapExactIn(
            "FXPoolTest: testSwapDiffDecimalsUsdcInXsgdOut",
            FX_POOL,
            usdc2,
            xsgd,
            swapAmount,
            0, // check
            charlie
        );

        vm.stopPrank();
    }

    function testSwapDiffDecimalsXsgdInUsdcOut() public {
        _deployXsgdUsdcPool();
        uint256 swapAmount = 10 * 1e6;

        vm.startPrank(charlie);
        _swapExactIn(
            "FXPoolTest: testSwapDiffDecimalsUsdcInXsgdOut",
            FX_POOL,
            xsgd,
            usdc2,
            swapAmount,
            0, // check
            charlie
        );

        vm.stopPrank();
    }

    function testSortPositions() public {
        _deployDaiUsdcPool(100 * 1e18);
        IERC20[] memory tokens = vault.getPoolTokens(FX_POOL);

        assertEq(
            address(tokens[0]),
            IFXPool(FX_POOL).isQuoteIndexZero()
                ? IFXPool(FX_POOL).quoteToken()
                : IFXPool(FX_POOL).baseToken()
        );
        assertEq(
            address(tokens[1]),
            IFXPool(FX_POOL).isQuoteIndexZero()
                ? IFXPool(FX_POOL).baseToken()
                : IFXPool(FX_POOL).quoteToken()
        );
    }

    function testSortPositionsViewLiquidity() public {
        _deployDaiUsdcPool(100 * 1e18);

        vm.startPrank(charlie);

        uint256 swapAmount = 10 * 1e18;

        (, uint256[] memory liqBal) = IFXPool(FX_POOL).liquidity();

        // token in is dai, out is usdc2. dai must increase in the pool, usdc2 must decrease
        _swapExactIn(
            "FXPoolTest: testSortPositionsViewLiquidity",
            FX_POOL,
            dai,
            usdc2,
            swapAmount,
            0,
            charlie
        );

        (, uint256[] memory liqBal2) = IFXPool(FX_POOL).liquidity();

        if (IFXPool(FX_POOL).isQuoteIndexZero()) {
            assertTrue(liqBal[0] > liqBal2[0]); // quote
            assertTrue(liqBal2[1] > liqBal[1]); // base
        } else {
            assertTrue(liqBal2[0] > liqBal[0]); // base
            assertTrue(liqBal[1] > liqBal2[1]); // quote
        }

        vm.stopPrank();
    }

    function testPoolPause() public {
        _deployDaiUsdcPool(100 * 1e18);
        vm.prank(adminMultiSig);
        vault.pausePool(FX_POOL);

        assertTrue(vault.isPoolPaused(FX_POOL));
        vm.prank(adminMultiSig);
        vault.unpausePool(FX_POOL);
        assertTrue(!vault.isPoolPaused(FX_POOL));
    }

    function testFailPoolPauseNotPauseAdmin() public {
        _deployDaiUsdcPool(100 * 1e18);
        vault.pausePool(FX_POOL);
    }

    function testInitializeAssetTokenZero() public {
        NewPoolParams memory params = NewPoolParams({
            name: "FX_ERROR",
            symbol: "FX_ERROR",
            protocolPercentFee: 60,
            owner: address(this),
            assets: FXAssets({
                quoteToken: address(0),
                baseToken: address(0),
                quoteWeight: 5e17,
                baseWeight: 5e17
            }),
            greeks: _fxDefaultGreeks()
        });

        BaseAssimilator baseAssim = new BaseAssimilator();
        QuoteAssimilator quoteAssim = new QuoteAssimilator();
        baseAssim.initialize(
            IERC20(address(0)),
            IERC20(address(0)),
            IOracle(address(0))
        );

        vm.expectRevert(bytes("FXP#515"));
        new FXPool(vault, params, address(baseAssim), address(quoteAssim));
    }

    function testWeightMoreThanOne() public {
        NewPoolParams memory params = NewPoolParams({
            name: "FX_ERROR",
            symbol: "FX_ERROR",
            protocolPercentFee: 60,
            owner: address(this),
            assets: FXAssets({
                quoteToken: address(usdc2),
                baseToken: address(dai),
                quoteWeight: 5e18,
                baseWeight: 5e18
            }),
            greeks: _fxDefaultGreeks()
        });
        BaseAssimilator baseAssim = new BaseAssimilator();
        QuoteAssimilator quoteAssim = new QuoteAssimilator();
        baseAssim.initialize(
            IERC20(params.assets.baseToken),
            IERC20(params.assets.quoteToken),
            IOracle(address(new StaticPriceOracle(111, 8, "testOracle")))
        );

        vm.expectRevert(bytes("FXP#517"));
        new FXPool(vault, params, address(baseAssim), address(quoteAssim));
    }

    function testAlphaError() public {
        NewPoolParams memory params = NewPoolParams({
            name: "FX_ERROR",
            symbol: "FX_ERROR",
            protocolPercentFee: 60,
            owner: address(this),
            assets: FXAssets({
                quoteToken: address(usdc2),
                baseToken: address(dai),
                quoteWeight: 5e17,
                baseWeight: 5e17
            }),
            greeks: FXGreeks({
                alpha: 0,
                beta: 0,
                max: 0,
                epsilon: 0,
                lambda: 0,
                kappa: 0
            })
        });

        BaseAssimilator baseAssim = new BaseAssimilator();
        QuoteAssimilator quoteAssim = new QuoteAssimilator();
        baseAssim.initialize(
            IERC20(params.assets.baseToken),
            IERC20(params.assets.quoteToken),
            IOracle(address(new StaticPriceOracle(111, 8, "testOracle")))
        );
        vm.expectRevert(bytes("FXP#518"));
        new FXPool(vault, params, address(baseAssim), address(quoteAssim));
    }

    function testBetaError() public {
        NewPoolParams memory params = NewPoolParams({
            name: "FX_ERROR",
            symbol: "FX_ERROR",
            protocolPercentFee: 60,
            owner: address(this),
            assets: FXAssets({
                quoteToken: address(usdc2),
                baseToken: address(dai),
                quoteWeight: 5e17,
                baseWeight: 5e17
            }),
            greeks: FXGreeks({
                alpha: ALPHA,
                beta: ALPHA,
                max: 0,
                epsilon: 0,
                lambda: 0,
                kappa: 0
            })
        });

        BaseAssimilator baseAssim = new BaseAssimilator();
        QuoteAssimilator quoteAssim = new QuoteAssimilator();
        baseAssim.initialize(
            IERC20(params.assets.baseToken),
            IERC20(params.assets.quoteToken),
            IOracle(address(new StaticPriceOracle(111, 8, "testOracle")))
        );

        vm.expectRevert(bytes("FXP#519"));
        new FXPool(vault, params, address(baseAssim), address(quoteAssim));
    }

    function testMaxError() public {
        NewPoolParams memory params = NewPoolParams({
            name: "FX_ERROR",
            symbol: "FX_ERROR",
            protocolPercentFee: 60,
            owner: address(this),
            assets: FXAssets({
                quoteToken: address(usdc2),
                baseToken: address(dai),
                quoteWeight: 5e17,
                baseWeight: 5e17
            }),
            greeks: FXGreeks({
                alpha: ALPHA,
                beta: BETA,
                max: 5e18,
                epsilon: 0,
                lambda: 0,
                kappa: 0
            })
        });

        BaseAssimilator baseAssim = new BaseAssimilator();
        QuoteAssimilator quoteAssim = new QuoteAssimilator();
        baseAssim.initialize(
            IERC20(params.assets.baseToken),
            IERC20(params.assets.quoteToken),
            IOracle(address(new StaticPriceOracle(111, 8, "testOracle")))
        );

        vm.expectRevert(bytes("FXP#520"));
        new FXPool(vault, params, address(baseAssim), address(quoteAssim));
    }

    function testEpsilonError() public {
        NewPoolParams memory params = NewPoolParams({
            name: "FX_ERROR",
            symbol: "FX_ERROR",
            protocolPercentFee: 60,
            owner: address(this),
            assets: FXAssets({
                quoteToken: address(usdc2),
                baseToken: address(dai),
                quoteWeight: 5e17,
                baseWeight: 5e17
            }),
            greeks: FXGreeks({
                alpha: ALPHA,
                beta: BETA,
                max: MAX,
                epsilon: 1e17,
                lambda: 0,
                kappa: 0
            })
        });

        BaseAssimilator baseAssim = new BaseAssimilator();
        QuoteAssimilator quoteAssim = new QuoteAssimilator();
        baseAssim.initialize(
            IERC20(params.assets.baseToken),
            IERC20(params.assets.quoteToken),
            IOracle(address(new StaticPriceOracle(111, 8, "testOracle")))
        );

        vm.expectRevert(bytes("FXP#521"));
        new FXPool(vault, params, address(baseAssim), address(quoteAssim));
    }

    function testLambdaError() public {
        NewPoolParams memory params = NewPoolParams({
            name: "FX_ERROR",
            symbol: "FX_ERROR",
            protocolPercentFee: 60,
            owner: address(this),
            assets: FXAssets({
                quoteToken: address(usdc2),
                baseToken: address(dai),
                quoteWeight: 5e17,
                baseWeight: 5e17
            }),
            greeks: FXGreeks({
                alpha: ALPHA,
                beta: BETA,
                max: MAX,
                epsilon: EPSILON,
                lambda: 1e19,
                kappa: KAPPA
            })
        });

        BaseAssimilator baseAssim = new BaseAssimilator();
        QuoteAssimilator quoteAssim = new QuoteAssimilator();
        baseAssim.initialize(
            IERC20(params.assets.baseToken),
            IERC20(params.assets.quoteToken),
            IOracle(address(new StaticPriceOracle(111, 8, "testOracle")))
        );

        vm.expectRevert(bytes("FXP#522"));
        new FXPool(vault, params, address(baseAssim), address(quoteAssim));
    }

    function testSwapConvergenceViolation() public {
        _deployDaiUsdcPool(100 * 1e18);
        uint256 swapAmount = 1e36;
        uint256 expectedAmountOut = 9.995 * 1e18;

        vm.prank(charlie);
        vm.expectRevert(bytes("FXP#528"));

        router.swapSingleTokenExactIn(
            FX_POOL,
            dai,
            usdc2,
            swapAmount,
            expectedAmountOut,
            block.timestamp + 1000,
            false,
            abi.encode("")
        );
    }

    function _deployZeroFeeDaiUsdcPool(
        uint256 _depositNumeraire
    )
        private
        returns (
            address fxPool,
            uint256[] memory initAmounts,
            uint256[] memory initAmountsScaled18
        )
    {
        DeployFXPoolParams memory params = DeployFXPoolParams({
            name: "FX_DAI_USDC2",
            lp: lp,
            protocolPercentFee: 0,
            depositNumeraire: _depositNumeraire,
            quoteToken: address(usdc2),
            baseToken: address(dai),
            quoteOracleName: "USDC2 / USD",
            quoteOraclePrice: 100_000_000,
            baseOracleName: "DAI / USD",
            baseOraclePrice: 100_000_000,
            greeks: _fxDefaultGreeks()
        });
        params.greeks.epsilon = 0;
        params.greeks.lambda = 0;

        (fxPool, initAmounts, initAmountsScaled18) = _deployAndInitializeFXPool(
            params
        );
        uint256 lpBalance = IERC20(fxPool).balanceOf(lp);

        // since both oracles are $1 we can assert that the amount of each token taken is equal
        // to at least half of the depositNumeraire
        // ensure that the Vault hasn't taken much more than a bit of dust on top (bc of rounding errors)
        assertLeBoundedPercentMax(
            lpBalance,
            IFXPool(fxPool).convertRawToNumeraire(
                IFXPool(fxPool).tokens(0),
                initAmounts[0]
            ) +
                IFXPool(fxPool).convertRawToNumeraire(
                    IFXPool(fxPool).tokens(1),
                    initAmounts[1]
                ),
            "[_deployZeroFeeDaiUsdcPool] correct amount of tokens taken"
        );
        FX_POOL = fxPool;
    }

    function _deployDaiUsdcPool(
        uint256 _depositNumeraire
    )
        private
        returns (
            address fxPool,
            uint256[] memory initAmounts,
            uint256[] memory initAmountsScaled18
        )
    {
        DeployFXPoolParams memory params = DeployFXPoolParams({
            name: "FX_DAI_USDC2",
            lp: lp,
            protocolPercentFee: 60,
            depositNumeraire: _depositNumeraire,
            quoteToken: address(usdc2),
            baseToken: address(dai),
            quoteOracleName: "USDC2 / USD",
            quoteOraclePrice: 100_000_000,
            baseOracleName: "DAI / USD",
            baseOraclePrice: 100_000_000,
            greeks: _fxDefaultGreeks()
        });

        (fxPool, initAmounts, initAmountsScaled18) = _deployAndInitializeFXPool(
            params
        );
        uint256 lpBalance = IERC20(fxPool).balanceOf(lp);

        // since both oracles are 1:! we can assert that the amount of each token taken is equal
        // to at least half of the depositNumeraire
        // ensure that the Vault hasn't taken much more than a bit of dust on top (bc of rounding errors)
        assertLeBoundedPercentMax(
            lpBalance,
            IFXPool(fxPool).convertRawToNumeraire(
                IFXPool(fxPool).tokens(0),
                initAmounts[0]
            ) +
                IFXPool(fxPool).convertRawToNumeraire(
                    IFXPool(fxPool).tokens(1),
                    initAmounts[1]
                ),
            "[_deployDaiUsdcPool] correct amount of tokens taken"
        );

        FX_POOL = fxPool;
    }

    function _deployXsgdUsdcPool() private {
        DeployFXPoolParams memory params = DeployFXPoolParams({
            name: "FX_XSGD_USDC",
            lp: lp,
            protocolPercentFee: 60,
            depositNumeraire: 20000 * 1e18,
            quoteToken: address(usdc2),
            baseToken: address(xsgd),
            quoteOracleName: "USDC2 / USD",
            quoteOraclePrice: 100_000_000,
            baseOracleName: "SGD / USD",
            baseOraclePrice: 74_376_600,
            greeks: _fxDefaultGreeks()
        });

        (FX_POOL, , ) = _deployAndInitializeFXPool(params);
    }
}
