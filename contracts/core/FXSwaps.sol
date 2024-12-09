// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {Assimilators} from "./Assimilators.sol";
import {Storage} from "./Storage.sol";
import {CurveMath, CurveMathTradeParams} from "./CurveMath.sol";
import {Errs, _require} from "./lib/FXPoolErrors.sol";

import {ABDKMath64x64} from "./lib/ABDKMath64x64.sol";

import {
    SwapKind
} from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";


struct FXSwapsSwapParams {
    Storage.Curve curve; // Pool curve parameters
    address[] assimilators; // Token assimilators
    uint256 originIx; // Index of input token
    uint256 targetIx; // Index of output token
    uint256 amount; // Trade amount
}

/// @title FXSwaps
/// @notice Library implementing core swap functionality for FXPool
library FXSwaps {
    using ABDKMath64x64 for int128;
    using ABDKMath64x64 for uint256;

    int128 public constant ONE = 0x10000000000000000;
    function viewOriginSwap(
        FXSwapsSwapParams memory params
    ) external view returns (uint256 tAmt_, int128 accruedFees_) {
        // Get numeraire amounts and current pool state
        (
            int128 _amt,
            int128 _oGLiq,
            int128 _nGLiq,
            int128[] memory _nBals,
            int128[] memory _oBals
        ) = viewOriginSwapData(
                params.curve,
                params.originIx,
                params.targetIx,
                params.amount,
                address(params.assimilators[params.originIx])
            );

        int128 inputNumeraireAmount = _amt;

        // Calculate trade output using curve math
        _amt = CurveMath.calculateTrade(
            CurveMathTradeParams({
                alpha: params.curve.alpha,
                beta: params.curve.beta,
                delta: params.curve.delta,
                lambda: params.curve.lambda,
                oGLiq: _oGLiq,
                nGLiq: _nGLiq,
                oBals: _oBals,
                nBals: _nBals,
                weights: params.curve.weights,
                inputAmt: _amt,
                outputIndex: params.targetIx
            })
        );

        // Apply rebalancing reward if applicable
        int128 kappaReward = calculateKappaReward(
            params,
            _amt,
            _oGLiq,
            _oBals,
            SwapKind.EXACT_IN
        );

        // Apply fees and rewards
        _amt = _amt.mul(ONE - params.curve.epsilon).sub(kappaReward);

        // Calculate total fees charged
        accruedFees_ = inputNumeraireAmount.sub(_amt.abs());

        // Convert output amount to raw token units
        tAmt_ = Assimilators.viewRawAmount(
            address(params.assimilators[params.targetIx]),
            _amt.abs()
        );
    }
    function viewTargetSwap(
        FXSwapsSwapParams memory params
    ) external view returns (uint256 oAmt_, int128 accruedFees_) {
        // Get numeraire amounts and current pool state
        (
            int128 _amt,
            int128 _oGLiq,
            int128 _nGLiq,
            int128[] memory _nBals,
            int128[] memory _oBals
        ) = viewTargetSwapData(
                params.curve,
                params.targetIx,
                params.originIx,
                params.amount,
                address(params.assimilators[params.targetIx])
            );

        int128 inputNumeraireAmount = _amt;

        // Calculate required input using curve math
        _amt = CurveMath.calculateTrade(
            CurveMathTradeParams({
                alpha: params.curve.alpha,
                beta: params.curve.beta,
                delta: params.curve.delta,
                lambda: params.curve.lambda,
                oGLiq: _oGLiq,
                nGLiq: _nGLiq,
                oBals: _oBals,
                nBals: _nBals,
                weights: params.curve.weights,
                inputAmt: _amt,
                outputIndex: params.originIx
            })
        );

        // Apply rebalancing reward if applicable
        int128 kappaReward = calculateKappaReward(
            params,
            _amt,
            _oGLiq,
            _oBals,
            SwapKind.EXACT_OUT
        );

        // Apply fees and rewards (note: epsilon applied in reverse for exact output)
        _amt = _amt.mul(ONE + params.curve.epsilon).sub(kappaReward);

        // Calculate total fees charged
        accruedFees_ = _amt.abs().sub(inputNumeraireAmount.abs());

        // Convert required input to raw token units
        oAmt_ = Assimilators.viewRawAmount(
            address(params.assimilators[params.originIx]),
            _amt
        );
    }

    function calculateRewardRange(
        int128 _oBal,
        int128 _nBal,
        int128 _ideal,
        int128 _beta
    ) public pure returns (int128 rewardRange_) {
        // Calculate β bounds around ideal weight
        int128 _lowerBeta = _ideal.mul(ONE - _beta);
        int128 _upperBeta = _ideal.mul(ONE + _beta);

        // Case 1: Moving up towards ideal from below
        if (_oBal < _ideal && _oBal < _nBal && _nBal > _lowerBeta) {
            rewardRange_ = ABDKMath64x64
                .sub(max(_oBal, _lowerBeta), min(_nBal, _ideal))
                .abs();
        }
        // Case 2: Moving down towards ideal from above
        else if (_oBal > _ideal && _oBal > _nBal && _nBal < _upperBeta) {
            rewardRange_ = ABDKMath64x64
                .sub(min(_oBal, _upperBeta), max(_nBal, _ideal))
                .abs();
        }
        // No reward if not moving towards ideal weight
    }

    function calculateKappaReward(
        FXSwapsSwapParams memory params,
        int128 _amt,
        int128 _oGLiq,
        int128[] memory _oBals,
        SwapKind _swapKind
    ) public pure returns (int128 kappaReward_) {
        // Skip if kappa is zero (no rebalancing rewards)
        if (params.curve.kappa == 0) {
            return 0;
        }

        // Determine which token balance to check based on swap kind
        uint256 index = _swapKind == SwapKind.EXACT_IN
            ? params.targetIx
            : params.originIx;

        int128 kappa = params.curve.kappa;
        int128 weight = params.curve.weights[index];

        // Get original and new balances
        int128 oBal = _oBals[index];
        int128 nBal = oBal.add(_amt);

        // Calculate portion of trade eligible for reward
        int128 rewardRange = calculateRewardRange(
            oBal,
            nBal,
            _oGLiq.mul(weight),
            params.curve.beta
        );

        // Apply kappa multiplier to get final reward
        kappaReward_ = rewardRange.mul(kappa);
    }
    function viewTargetSwapData(
        Storage.Curve memory curve,
        uint256 _inputIx,
        uint256 _outputIx,
        uint256 _amt,
        address _assim
    )
        private
        view
        returns (
            int128 amt_,
            int128 oGLiq_,
            int128 nGLiq_,
            int128[] memory nBals_,
            int128[] memory oBals_
        )
    {
        uint256 _length = curve.assimilators.length;
        nBals_ = new int128[](_length);
        oBals_ = new int128[](_length);

        // Get current balances and convert target amount
        for (uint256 i = 0; i < _length; i++) {
            if (i != _inputIx) {
                // Store same balance for tokens not involved in swap
                nBals_[i] = oBals_[i] = _viewNumeraireBalance(curve, i);
            } else {
                // Convert target amount to numeraire for input token
                int128 _bal;
                (amt_, _bal) = _viewNumeraireAmountAndBalance(
                    curve,
                    _assim,
                    _amt
                );
                amt_ = amt_.neg(); // Negate for target-specified swap
                oBals_[i] = _bal;
                nBals_[i] = _bal.add(amt_);
            }
            oGLiq_ += oBals_[i];
            nGLiq_ += nBals_[i];
        }

        // Adjust liquidity and output token balance
        nGLiq_ = nGLiq_.sub(amt_);
        nBals_[_outputIx] = ABDKMath64x64.sub(nBals_[_outputIx], amt_);
    }
    function viewOriginSwapData(
        Storage.Curve memory curve,
        uint256 _inputIx,
        uint256 _outputIx,
        uint256 _amt,
        address _assim
    )
        private
        view
        returns (
            int128 amt_,
            int128 oGLiq_,
            int128 nGLiq_,
            int128[] memory nBals_,
            int128[] memory oBals_
        )
    {
        uint256 _length = curve.assimilators.length;
        nBals_ = new int128[](_length);
        oBals_ = new int128[](_length);

        // Get current balances and convert input amount
        for (uint256 i = 0; i < _length; i++) {
            if (i != _inputIx) {
                // Store same balance for tokens not involved in swap
                nBals_[i] = oBals_[i] = _viewNumeraireBalance(curve, i);
            } else {
                // Convert input amount to numeraire
                int128 _bal;
                (amt_, _bal) = _viewNumeraireAmountAndBalance(
                    curve,
                    _assim,
                    _amt
                );
                oBals_[i] = _bal;
                nBals_[i] = _bal.add(amt_);
            }
            oGLiq_ += oBals_[i];
            nGLiq_ += nBals_[i];
        }

        // Adjust liquidity and prepare output token balance for curve math
        nGLiq_ = nGLiq_.sub(amt_);
        nBals_[_outputIx] = ABDKMath64x64.sub(nBals_[_outputIx], amt_);
    }

    /// @notice Views the numeraire balance for a given assimilator
    /// @dev Internal function to avoid stack too deep errors
    function _viewNumeraireBalance(
        Storage.Curve memory curve,
        uint256 index
    ) internal view returns (int128) {
        return
            Assimilators.viewNumeraireBalance(
                curve.assimilators[index],
                address(curve.vault),
                curve.fxPoolAddress
            );
    }

    /// @notice Views the numeraire amount and balance for a given assimilator and amount
    /// @dev Internal function to avoid stack too deep errors
    function _viewNumeraireAmountAndBalance(
        Storage.Curve memory curve,
        address _assim,
        uint256 _amt
    ) internal view returns (int128 amt_, int128 bal_) {
        return
            Assimilators.viewNumeraireAmountAndBalance(
                _assim,
                _amt,
                address(curve.vault),
                curve.fxPoolAddress
            );
    }

    function min(int128 a, int128 b) internal pure returns (int128) {
        return a < b ? a : b;
    }

    function max(int128 a, int128 b) internal pure returns (int128) {
        return a > b ? a : b;
    }
}
