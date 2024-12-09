// SPDX-License-Identifier: MIT

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ABDKMath64x64} from "./lib/ABDKMath64x64.sol";
import {_require, _revert, Errs} from "./lib/FXPoolErrors.sol";



struct CurveMathTradeParams {
    int128 alpha; // Maximum weight deviation allowed
    int128 beta; // No-fee zone width
    int128 delta; // Fee growth rate
    int128 lambda; // Dynamic fee proportion
    int128 oGLiq; // Original gross liquidity
    int128 nGLiq; // New gross liquidity
    int128[] oBals; // Original balances
    int128[] nBals; // New balances
    int128[] weights; // Target weights
    int128 inputAmt; // Trade input amount
    uint256 outputIndex; // Index of output token
}

library CurveMath {
    // 1.0 in 64.64 fixed point
    int128 private constant ONE = 0x10000000000000000;

    // Maximum fee of 0.25 (25%) in 64.64
    int128 private constant MAX = 0x4000000000000000;

    // Acceptable numerical deviation for utility changes
    int128 private constant MAX_DIFF = -0x10C6F7A0B5EE; // Approximately -1e-5

    // Minimal amount for numerical stability
    int128 private constant ONE_WEI = 0x12;

    using ABDKMath64x64 for int128;
    using ABDKMath64x64 for uint256;

    function calculateFee(
        int128 _gLiq,
        int128[] memory _bals,
        int128 _beta,
        int128 _delta,
        int128[] memory _weights
    ) internal pure returns (int128 psi_) {
        uint256 _length = _bals.length;
        // Sum micro fees (fᵢ) for each token in the pool
        for (uint256 i = 0; i < _length; i++) {
            // Calculate ideal balance for token i: Iᵢ = G · wᵢ
            int128 _ideal = _gLiq.mul(_weights[i]);
            // Add micro fee for this token to total fee
            psi_ += calculateDynamicFee(_bals[i], _ideal, _beta, _delta);
        }
    }

    function calculateDynamicFee(
        int128 _bal,
        int128 _ideal,
        int128 _beta,
        int128 _delta
    ) internal pure returns (int128 fee_) {
        // Case 1: Balance below ideal
        if (_bal < _ideal) {
            // Calculate lower bound of no-fee zone
            int128 _lowerBeta = _ideal.mul(ONE - _beta);
            // If balance below no-fee zone, calculate quadratic fee
            if (_bal < _lowerBeta) {
                // Distance from lower bound of no-fee zone
                int128 _feeMargin = _lowerBeta - _bal;
                // Initial fee proportional to deviation
                fee_ = _feeMargin.mul(_delta).div(_ideal);
                // Cap fee at 25% (0x4000000000000000 in 64.64)
                if (fee_ > MAX) fee_ = MAX;
                // Final fee grows quadratically with deviation
                fee_ = fee_.mul(_feeMargin);
            } else {
                fee_ = 0; // Within no-fee zone
            }
        } else {
            // Case 2: Balance above ideal
            // Calculate upper bound of no-fee zone
            int128 _upperBeta = _ideal.mul(ONE + _beta);
            // If balance above no-fee zone, calculate quadratic fee
            if (_bal > _upperBeta) {
                int128 _feeMargin = _bal - _upperBeta;
                fee_ = _feeMargin.mul(_delta).div(_ideal);
                if (fee_ > MAX) fee_ = MAX;
                fee_ = fee_.mul(_feeMargin);
            } else {
                fee_ = 0; // Within no-fee zone
            }
        }
    }

    function calculateTrade(
        CurveMathTradeParams memory p
    ) internal pure returns (int128 outputAmt_) {
        // Initialize output amount as negative of input amount
        outputAmt_ = -p.inputAmt;
        // Calculate original state fee (ω in whitepaper)
        int128 _omega = calculateFee(
            p.oGLiq,
            p.oBals,
            p.beta,
            p.delta,
            p.weights
        );

        // Iterate to find output amount that preserves invariants
        for (uint256 i = 0; i < 32; i++) {
            // Calculate new state fee (ψ in whitepaper)
            int128 _psi = calculateFee(
                p.nGLiq,
                p.nBals,
                p.beta,
                p.delta,
                p.weights
            );

            int128 prevAmount = outputAmt_;
            // Adjust output amount based on fee differential
            // if omega < psi, we are moving towards a less balanced state
            outputAmt_ = _omega < _psi
                ? -(p.inputAmt + (_omega - _psi))
                : -(p.inputAmt + (p.lambda).mul(_omega - _psi));

            // Check for convergence (within 1e-13 precision)
            if (outputAmt_ / 1e13 == prevAmount / 1e13) {
                // Update final state
                p.nGLiq = p.oGLiq + p.inputAmt + outputAmt_;
                p.nBals[p.outputIndex] = p.oBals[p.outputIndex] + outputAmt_;
                // Verify trade satisfies invariants
                enforceHalts(
                    p.alpha,
                    p.oGLiq,
                    p.nGLiq,
                    p.oBals,
                    p.nBals,
                    p.weights
                );
                enforceSwapInvariant(p.oGLiq, _omega, p.nGLiq, _psi);

                return outputAmt_;
            } else {
                // Update state for next iteration
                p.nGLiq = p.oGLiq + p.inputAmt + outputAmt_;
                p.nBals[p.outputIndex] = p.oBals[p.outputIndex].add(outputAmt_);
            }
        }
        // If convergence not reached, revert
        _revert(Errs.FP_SWAP_CONVERGENCE_VIOLATION);
    }

    function enforceSwapInvariant(
        int128 _oGLiq,
        int128 _omega,
        int128 _nGLiq,
        int128 _psi
    ) private pure {
        // Calculate utility change: (new utility - old utility)
        // Where utility U(x) = G(x) - F(x) = gross liquidity - fees
        int128 _nextUtil = _nGLiq - _psi;
        int128 _prevUtil = _oGLiq - _omega;
        int128 _diff = _nextUtil - _prevUtil;

        // Ensure utility either increases or doesn't decrease beyond acceptable threshold
        // MAX_DIFF (approximately -1e-5) provides numerical tolerance for floating point operations
        _require(
            0 < _diff || _diff >= MAX_DIFF,
            Errs.FP_SWAP_INVARIANT_VIOLATION
        );
    }

    function enforceLiquidityInvariant(
        int128 _totalShells,
        int128 _newShells,
        int128 _oGLiq,
        int128 _nGLiq,
        int128 _omega,
        int128 _psi
    ) internal pure {
        // Skip check if no shells exist or will exist after operation
        if (_totalShells == 0 || 0 == _totalShells + _newShells) return;

        // Calculate utility per shell before and after operation
        int128 _prevUtilPerShell = _oGLiq.sub(_omega).div(_totalShells);
        int128 _nextUtilPerShell = _nGLiq.sub(_psi).div(
            _totalShells.add(_newShells)
        );

        // Verify utility per shell doesn't decrease beyond acceptable threshold
        int128 _diff = _nextUtilPerShell - _prevUtilPerShell;
        _require(
            0 < _diff || _diff >= MAX_DIFF,
            Errs.FP_CURVE_LIQUIDITY_VIOLATION
        );
    }

    function enforceHalts(
        int128 _alpha,
        int128 _oGLiq,
        int128 _nGLiq,
        int128[] memory _oBals,
        int128[] memory _nBals,
        int128[] memory _weights
    ) private pure {
        uint256 _length = _nBals.length;
        for (uint256 i = 0; i < _length; i++) {
            // Calculate new ideal balance for token i: Iᵢ = G * wᵢ
            int128 _nIdeal = _nGLiq.mul(_weights[i]);

            if (_nBals[i] > _nIdeal) {
                // Check upper halt threshold
                int128 _upperAlpha = ONE + _alpha;
                int128 _nHalt = _nIdeal.mul(_upperAlpha);

                if (_nBals[i] > _nHalt) {
                    // Calculate original halt threshold
                    int128 _oHalt = _oGLiq.mul(_weights[i]).mul(_upperAlpha);

                    // Ensure we don't cross halt threshold
                    if (_oBals[i] < _oHalt) {
                        _revert(Errs.FP_UPPER_HALT);
                    }
                    if (_nBals[i] - _nHalt > _oBals[i] - _oHalt) {
                        _revert(Errs.FP_UPPER_HALT);
                    }
                }
            } else {
                // Check lower halt threshold
                int128 _lowerAlpha = ONE - _alpha;
                int128 _nHalt = _nIdeal.mul(_lowerAlpha);

                if (_nBals[i] < _nHalt) {
                    int128 _oHalt = _oGLiq.mul(_weights[i]);
                    _oHalt = _oHalt.mul(_lowerAlpha);

                    // Ensure we don't cross halt threshold
                    if (_oBals[i] > _oHalt) {
                        _revert(Errs.FP_LOWER_HALT);
                    }
                    if (_nHalt - _nBals[i] > _oHalt - _oBals[i]) {
                        _revert(Errs.FP_LOWER_HALT);
                    }
                }
            }
        }
    }
}
