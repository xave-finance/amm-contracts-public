// SPDX-License-Identifier: MIT
pragma solidity ^0.7.3;

import '../core/lib/ABDKMath64x64.sol';
import '../core/lib/UnsafeMath64x64.sol';
import '@openzeppelin/contracts/math/SafeMath.sol';

contract FxPoolSimulationTest {
    using ABDKMath64x64 for int128;
    using ABDKMath64x64 for uint256;
    using UnsafeMath64x64 for int128;
    using SafeMath for uint256;

    int128 public constant ONE = 0x10000000000000000;

    function viewNumeraireAmountInt(
        uint256 _amount,
        uint256 _rate,
        uint256 _baseDecimals
    ) public pure returns (int128) {
        return ((_amount * _rate) / 1e8).divu(_baseDecimals);
    }

    function viewNumeraireAmount(
        uint256 _amount,
        uint256 _rate,
        uint256 baseDecimals
    ) external pure returns (uint256 amount_) {
        // working as is comparing with ABDK divu from Assimilator conversion
        amount_ = ((_amount * _rate) / 1e8).div(baseDecimals);
    }

    // returns ether value like in int128
    function viewRawAmount(
        uint256 _amount,
        uint256 _rate,
        uint256 baseDecimals
    ) external pure returns (uint256 amount_) {
        amount_ = (_amount.mul(baseDecimals) * 1e8) / _rate;
        amount_ = amount_.mul(1e18);
    }

    function viewExpectedLiquidity(
        uint256 _amount,
        uint256 _rate,
        uint256 baseDecimals
    ) external pure returns (uint256 amount_) {
        // working as is comparing with ABDK divu from Assimilator conversion
        int128 liq = ((_amount * _rate) / 1e8).divu(baseDecimals);
        amount_ = liq.mulu(1e18);
    }

    function viewExpectedLPFeeBetaRegion(
        uint256 _swapAmount,
        uint256 _epsilon,
        uint256 _rate,
        uint256 _baseDecimals,
        uint256 _protocolPercentFee
    ) public pure returns (uint256) {
        // input asset then convert in int128 numeraire, call viewNumeraireAmountInt()
        int128 inputNumeraireAmount = viewNumeraireAmountInt(_swapAmount, _rate, _baseDecimals);
        int128 fees;

        // calculate accruedFees
        // origin: fees = inputNumeraireAmount.sub(_amt.abs());
        // target: fees = _amt.abs().sub(inputNumeraireAmount.abs());
        fees = inputNumeraireAmount.us_mul(_epsilonConvert(_epsilon));

        // calculate expectedFeeToAdd_
        return fees.mulu(1e18).mul(_protocolPercentFee).div(1e2);
    }

    function viewLpFeeToBeMinted(
        uint256 _baseWeight,
        uint256 _quoteWeight,
        uint256 _baseTokenBal,
        uint256 _usdcBal,
        uint256 _curveSupply,
        uint256 _amount
    ) external pure returns (uint256) {
        int128 usdcBalance = _usdcBal.divu(1e6);

        _usdcBal = _usdcBal.mul(1e18).div(_quoteWeight);

        uint256 _rate = _usdcBal.mul(1e18).div(_baseTokenBal.mul(1e18).div(_baseWeight));

        int128 baseBalance = ((_baseTokenBal * _rate) / 1e6).divu(1e18);

        int128 intLiq = usdcBalance.add(baseBalance);

        return (intLiq.inv()).mulu(_amount).mul(_curveSupply).div(1e18);
    }

    function viewLpToBeMinted(
        uint256 _baseWeight,
        uint256 _quoteWeight,
        uint256 _baseTokenBal,
        uint256 _usdcBal,
        uint256 _curveSupply,
        uint256 _deposit
    ) external pure returns (uint256) {
        int128 __deposit = _deposit.divu(1e18);

        int128 usdcBalance = _usdcBal.divu(1e6);

        _usdcBal = _usdcBal.mul(1e18).div(_quoteWeight);

        uint256 _rate = _usdcBal.mul(1e18).div(_baseTokenBal.mul(1e18).div(_baseWeight));

        int128 baseBalance = ((_baseTokenBal * _rate) / 1e6).divu(1e18);

        int128 oGLiq = usdcBalance.add(baseBalance);

        // caclulate ogLiq
        // int128 _multiplier = __deposit.div(intLiq);
        int128 _totalShells = _curveSupply.divu(1e18);

        int128 _newShells = __deposit.div(oGLiq);
        _newShells = _newShells.mul(_totalShells);

        return _newShells.mulu(1e18);
    }

    function _epsilonConvert(uint256 _epsilon) private pure returns (int128) {
        return (_epsilon + 1).divu(1e18);
    }
}
