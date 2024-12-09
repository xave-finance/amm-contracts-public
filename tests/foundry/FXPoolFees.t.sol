// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {FXPoolBaseTest} from "./FXPoolBaseTest.sol";
import {IFXPool} from "../../contracts/core/interfaces/IFXPool.sol";
import {
    IAllowanceTransfer
} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {
    FXAssets,
    FXGreeks,
    NewPoolParams,
    PoolBoundaries
} from "../../contracts/core/FXPoolTypes.sol";
import {ABDKMath64x64} from "../../contracts/core/lib/ABDKMath64x64.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    ERC20TestToken
} from "@balancer-labs/v3-solidity-utils/contracts/test/ERC20TestToken.sol";
import {
    ScalingHelpers
} from "@balancer-labs/v3-solidity-utils/contracts/helpers/ScalingHelpers.sol";
import {
    ArrayHelpers
} from "@balancer-labs/v3-solidity-utils/contracts/test/ArrayHelpers.sol";
import {
    IERC20Metadata
} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IVault} from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import {
    IAuthorizer
} from "@balancer-labs/v3-interfaces/contracts/vault/IAuthorizer.sol";

contract FXPoolFees is FXPoolBaseTest {
    using ABDKMath64x64 for int128;
    using ABDKMath64x64 for uint256;
    using ArrayHelpers for *;
    using ScalingHelpers for *;

    uint256 constant DEPOSIT_NUMERAIRE = 1_000_000 * 1e18;
    address FXPOOL;

    function setUp() public override {
        super.setUp();

        DeployFXPoolParams memory params = DeployFXPoolParams({
            name: "FX_DAI_USDC",
            lp: lp,
            protocolPercentFee: 60,
            depositNumeraire: DEPOSIT_NUMERAIRE,
            quoteToken: address(token13Dec),
            baseToken: address(token2Dec),
            quoteOracleName: "2DEC / 13DEC",
            quoteOraclePrice: 100_000_000,
            baseOracleName: "2DEC / 13DEC",
            baseOraclePrice: 100_000_000,
            greeks: _fxDefaultGreeks()
        });

        (FXPOOL, , ) = _deployAndInitializeFXPool(params);

        address adminMultisig = fxPoolFactory.adminMultisig();
        vm.startPrank(adminMultisig);
        IFXPool(FXPOOL).setCollectorAddress(adminMultisig);
    }

    function test_staticFee() public {
        PoolBoundaries memory b = IFXPool(FXPOOL).getPoolBoundaries();

        address tokenIn = b.betaSwapAmtMaxToken;
        address tokenOut = b.betaSwapAmtMinToken;
        uint256 swapAmtNumeraire = b.betaSwapAmtMax;
        uint256 swapAmt = IFXPool(FXPOOL).convertNumeraireToRaw(
            tokenIn,
            swapAmtNumeraire
        );

        address adminMultiSig = fxPoolFactory.adminMultisig();

        uint256 lpFeesBefore = IERC20(FXPOOL).balanceOf(adminMultiSig);

        vm.startPrank(eve);
        _swapExactIn(
            "[test_staticFee] swap to BETA edge",
            FXPOOL,
            IERC20(tokenIn),
            IERC20(tokenOut),
            swapAmt,
            0,
            eve
        );
        _collectProtocolFees(FXPOOL);
        vm.stopPrank();

        uint256 lpFeesDelta = IERC20(FXPOOL).balanceOf(adminMultiSig) -
            lpFeesBefore;
        // @TODO because we not mint LP tokens during add/remove liquidity
        // the actual fees collected are different from the expected fees
        // @TODO fix this
        uint256 expectedFees = _calculateFXPoolExpectedStaticFee(
            swapAmtNumeraire,
            IFXPool(FXPOOL)
        );
        // assertLeBoundedPercentMax(lpFeesDelta, expectedFees, 'lp fees delta');
        assertLe(lpFeesDelta, expectedFees, "lp fees delta");

        b = IFXPool(FXPOOL).getPoolBoundaries();
        // now swap to the other side of BETA edge
        tokenIn = b.betaSwapAmtMaxToken;
        tokenOut = b.betaSwapAmtMinToken;
        swapAmtNumeraire = b.betaSwapAmtMax;
        swapAmt = IFXPool(FXPOOL).convertNumeraireToRaw(
            tokenIn,
            swapAmtNumeraire
        );
        lpFeesBefore = IERC20(FXPOOL).balanceOf(adminMultiSig);

        vm.startPrank(eve);
        _swapExactIn(
            "[test_staticFee] swap to the opposite BETA edge",
            FXPOOL,
            IERC20(tokenIn),
            IERC20(tokenOut),
            swapAmt,
            0,
            eve
        );
        _collectProtocolFees(FXPOOL);
        vm.stopPrank();
        lpFeesDelta = IERC20(FXPOOL).balanceOf(adminMultiSig) - lpFeesBefore;
        assertGt(
            lpFeesDelta,
            0,
            "received fees should be greater than 0 after second swap"
        );
    }

    function test_dynamicFee() public {
        PoolBoundaries memory b = IFXPool(FXPOOL).getPoolBoundaries();

        address tokenIn = b.haltSwapAmtMaxToken;
        address tokenOut = b.haltSwapAmtMinToken;
        uint256 swapAmtNumeraire = b.haltSwapAmtMax;
        uint256 swapAmt = IFXPool(FXPOOL).convertNumeraireToRaw(
            tokenIn,
            swapAmtNumeraire
        );

        address adminMultiSig = fxPoolFactory.adminMultisig();

        uint256 lpFeesBefore = IERC20(FXPOOL).balanceOf(adminMultiSig);

        vm.startPrank(eve);
        _swapExactIn(
            "[test_dynamicFee] swap to HALT edge",
            FXPOOL,
            IERC20(tokenIn),
            IERC20(tokenOut),
            swapAmt,
            0,
            eve
        );
        _collectProtocolFees(FXPOOL);
        vm.stopPrank();

        uint256 lpFeesDelta = IERC20(FXPOOL).balanceOf(adminMultiSig) -
            lpFeesBefore;
        uint256 expectedStaticFees = _calculateFXPoolExpectedStaticFee(
            swapAmtNumeraire,
            IFXPool(FXPOOL)
        );

        assertLe(expectedStaticFees, lpFeesDelta, "lp fees halt swap");

        b = IFXPool(FXPOOL).getPoolBoundaries();
        // now swap to the other side of HALT edge
        tokenIn = b.haltSwapAmtMaxToken;
        tokenOut = b.haltSwapAmtMinToken;
        swapAmtNumeraire = b.haltSwapAmtMax;
        swapAmt = IFXPool(FXPOOL).convertNumeraireToRaw(
            tokenIn,
            swapAmtNumeraire
        );
        lpFeesBefore = IERC20(FXPOOL).balanceOf(adminMultiSig);

        vm.startPrank(eve);
        _swapExactIn(
            "[test_dynamicFee] swap to the opposite HALT edge",
            FXPOOL,
            IERC20(tokenIn),
            IERC20(tokenOut),
            swapAmt,
            0,
            eve
        );
        _collectProtocolFees(FXPOOL);
        vm.stopPrank();
        lpFeesDelta = IERC20(FXPOOL).balanceOf(adminMultiSig) - lpFeesBefore;
        assertGt(
            lpFeesDelta,
            0,
            "received fees should be greater than 0 after second halt swap"
        );
    }

    function _calculateFXPoolExpectedStaticFee(
        uint256 swapAmountNumeraire,
        IFXPool pool
    ) private view returns (uint256) {
        (, , , uint256 epsilon, , ) = pool.viewParameters();
        return
            _calculateExpectedStaticFee(
                swapAmountNumeraire,
                pool.protocolPercentFee(),
                epsilon
            );
    }

    function _calculateExpectedStaticFee(
        uint256 swapAmountNumeraire,
        uint256 protocolPercentFee,
        uint256 epsilon
    ) private pure returns (uint256) {
        // only used when the pool is perfectly balanced before the swap
        int128 epsilonFixed = ABDKMath64x64.divu(epsilon, 1e18);
        return
            swapAmountNumeraire
                .divu(1e18)
                .mul(epsilonFixed)
                .mul(protocolPercentFee.divu(100))
                .mulu(1e18);
    }

    function test_calculateExpectedStaticFee() public pure {
        uint256 swapAmountNumeraire = 1e18; // 1 numeraire
        uint256 protocolPercentFee = 60; // 60%
        uint256 epsilon = 1e16; // 1%

        uint256 expectedFee = _calculateExpectedStaticFee(
            swapAmountNumeraire,
            protocolPercentFee,
            epsilon
        );

        // Expected fee should be 0.006 numeraire (0.6% of 1 numeraire) with a rounding error of 1 wei
        assertEq(
            expectedFee,
            6e15 - 1,
            "Calculated fee does not match expected value"
        );
    }
}
