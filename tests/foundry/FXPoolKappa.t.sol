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
    SwapKind
} from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";
import {
    IERC20Metadata
} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IVault} from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import {
    IAuthorizer
} from "@balancer-labs/v3-interfaces/contracts/vault/IAuthorizer.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {FXSwaps} from "../../contracts/core/FXSwaps.sol";

struct RewardData {
    uint256 oBal;
    uint256 nBal;
    uint256 ideal;
    uint256 beta;
    uint256 range;
}

contract FXPoolKappaTest is FXPoolBaseTest {
    using ABDKMath64x64 for int128;
    using ABDKMath64x64 for uint256;
    using ArrayHelpers for *;
    using ScalingHelpers for *;
    using Strings for uint256;

    uint256 constant DEPOSIT_NUMERAIRE = 1_000_000 * 1e18;

    function setUp() public override {
        super.setUp();
    }

    function _deployAndInitializeFXPoolWithKappa(
        uint256 _kappa
    ) internal returns (address fpPool) {
        FXGreeks memory g = _fxDefaultGreeks();
        g.kappa = _kappa;

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
            greeks: g
        });

        (fpPool, , ) = _deployAndInitializeFXPool(params);

        address adminMultisig = fxPoolFactory.adminMultisig();
        vm.startPrank(adminMultisig);
        IFXPool(fpPool).setCollectorAddress(adminMultisig);
    }

    function test_FXSwaps_calculateRewardRange() public pure {
        RewardData[] memory data = new RewardData[](14);
        data[0] = RewardData(13, 67, 50, 0.48 * 1e18, 24); // oBal < ideal
        data[1] = RewardData(67, 13, 50, 0.48 * 1e18, 17); // ideal < oBal
        data[2] = RewardData(13, 80, 50, 0.48 * 1e18, 24); // whole beta range oBal < ideal
        data[3] = RewardData(80, 13, 50, 0.48 * 1e18, 24); // whole beta range ideal < oBal
        data[4] = RewardData(13, 32, 50, 0.48 * 1e18, 6); // oBal < ideal
        data[5] = RewardData(80, 70, 50, 0.48 * 1e18, 4); // ideal < oBal
        data[6] = RewardData(13, 20, 50, 0.48 * 1e18, 0); // oBal < ideal // outside beta range
        data[7] = RewardData(80, 75, 50, 0.48 * 1e18, 0); // ideal < oBal // outside beta range
        data[8] = RewardData(45, 55, 50, 0.48 * 1e18, 5); // oBal < ideal around ideal
        data[9] = RewardData(55, 45, 50, 0.48 * 1e18, 5); // ideal < oBal around ideal
        data[10] = RewardData(50, 50, 50, 0.48 * 1e18, 0); // oBal == nBal == ideal
        data[11] = RewardData(50, 50, 50, 0.48 * 1e18, 0); // oBal == nBal == ideal
        data[12] = RewardData(67, 70, 50, 0.48 * 1e18, 0); // oBal > ideal
        data[13] = RewardData(30, 26, 50, 0.48 * 1e18, 0); // ideal > oBal

        for (uint256 i = 0; i < data.length; i++) {
            if (data[i].oBal == 0) {
                continue;
            }
            int128 range = FXSwaps.calculateRewardRange(
                (data[i].oBal * 1e18).divu(1e18),
                (data[i].nBal * 1e18).divu(1e18),
                (data[i].ideal * 1e18).divu(1e18),
                // round up, same as in `FXPool._setParamsNoCheck`
                (data[i].beta + 1).divu(1e18)
            );
            uint256 errTolerance = 1e5;
            assertApproxEqRel(
                range.mulu(1e18),
                data[i].range * 1e18,
                errTolerance,
                string(
                    abi.encodePacked(
                        "[",
                        i.toString(),
                        "] expected range [",
                        data[i].range.toString(),
                        "] [error tolerance ",
                        errTolerance.toString(),
                        "] ",
                        (data[i].range * 1e18).toString(),
                        " != ",
                        range.mulu(1e18).toString()
                    )
                )
            );
        }
    }

    function test_KappaReward_swapExactIn() public {
        address fxPool = _deployAndInitializeFXPoolWithKappa(2 * EPSILON);
        /**
         * - swap to beta edge
         *             - check that unclaimed fees are correct (increased)
         *       - swap back to balance
         *             - check that unclaimed fees are correct (decreased back to 0)
         *       - swap outside beta
         *             - check that unclaimed fees are correct (increased)
         *       - swap back to balance
         *             - check that unclaimed fees are correct (decreased but not to 0 since base fee is applied outside beta)
         */
        int256 fees = IFXPool(fxPool).unclaimedProtocolFeesNumeraire();
        assertEq(
            fees,
            0,
            "[test_KappaReward_swapExactIn] unclaimedProtocolFeesNumeraire should be 0"
        );

        // swap to beta edge
        _swapToMaxBetaEdge(fxPool, eve, SwapKind.EXACT_IN);
        fees = IFXPool(fxPool).unclaimedProtocolFeesNumeraire();
        assertGt(
            fees,
            0,
            "[test_KappaReward_swapExactIn] unclaimedProtocolFeesNumeraire should be positive"
        );
        assertApproxEqPctAbsMax(
            uint256(fees),
            72 * 1e18,
            "[test_KappaReward_swapExactIn] unclaimedProtocolFeesNumeraire should be 72"
        );

        // swap back to balance
        _swapToBalance(fxPool, eve, SwapKind.EXACT_IN);
        // fees should be 0 bc Kappa is 2 * EPSILON
        assertLt(
            uint256(IFXPool(fxPool).unclaimedProtocolFeesNumeraire()),
            0.1 * 1e18,
            "[test_KappaReward_swapExactIn] unclaimedProtocolFeesNumeraire should be approx 0"
        );
        assertLt(
            IFXPool(fxPool).unclaimedProtocolFeesNumeraire(),
            fees,
            "[test_KappaReward_swapExactIn] unclaimedProtocolFeesNumeraire should have decreased because of KAPPA"
        );
        fees = IFXPool(fxPool).unclaimedProtocolFeesNumeraire();
        // fees > 0 so we can cast to uint256 later on
        assertGt(
            fees,
            0,
            "[test_KappaReward_swapExactIn] unclaimedProtocolFeesNumeraire should be positive"
        );

        // swap outside beta
        _swapToMaxHalt(fxPool, eve);
        assertGt(
            IFXPool(fxPool).unclaimedProtocolFeesNumeraire(),
            fees,
            "[test_KappaReward_swapExactIn] fees should increased"
        );

        // swap back to balance
        _swapToBalance(fxPool, eve, SwapKind.EXACT_IN);

        assertGt(
            IFXPool(fxPool).unclaimedProtocolFeesNumeraire(),
            fees,
            "[test_KappaReward_swapExactIn] unclaimedProtocolFeesNumeraire should increased because of dynamic fee and KAPPA"
        );
        // @TODO compare fees when kappa == 0 and fees when kappa > epsilon when doing outside of beta swaps
    }

    function test_KappaReward_swapExactOut() public {
        address fxPool = _deployAndInitializeFXPoolWithKappa(2 * EPSILON);
        /**
         * - swap to beta edge
         *             - check that unclaimed fees are correct (increased)
         *       - swap back to balance
         *             - check that unclaimed fees are correct (decreased back to 0)
         *       - swap outside beta
         *             - check that unclaimed fees are correct (increased)
         *       - swap back to balance
         *             - check that unclaimed fees are correct (decreased but not to 0 since base fee is applied outside beta)
         */
        int256 fees = IFXPool(fxPool).unclaimedProtocolFeesNumeraire();
        assertEq(
            fees,
            0,
            "[test_KappaReward_swapExactOut] unclaimedProtocolFeesNumeraire should be 0"
        );

        // swap to beta edge
        _swapToMaxBetaEdge(fxPool, eve, SwapKind.EXACT_OUT);

        fees = IFXPool(fxPool).unclaimedProtocolFeesNumeraire();

        assertGt(
            fees,
            0,
            "[test_KappaReward_swapExactOut] unclaimedProtocolFeesNumeraire should be positive"
        );
        assertApproxEqPctAbsMax(
            uint256(fees),
            72 * 1e18,
            "[test_KappaReward_swapExactOut] unclaimedProtocolFeesNumeraire should be 72"
        );

        assertGt(
            fees,
            0,
            "[test_KappaReward_swapExactOut] unclaimedProtocolFeesNumeraire should be positive"
        );

        // swap back to balance
        _swapToBalance(fxPool, eve, SwapKind.EXACT_OUT);
        // fees should be 0 bc Kappa is 2 * EPSILON
        assertLt(
            uint256(IFXPool(fxPool).unclaimedProtocolFeesNumeraire()),
            0.1 * 1e18,
            "[test_KappaReward_swapExactOut] unclaimedProtocolFeesNumeraire should be approx 0"
        );
        assertLt(
            IFXPool(fxPool).unclaimedProtocolFeesNumeraire(),
            fees,
            "[test_KappaReward_swapExactOut] unclaimedProtocolFeesNumeraire should have decreased because of KAPPA"
        );

        assertLt(
            IFXPool(fxPool).unclaimedProtocolFeesNumeraire(),
            fees,
            "[test_KappaReward_swapExactOut] unclaimedProtocolFeesNumeraire should have decreased because of KAPPA"
        );
        fees = IFXPool(fxPool).unclaimedProtocolFeesNumeraire();
        // fees > 0 so we can cast to uint256 later on
        assertGt(
            fees,
            0,
            "[test_KappaReward_swapExactOut] unclaimedProtocolFeesNumeraire should be positive"
        );
        assertApproxEqAbs(
            uint256(fees),
            0,
            // this rounding error is less than 0.1% (actually 0.026%) vs
            // unclaimedProtocolFeesNumeraire made from previous swap
            1.9e16,
            "[test_KappaReward_swapExactOut] unclaimedProtocolFeesNumeraire should be approx 0 (but not negative)"
        );

        // swap outside beta
        _swapToMaxHalt(fxPool, eve);
        assertGt(
            IFXPool(fxPool).unclaimedProtocolFeesNumeraire(),
            fees,
            "[test_KappaReward_swapExactOut] fees should increased"
        );

        // swap back to balance
        _swapToBalance(fxPool, eve, SwapKind.EXACT_OUT);

        assertGt(
            IFXPool(fxPool).unclaimedProtocolFeesNumeraire(),
            fees,
            "[test_KappaReward_swapExactOut] unclaimedProtocolFeesNumeraire should increased because of dynamic fee and KAPPA"
        );
    }
}
