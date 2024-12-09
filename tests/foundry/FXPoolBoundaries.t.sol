// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FXPoolBaseTest} from "./FXPoolBaseTest.sol";
import {IFXPool} from "../../contracts/core/interfaces/IFXPool.sol";
import {
    FXAssets,
    FXGreeks,
    NewPoolParams,
    PoolBoundaries
} from "../../contracts/core/FXPoolTypes.sol";

contract FXPoolBoundariesTest is FXPoolBaseTest {
    uint256 constant INITIAL_DEPOSIT_NUMERAIRE = 100_000 * 1e18;

    /**
     * @dev Tests the calculation of boundaries in the FXPool.
     *
     * This test function verifies the following functions:
     * - IFXPool.isInBeta()
     * - IFXPool.isBalanced()
     * - IFXPool.viewSwapToBalancePool()
     */
    function testBalancedAndBeta() public {
        address fxPool = _deployZeroFeeFXPool(
            INITIAL_DEPOSIT_NUMERAIRE,
            charlie,
            address(token13Dec),
            address(token2Dec)
        );
        _approveUser(eve, fxPool, address(token13Dec), address(token2Dec));

        ////////////////////////////////////////////////////////////////////////
        // Test initial state
        ////////////////////////////////////////////////////////////////////////
        (bool isInBeta, uint256 amtBackToBeta, address tokenIn) = IFXPool(
            fxPool
        ).isInBeta();
        assertTrue(isInBeta, "Initial state: should be within beta");
        assertEq(amtBackToBeta, 0, "Initial state: amtBackToBeta should be 0");
        assertEq(
            tokenIn,
            address(0),
            "Initial state: tokenIn should be address(0)"
        );
        assertTrue(
            IFXPool(fxPool).isBalanced(),
            "Initial state: should be balanced"
        );
        (
            address fromToken,
            address toToken,
            uint256 rawAmount,
            uint256 numeraireAmount
        ) = IFXPool(fxPool).viewSwapToBalancePool();
        assertEq(
            fromToken,
            address(0),
            "[Initial state: viewSwapToBalancePool] fromToken should be address(0)"
        );
        assertEq(
            toToken,
            address(0),
            "[Initial state: viewSwapToBalancePool] toToken should be address(0)"
        );
        assertEq(
            rawAmount,
            0,
            "[Initial state: viewSwapToBalancePool] rawAmount should be 0"
        );
        assertEq(
            numeraireAmount,
            0,
            "[Initial state: viewSwapToBalancePool] numeraireAmount should be 0"
        );
        ////////////////////////////////////////////////////////////////////////
        // Swap #1 - swap within the 1% balanced threshold (slightly less than 0.5%
        ////////////////////////////////////////////////////////////////////////
        uint256 swapAmount = IFXPool(fxPool).convertNumeraireToRaw(
            address(token2Dec),
            (INITIAL_DEPOSIT_NUMERAIRE / 200) - 1
        );

        vm.startPrank(eve);
        _swapExactIn(
            "[testBalancedAndBeta] swap #1 to within balanced threshold",
            fxPool,
            token2Dec,
            token13Dec,
            swapAmount,
            0,
            eve
        );
        vm.stopPrank();
        assertTrue(
            IFXPool(fxPool).isBalanced(),
            "After swap #1: should be balanced"
        );
        (isInBeta, amtBackToBeta, tokenIn) = IFXPool(fxPool).isInBeta();
        assertTrue(isInBeta, "After swap #1: should be within beta");
        assertEq(amtBackToBeta, 0, "After swap #1: amtBackToBeta should be 0");
        assertEq(
            tokenIn,
            address(0),
            "After swap #1: tokenIn should be address(0)"
        );

        (fromToken, toToken, rawAmount, numeraireAmount) = IFXPool(fxPool)
            .viewSwapToBalancePool();
        assertEq(
            fromToken,
            address(0),
            "After swap #1: fromToken should be address(0)"
        );
        assertEq(
            toToken,
            address(0),
            "After swap #1: toToken should be address(0)"
        );
        assertEq(rawAmount, 0, "After swap #1: rawAmount should be 0");
        assertEq(
            numeraireAmount,
            0,
            "After swap #1: numeraireAmount should be 0"
        );

        ////////////////////////////////////////////////////////////////////////
        // Swap #2 - swap within the 2% balanced threshold in the opposite direction
        ////////////////////////////////////////////////////////////////////////
        swapAmount = IFXPool(fxPool).convertNumeraireToRaw(
            address(token13Dec),
            INITIAL_DEPOSIT_NUMERAIRE / 101
        );

        vm.startPrank(eve);
        _swapExactIn(
            "[testBalancedAndBeta] swap #2 to within balanced threshold opposite direction",
            fxPool,
            token13Dec,
            token2Dec,
            swapAmount,
            0,
            eve
        );
        vm.stopPrank();
        assertTrue(
            IFXPool(fxPool).isBalanced(),
            "After swap #2: should be balanced"
        );
        (isInBeta, amtBackToBeta, tokenIn) = IFXPool(fxPool).isInBeta();
        assertTrue(isInBeta, "After swap #2: should be within beta");
        assertEq(amtBackToBeta, 0, "After swap #2: amtBackToBeta should be 0");
        assertEq(
            tokenIn,
            address(0),
            "After swap #2: tokenIn should be address(0)"
        );

        (fromToken, toToken, rawAmount, numeraireAmount) = IFXPool(fxPool)
            .viewSwapToBalancePool();
        assertEq(
            fromToken,
            address(0),
            "After swap #2: fromToken should be address(0)"
        );
        assertEq(
            toToken,
            address(0),
            "After swap #2: toToken should be address(0)"
        );
        assertEq(rawAmount, 0, "After swap #2: rawAmount should be 0");
        assertEq(
            numeraireAmount,
            0,
            "After swap #2: numeraireAmount should be 0"
        );

        ////////////////////////////////////////////////////////////////////////
        // Swap #3 - swap just past the balanced threshold
        ////////////////////////////////////////////////////////////////////////
        swapAmount = 0.1 * 1e18;

        vm.startPrank(eve);
        _swapExactIn(
            "[testBalancedAndBeta] swap #3 outside of balanced threshold",
            fxPool,
            token13Dec,
            token2Dec,
            swapAmount,
            0,
            eve
        );
        vm.stopPrank();
        assertFalse(
            IFXPool(fxPool).isBalanced(),
            "After swap #3: should NOT be balanced"
        );
        (isInBeta, amtBackToBeta, tokenIn) = IFXPool(fxPool).isInBeta();
        assertTrue(isInBeta, "After swap #3: should be within beta");
        assertEq(amtBackToBeta, 0, "After swap #3: amtBackToBeta should be 0");
        assertEq(
            tokenIn,
            address(0),
            "After swap #3: tokenIn should be address(0)"
        );

        (fromToken, toToken, rawAmount, numeraireAmount) = IFXPool(fxPool)
            .viewSwapToBalancePool();
        assertEq(
            fromToken,
            address(token2Dec),
            "After swap #3: fromToken should be token2Dec"
        );
        assertEq(
            toToken,
            address(token13Dec),
            "After swap #3: toToken should be token13Dec"
        );

        // at this point the liquidity in the pool is roughly:
        //   - token13Dec: 60,500
        //   - token2Dec: 39,500
        assertApproxEqPctAbs(
            rawAmount,
            IFXPool(fxPool).convertNumeraireToRaw(
                address(token2Dec),
                10_500 * 1e18
            ),
            10_000, // accept a 0.1% difference
            "After swap #3: rawAmount"
        );

        assertApproxEqPctAbs(
            numeraireAmount,
            10_500 * 1e18,
            10_000,
            "After swap #3: numeraireAmount"
        );
    }

    /**
     * @dev Tests the calculation of boundaries in the FXPool.
     *
     * This test function verifies the following functions:
     * - IFXPool.isInBeta()
     * - IFXPool.isBalanced()
     * - IFXPool.getPoolBoundaries()
     * - IFXPool.isSwapWithinBeta()
     * - IFXPool.viewSwapToBalancePool()
     */
    function testGetPoolBoundaries() public {
        address fxPool = _deployZeroFeeFXPool(
            INITIAL_DEPOSIT_NUMERAIRE,
            charlie,
            address(token13Dec),
            address(token2Dec)
        );
        _approveUser(eve, fxPool, address(token13Dec), address(token2Dec));

        ////////////////////////////////////////////////////////////////////////
        // Test initial state
        ////////////////////////////////////////////////////////////////////////
        (bool isInBeta, uint256 amtBackToBeta, address tokenIn) = IFXPool(
            fxPool
        ).isInBeta();
        assertTrue(isInBeta, "Initial state: should be within beta");
        assertEq(amtBackToBeta, 0, "Initial state: amtBackToBeta should be 0");
        assertEq(
            tokenIn,
            address(0),
            "Initial state: tokenIn should be address(0)"
        );

        assertTrue(
            IFXPool(fxPool).isBalanced(),
            "Initial state: should be balanced"
        );

        (
            address fromToken,
            address toToken,
            uint256 rawAmount,
            uint256 numeraireAmount
        ) = IFXPool(fxPool).viewSwapToBalancePool();
        assertEq(
            fromToken,
            address(0),
            "[Initial state: viewSwapToBalancePool] fromToken should be address(0)"
        );
        assertEq(
            toToken,
            address(0),
            "[Initial state: viewSwapToBalancePool] toToken should be address(0)"
        );
        assertEq(
            rawAmount,
            0,
            "[Initial state: viewSwapToBalancePool] rawAmount should be 0"
        );
        assertEq(
            numeraireAmount,
            0,
            "[Initial state: viewSwapToBalancePool] numeraireAmount should be 0"
        );

        PoolBoundaries memory b = IFXPool(fxPool).getPoolBoundaries();
        PoolBoundaries memory bhbExpected = PoolBoundaries({
            upperBeta: 74_000 * 1e18,
            lowerBeta: 26_000 * 1e18,
            betaSwapAmtMin: 24_000 * 1e18,
            betaSwapAmtMinToken: address(token2Dec),
            betaSwapAmtMax: 24_000 * 1e18,
            betaSwapAmtMaxToken: address(token13Dec),
            lowerHalt: 10_000 * 1e18,
            upperHalt: 90_000 * 1e18,
            haltSwapAmtMin: 40_000 * 1e18,
            haltSwapAmtMax: 40_000 * 1e18,
            // when pool is balanced halts are equal distance
            // depending on dust and rounding errors, this value will tilt to either side of the pool
            haltSwapAmtMinToken: address(token2Dec),
            haltSwapAmtMaxToken: address(token13Dec),
            isWithinBeta: true,
            isBalanced: true,
            balancedSwapAmt: 0,
            balancedSwapToken: address(0)
        });

        _assertBetaHaltBoundaries("[Initial state]", b, bhbExpected);
        // test isSwapWithinBeta
        assertTrue(
            IFXPool(fxPool).isSwapWithinBeta(
                address(token2Dec),
                IFXPool(fxPool).convertNumeraireToRaw(
                    address(token2Dec),
                    20_000 * 1e18
                )
            ),
            "[Initial state] 20_000 numeraire swap should be within beta"
        );
        assertTrue(
            IFXPool(fxPool).isSwapWithinBeta(
                address(b.betaSwapAmtMinToken),
                IFXPool(fxPool).convertNumeraireToRaw(
                    b.betaSwapAmtMinToken,
                    b.betaSwapAmtMin
                )
            ),
            "[Initial state] betaSwapAmtMin numeraire swap should be within beta"
        );
        assertFalse(
            IFXPool(fxPool).isSwapWithinBeta(
                address(b.betaSwapAmtMinToken),
                // adding 3 wei numeraire becasue +1 is sometimes too small and gets rounded down
                IFXPool(fxPool).convertNumeraireToRaw(
                    b.betaSwapAmtMinToken,
                    b.betaSwapAmtMin
                ) + 3
            ),
            "[Initial state] betaSwapAmtMin + 3 numeraire swap should be outside beta"
        );
        assertTrue(
            IFXPool(fxPool).isSwapWithinBeta(
                address(b.betaSwapAmtMaxToken),
                IFXPool(fxPool).convertNumeraireToRaw(
                    b.betaSwapAmtMaxToken,
                    b.betaSwapAmtMax
                )
            ),
            "[Initial state] betaSwapAmtMax numeraire swap should be within beta"
        );
        assertFalse(
            IFXPool(fxPool).isSwapWithinBeta(
                address(b.betaSwapAmtMaxToken),
                // adding 3 wei numeraire becasue +1 is sometimes too small and gets rounded down
                IFXPool(fxPool).convertNumeraireToRaw(
                    b.betaSwapAmtMaxToken,
                    b.betaSwapAmtMax
                ) + 3
            ),
            "[Initial state] betaSwapAmtMax + 3 numeraire swap should be outside beta"
        );

        ////////////////////////////////////////////////////////////////////////
        // swap to create an imbalance in the pool but still stay within beta boundaries
        ////////////////////////////////////////////////////////////////////////
        uint256 swapAmount = IFXPool(fxPool).convertNumeraireToRaw(
            address(token2Dec),
            20_000 * 1e18
        );

        vm.startPrank(eve);
        (uint256 inAmt, uint256 outAmt) = _swapExactIn(
            "[testgetBetaAndHaltBoundaries] swap to within BETA",
            fxPool,
            token2Dec,
            token13Dec,
            swapAmount,
            0,
            eve
        );
        vm.stopPrank();

        (fromToken, toToken, rawAmount, numeraireAmount) = IFXPool(fxPool)
            .viewSwapToBalancePool();
        assertEq(
            fromToken,
            address(token13Dec),
            "[swapped within BETA] fromToken should be token13Dec"
        );
        assertApproxEqPctAbsMax(
            tokenAmountScaled18(rawAmount, address(token13Dec)),
            tokenAmountScaled18(swapAmount, address(token2Dec)),
            "[swapped within BETA] rawAmount should be equal to the previous swap amount"
        );
        assertApproxEqPctAbsMax(
            numeraireAmount,
            IFXPool(fxPool).convertRawToNumeraire(
                address(token13Dec),
                rawAmount
            ),
            "[swapped within BETA] numeraireAmount should be equal to the previous swap amount"
        );

        // since: 1) we're still within the BETA region and 2) both oracles are 1:1 vs USD and 3) no fees
        // the input and output amounts should be equal
        assertApproxEqPctAbsMax(
            inAmt,
            swapAmount,
            "Swap took the correct amount of tokens instructed as amount in"
        );
        assertApproxEqPctAbsMax(
            IFXPool(fxPool).convertRawToNumeraire(address(token2Dec), inAmt),
            IFXPool(fxPool).convertRawToNumeraire(address(token13Dec), outAmt),
            "[swapped within Beta] Within Beta region & no fees, the input and output amounts of a swap should be equal"
        );

        b = IFXPool(fxPool).getPoolBoundaries();
        bhbExpected = PoolBoundaries({
            upperBeta: 74_000 * 1e18,
            lowerBeta: 26_000 * 1e18,
            betaSwapAmtMin: 4_000 * 1e18,
            // we swapped XSGD for USDC, therefore the pool has more XSGD now
            // so the betaSwapAmtMinToken should be XSGD
            betaSwapAmtMinToken: address(token2Dec),
            betaSwapAmtMax: 44_000 * 1e18,
            betaSwapAmtMaxToken: address(token13Dec),
            lowerHalt: 10_000 * 1e18,
            upperHalt: 90_000 * 1e18,
            haltSwapAmtMin: 20_000 * 1e18,
            haltSwapAmtMax: 60_000 * 1e18,
            haltSwapAmtMinToken: address(token2Dec),
            haltSwapAmtMaxToken: address(token13Dec),
            isWithinBeta: true,
            isBalanced: false,
            balancedSwapAmt: 20_000 * 1e18,
            balancedSwapToken: address(token13Dec)
        });
        _assertBetaHaltBoundaries(
            "[swapped within BETA] After swap within BETA (more XSGD)",
            b,
            bhbExpected
        );
        (isInBeta, amtBackToBeta, tokenIn) = IFXPool(fxPool).isInBeta();
        assertTrue(isInBeta, "[swapped within Beta]: should be within beta");
        assertEq(
            amtBackToBeta,
            0,
            "[swapped within Beta]: amtBackToBeta should be 0"
        );
        assertEq(
            tokenIn,
            address(0),
            "[swapped within Beta]: tokenIn should be address(0)"
        );

        ////////////////////////////////////////////////////////////////////////
        // swap the opposite way, at the edge of the beta range
        ////////////////////////////////////////////////////////////////////////
        swapAmount = IFXPool(fxPool).convertNumeraireToRaw(
            address(token13Dec),
            b.betaSwapAmtMax
        );

        vm.startPrank(eve);
        (inAmt, outAmt) = _swapExactIn(
            "[testgetBetaAndHaltBoundaries] swap to BETA edge",
            fxPool,
            token13Dec,
            token2Dec,
            swapAmount,
            0,
            eve
        );
        vm.stopPrank();

        // since: 1) we're still within the BETA region and 2) both oracles are 1:1 vs USD and 3) no fees
        // the input and output amounts should be equal
        assertApproxEqPctAbsMax(
            inAmt,
            swapAmount,
            "Swap took the correct amount of tokens instructed as amount in"
        );
        assertApproxEqPctAbsMax(
            IFXPool(fxPool).convertRawToNumeraire(address(token13Dec), inAmt),
            IFXPool(fxPool).convertRawToNumeraire(address(token2Dec), outAmt),
            "[swapped to BETA edge] Within Beta region & no fees, the input and output amounts of a swap should be equal"
        );

        b = IFXPool(fxPool).getPoolBoundaries();
        bhbExpected = PoolBoundaries({
            upperBeta: 74_000 * 1e18,
            lowerBeta: 26_000 * 1e18,
            betaSwapAmtMin: 0,
            betaSwapAmtMinToken: address(token13Dec),
            betaSwapAmtMax: 48_000 * 1e18,
            betaSwapAmtMaxToken: address(token2Dec),
            lowerHalt: 10_000 * 1e18,
            upperHalt: 90_000 * 1e18,
            haltSwapAmtMin: 16_000 * 1e18,
            haltSwapAmtMax: 64_000 * 1e18,
            haltSwapAmtMinToken: address(token13Dec),
            haltSwapAmtMaxToken: address(token2Dec),
            isWithinBeta: true,
            isBalanced: false,
            // we're at 74_000 numeraire on one side therefore we need to
            // swap back 24_000 to reach 50_000 numeraire on each side
            balancedSwapAmt: 24_000 * 1e18,
            balancedSwapToken: address(token2Dec)
        });
        _assertBetaHaltBoundaries(
            "[swapped to BETA edge] After swap to BETA edge (more USDC)",
            b,
            bhbExpected
        );
        (isInBeta, amtBackToBeta, tokenIn) = IFXPool(fxPool).isInBeta();
        assertTrue(isInBeta, "[swapped to BETA edge]: should be within beta");
        assertEq(
            amtBackToBeta,
            0,
            "[swapped to BETA edge]: amtBackToBeta should be 0"
        );
        assertEq(
            tokenIn,
            address(0),
            "[swapped to BETA edge]: tokenIn should be address(0)"
        );

        (fromToken, toToken, rawAmount, numeraireAmount) = IFXPool(fxPool)
            .viewSwapToBalancePool();
        assertEq(
            fromToken,
            address(token2Dec),
            "[swapped to BETA edge] fromToken should be token2Dec"
        );
        assertEq(
            toToken,
            address(token13Dec),
            "[swapped to BETA edge] toToken should be token13Dec"
        );
        assertApproxEqPctAbsMax(
            rawAmount,
            tokenAmount(24_000, address(token2Dec)),
            "[swapped to BETA edge] rawAmount"
        );
        assertApproxEqPctAbsMax(
            numeraireAmount,
            IFXPool(fxPool).convertRawToNumeraire(
                address(token2Dec),
                tokenAmount(24_000, address(token2Dec))
            ),
            "[swapped to BETA edge] numeraireAmount"
        );

        ////////////////////////////////////////////////////////////////////////
        // swap to go OUTSIDE BETA boundary
        ////////////////////////////////////////////////////////////////////////
        swapAmount = IFXPool(fxPool).convertNumeraireToRaw(
            address(token13Dec),
            1_000 * 1e18
        );
        vm.startPrank(eve);
        (inAmt, outAmt) = _swapExactIn(
            "[testgetBetaAndHaltBoundaries] swap OUTSIDE BETA",
            fxPool,
            token13Dec,
            token2Dec,
            swapAmount,
            0,
            eve
        );
        vm.stopPrank();
        assertApproxEqPctAbsMax(
            inAmt,
            swapAmount,
            "[swapped OUTSIDE BETA edge] Swap took the correct amount of tokens instructed as amount in"
        );
        // even though the fixed and dynamic fees are 0, the delta param is non-0 therefore
        // there is a fee applied to the swap when it goes OUTSIDE BETA boundaries
        assertApproxEqPctAbsMax(
            989.237187 * 1e18,
            IFXPool(fxPool).convertRawToNumeraire(address(token2Dec), outAmt),
            "[swapped OUTSIDE BETA edge] Swap gave the correct amount of tokens"
        );
        b = IFXPool(fxPool).getPoolBoundaries();
        // because swapping outside BETA region (with a non-0 delta param) generates a fee for the pool
        // the pool's liquidity has changed now and the beta and halt boundaries are different
        bhbExpected = PoolBoundaries({
            upperBeta: 74_007.96 * 1e18,
            lowerBeta: 26_002.79 * 1e18,
            betaSwapAmtMin: 992.035 * 1e18,
            betaSwapAmtMinToken: address(token2Dec),
            betaSwapAmtMax: 48_997.201 * 1e18,
            betaSwapAmtMaxToken: address(token13Dec),
            lowerHalt: 10_001.076 * 1e18,
            upperHalt: 90_009.686 * 1e18,
            haltSwapAmtMin: 15_009.686 * 1e18,
            haltSwapAmtMax: 64_998.923 * 1e18,
            haltSwapAmtMinToken: address(token13Dec),
            haltSwapAmtMaxToken: address(token2Dec),
            isWithinBeta: false,
            isBalanced: false,
            // we were roughly 24_000 from balanced state, and we swapped 1_000 further out
            // there's a slight delta fee that was applied to the swap hence the difference
            balancedSwapAmt: 24_994.46 * 1e18,
            balancedSwapToken: address(token2Dec)
        });
        _assertBetaHaltBoundaries(
            "[swapped OUTSIDE BETA (more USDC)] After swap",
            b,
            bhbExpected
        );
        (isInBeta, amtBackToBeta, tokenIn) = IFXPool(fxPool).isInBeta();
        assertFalse(
            isInBeta,
            "[swapped OUTSIDE BETA (more USDC)]: should be outside beta"
        );
        assertEq(
            amtBackToBeta,
            b.betaSwapAmtMin,
            "[swapped OUTSIDE BETA (more USDC)]: amtBackToBeta should be betaSwapAmtMin"
        );
        assertEq(
            tokenIn,
            b.betaSwapAmtMinToken,
            "[swapped OUTSIDE BETA (more USDC)]: tokenIn should be betaSwapAmtMinToken"
        );

        ////////////////////////////////////////////////////////////////////////
        // swap back inside BETA boundary (minimum volume)
        ////////////////////////////////////////////////////////////////////////
        swapAmount = IFXPool(fxPool).convertNumeraireToRaw(
            address(token2Dec),
            b.betaSwapAmtMin
        );
        vm.startPrank(eve);
        (inAmt, outAmt) = _swapExactIn(
            "[testgetBetaAndHaltBoundaries] swap back inside BETA",
            fxPool,
            token2Dec,
            token13Dec,
            // ensure that we swap all the way back to the _inside_ edge of the beta boundary
            // without the +1 the swap will position the pool outside the edge of the beta boundary
            // and the isWithinBeta flag will be false
            swapAmount + 1,
            0,
            eve
        );
        vm.stopPrank();
        assertApproxEqPctAbsMax(
            inAmt,
            swapAmount,
            "[swapped back inside BETA] Swap took the correct amount of tokens instructed as amount in"
        );
        // because there is no dynamic fee, there is no reward for swapping back inside BETA
        assertApproxEqPctAbsMax(
            IFXPool(fxPool).convertRawToNumeraire(address(token2Dec), inAmt),
            IFXPool(fxPool).convertRawToNumeraire(address(token13Dec), outAmt),
            "[swapped back inside BETA] Swap gave the correct amount of tokens"
        );
        b = IFXPool(fxPool).getPoolBoundaries();
        // because swapping outside BETA region (with a non-0 delta param) generates a fee for the pool
        // the pool's liquidity has changed now and the beta and halt boundaries are different
        bhbExpected = PoolBoundaries({
            upperBeta: 74_007.96 * 1e18,
            lowerBeta: 26_002.79 * 1e18,
            betaSwapAmtMin: 0,
            betaSwapAmtMinToken: address(token13Dec),
            betaSwapAmtMax: 48_005.166 * 1e18,
            betaSwapAmtMaxToken: address(token2Dec),
            lowerHalt: 10_001.076 * 1e18,
            upperHalt: 90_009.686 * 1e18,
            haltSwapAmtMin: 16_001.722 * 1e18,
            haltSwapAmtMax: 64_006.888 * 1e18,
            haltSwapAmtMinToken: address(token13Dec),
            haltSwapAmtMaxToken: address(token2Dec),
            isWithinBeta: true,
            isBalanced: false,
            // we're back at the beta edge (74k), with slightly more liquidity in the pool
            balancedSwapAmt: 24_002.5 * 1e18,
            balancedSwapToken: address(token2Dec)
        });
        _assertBetaHaltBoundaries(
            "[swapped back inside BETA] After swap",
            b,
            bhbExpected
        );
        (isInBeta, amtBackToBeta, tokenIn) = IFXPool(fxPool).isInBeta();
        assertTrue(
            isInBeta,
            "[swapped back inside BETA]: should be within beta"
        );
        assertEq(
            amtBackToBeta,
            0,
            "[swapped back inside BETA]: amtBackToBeta should be 0"
        );
        assertEq(
            tokenIn,
            address(0),
            "[swapped back inside BETA]: tokenIn should be address(0)"
        );

        ////////////////////////////////////////////////////////////////////////
        // swap to reach HALT boundary (more USDC)
        ////////////////////////////////////////////////////////////////////////
        swapAmount = IFXPool(fxPool).convertNumeraireToRaw(
            address(token13Dec),
            b.haltSwapAmtMin
        );
        vm.startPrank(eve);
        (inAmt, outAmt) = _swapExactIn(
            "[testgetBetaAndHaltBoundaries] swap to HALT (more USDC)",
            fxPool,
            token13Dec,
            token2Dec,
            swapAmount,
            0,
            eve
        );
        vm.stopPrank();
        assertApproxEqPctAbsMax(
            inAmt,
            swapAmount,
            "[swapped to HALT (more USDC)] Swap took the correct amount of tokens instructed as amount in"
        );
        // we swapped 16_000 worth of numeraire and received 13_793.033 worth back
        // this is because the pool is outside the beta boundaries and even without the lambda and epsilon
        // fees, the pool still charges a fee for swaps outside the beta boundaries because of the delta param
        assertApproxEqPctAbsMax(
            13_793.033 * 1e18,
            IFXPool(fxPool).convertRawToNumeraire(address(token2Dec), outAmt),
            "[swapped to HALT (more USDC)] Swap gave the correct amount of tokens"
        );

        b = IFXPool(fxPool).getPoolBoundaries();
        bhbExpected = PoolBoundaries({
            upperBeta: 75_642 * 1e18,
            lowerBeta: 26_577.057 * 1e18,
            betaSwapAmtMin: 14_367.292 * 1e18,
            betaSwapAmtMinToken: address(token2Dec),
            betaSwapAmtMax: 63_432.629 * 1e18,
            betaSwapAmtMaxToken: address(token13Dec),
            lowerHalt: 10_221.945 * 1e18,
            upperHalt: 91_997.505 * 1e18,
            haltSwapAmtMin: 1_987.819 * 1e18,
            haltSwapAmtMax: 79_787.741 * 1e18,
            haltSwapAmtMinToken: address(token13Dec),
            haltSwapAmtMaxToken: address(token2Dec),
            isWithinBeta: false,
            isBalanced: false,
            // pool now has approx 102k liquidity in total and halts are at 10/90
            // therefore balance state is at ~90k - 102k/2 =~ 39k
            balancedSwapAmt: 38_899.96 * 1e18,
            balancedSwapToken: address(token2Dec)
        });
        _assertBetaHaltBoundaries(
            "[swapped to HALT edge] After swap to HALT (more USDC)",
            b,
            bhbExpected
        );
        (isInBeta, amtBackToBeta, tokenIn) = IFXPool(fxPool).isInBeta();
        assertFalse(isInBeta, "[swapped to HALT edge]: should be outside beta");
        assertEq(
            amtBackToBeta,
            b.betaSwapAmtMin,
            "[swapped to HALT edge]: amtBackToBeta should be betaSwapAmtMin"
        );
        assertEq(
            tokenIn,
            b.betaSwapAmtMinToken,
            "[swapped to HALT edge]: tokenIn should be betaSwapAmtMinToken"
        );

        ////////////////////////////////////////////////////////////////////////
        // swap back to balance
        ////////////////////////////////////////////////////////////////////////
        swapAmount = IFXPool(fxPool).convertNumeraireToRaw(
            b.balancedSwapToken,
            b.balancedSwapAmt
        );
        vm.startPrank(eve);
        (inAmt, outAmt) = _swapExactIn(
            "[testgetBetaAndHaltBoundaries] swap to balance",
            fxPool,
            IERC20(b.balancedSwapToken),
            address(token2Dec) == b.balancedSwapToken ? token13Dec : token2Dec,
            swapAmount,
            0,
            eve
        );
        vm.stopPrank();

        b = IFXPool(fxPool).getPoolBoundaries();
        bhbExpected = PoolBoundaries({
            upperBeta: 75_642.4 * 1e18,
            lowerBeta: 26_577.06 * 1e18,
            betaSwapAmtMin: 24_532.66 * 1e18,
            betaSwapAmtMinToken: address(token13Dec),
            betaSwapAmtMax: 24_532.66 * 1e18,
            betaSwapAmtMaxToken: address(token2Dec),
            lowerHalt: 10_221.94 * 1e18,
            upperHalt: 91_997.51 * 1e18,
            haltSwapAmtMin: 40_887.78 * 1e18,
            haltSwapAmtMax: 40_887.78 * 1e18,
            // when pool is balanced halts are equal distance
            // depending on dust and rounding errors, this value will tilt to either side of the pool
            haltSwapAmtMinToken: address(token13Dec),
            haltSwapAmtMaxToken: address(token2Dec),
            isWithinBeta: true,
            isBalanced: true,
            balancedSwapAmt: 0,
            balancedSwapToken: address(0)
        });
        _assertBetaHaltBoundaries(
            "[swapped to balance] After swap to balance",
            b,
            bhbExpected
        );
        (isInBeta, amtBackToBeta, tokenIn) = IFXPool(fxPool).isInBeta();
        assertTrue(isInBeta, "[swapped to balance]: should be inside beta");
        assertEq(
            amtBackToBeta,
            0,
            "[swapped to balance]: amtBackToBeta should be 0"
        );
        assertEq(
            tokenIn,
            address(0),
            "[swapped to balance]: tokenIn should be address(0)"
        );
    }

    function _approveUser(
        address _user,
        address _fxPool,
        address _quoteToken,
        address _baseToken
    ) private {
        // Approve tokens for the _user
        vm.startPrank(_user);
        // _user gives allowance to permit2 to spend their tokens
        IERC20(_quoteToken).approve(address(permit2), type(uint256).max);
        IERC20(_baseToken).approve(address(permit2), type(uint256).max);
        IFXPool(_fxPool).approve(address(permit2), type(uint256).max);
        IFXPool(_fxPool).approve(address(router), type(uint256).max);
        // _user approves permit2 to approve the router to spend the _user's tokens
        permit2.approve(
            _quoteToken,
            address(router),
            type(uint160).max,
            type(uint48).max
        );
        permit2.approve(
            _baseToken,
            address(router),
            type(uint160).max,
            type(uint48).max
        );
        vm.stopPrank();
    }

    function _assertBetaHaltBoundaries(
        string memory label,
        PoolBoundaries memory b,
        PoolBoundaries memory expected
    ) private pure {
        // ensure that min / max tokens are never the same
        assertTrue(
            b.betaSwapAmtMinToken != b.betaSwapAmtMaxToken,
            string(
                abi.encodePacked(
                    "[",
                    label,
                    "] ",
                    "Beta swap min and max tokens are the same"
                )
            )
        );
        assertTrue(
            b.haltSwapAmtMinToken != b.haltSwapAmtMaxToken,
            string(
                abi.encodePacked(
                    "[",
                    label,
                    "] ",
                    "Halt swap min and max tokens are the same"
                )
            )
        );

        assertApproxEqPctAbsMax(
            b.lowerHalt,
            expected.lowerHalt,
            string(abi.encodePacked("[", label, "] ", "Lower halt boundary"))
        );
        assertApproxEqPctAbsMax(
            b.upperHalt,
            expected.upperHalt,
            string(abi.encodePacked("[", label, "] ", "Upper halt boundary"))
        );
        assertApproxEqPctAbsMax(
            b.upperBeta,
            expected.upperBeta,
            string(abi.encodePacked("[", label, "] ", "Upper beta boundary"))
        );
        assertApproxEqPctAbsMax(
            b.lowerBeta,
            expected.lowerBeta,
            string(abi.encodePacked("[", label, "] ", "Lower beta boundary"))
        );

        if (expected.isWithinBeta) {
            assertTrue(
                b.isWithinBeta,
                string(
                    abi.encodePacked("[", label, "] ", "should be within beta")
                )
            );
        } else {
            assertFalse(
                b.isWithinBeta,
                string(
                    abi.encodePacked(
                        "[",
                        label,
                        "] ",
                        "should not be within beta"
                    )
                )
            );
        }

        if (expected.isBalanced) {
            assertTrue(
                b.isBalanced,
                string(abi.encodePacked("[", label, "] ", "should be balanced"))
            );
        } else {
            assertFalse(
                b.isBalanced,
                string(
                    abi.encodePacked("[", label, "] ", "should not be balanced")
                )
            );
        }

        assertEq(
            b.balancedSwapToken,
            expected.balancedSwapToken,
            string(abi.encodePacked("[", label, "] ", "Balanced swap token"))
        );
        assertApproxEqPctAbsMax(
            b.balancedSwapAmt,
            expected.balancedSwapAmt,
            string(abi.encodePacked("[", label, "] ", "Balanced swap amount"))
        );

        // dust and rounding errors can cause the pool to be slightly off the beta boundary
        if (expected.betaSwapAmtMin == 0) {
            assertLe(
                b.betaSwapAmtMin,
                0.01 * 1e18,
                string(
                    abi.encodePacked("[", label, "] ", "Beta swap amount min")
                )
            );
        } else {
            assertApproxEqPctAbsMax(
                b.betaSwapAmtMin,
                expected.betaSwapAmtMin,
                string(
                    abi.encodePacked("[", label, "] ", "Beta swap amount min")
                )
            );
        }

        if (expected.haltSwapAmtMin == 0) {
            assertLe(
                b.haltSwapAmtMin,
                0.01 * 1e18,
                string(
                    abi.encodePacked("[", label, "] ", "Halt swap amount min")
                )
            );
        } else {
            assertApproxEqPctAbsMax(
                b.haltSwapAmtMin,
                expected.haltSwapAmtMin,
                string(
                    abi.encodePacked("[", label, "] ", "Halt swap amount min")
                )
            );
        }

        assertEq(
            b.betaSwapAmtMinToken,
            expected.betaSwapAmtMinToken,
            string(
                abi.encodePacked("[", label, "] ", "Beta swap amount min token")
            )
        );
        assertEq(
            b.betaSwapAmtMaxToken,
            expected.betaSwapAmtMaxToken,
            string(
                abi.encodePacked("[", label, "] ", "Beta swap amount max token")
            )
        );
        assertApproxEqPctAbsMax(
            b.betaSwapAmtMax,
            expected.betaSwapAmtMax,
            string(abi.encodePacked("[", label, "] ", "Beta swap amount max"))
        );
        assertApproxEqPctAbsMax(
            b.haltSwapAmtMax,
            expected.haltSwapAmtMax,
            string(abi.encodePacked("[", label, "] ", "Halt swap amount max"))
        );

        assertEq(
            b.haltSwapAmtMinToken,
            expected.haltSwapAmtMinToken,
            string(
                abi.encodePacked("[", label, "] ", "Halt swap amount min token")
            )
        );
        assertEq(
            b.haltSwapAmtMaxToken,
            expected.haltSwapAmtMaxToken,
            string(
                abi.encodePacked("[", label, "] ", "Halt swap amount max token")
            )
        );
    }
}
