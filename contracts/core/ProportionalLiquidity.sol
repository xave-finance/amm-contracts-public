// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {Assimilators} from "./Assimilators.sol";
import {Storage} from "./Storage.sol";
import {ABDKMath64x64} from "./lib/ABDKMath64x64.sol";
import {CurveMath} from "./CurveMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";


library ProportionalLiquidity {
    using ABDKMath64x64 for uint256;
    using ABDKMath64x64 for int128;

    // Constants for fixed-point arithmetic
    int128 public constant ONE = 0x10000000000000000; // 1.0 in 64.64
    int128 public constant ONE_WEI = 0x12; // Minimum unit

    struct DepositParams {
        int128 deposit64Fp; // Deposit amount in 64.64 fixed point
        int128 oGLiq; // Original gross liquidity
        int128[] oBals; // Original balances
        int128 oGLiqProp; // Original gross liquidity (proportional)
        int128[] oBalsProp; // Original balances (proportional)
        uint256[] weights; // Token weights
    }
    function proportionalDeposit(
        Storage.Curve storage curve,
        uint256 _deposit
    )
        external
        view
        returns (uint256 lpTokens_, uint256[] memory depositUintAmts)
    {
        // Delegate to internal implementation
        return _calculateProportionalDeposit(curve, _deposit, false);
    }

    function viewProportionalDeposit(
        Storage.Curve storage curve,
        uint256 _deposit
    )
        external
        view
        returns (uint256 lpTokens_, uint256[] memory depositUintAmts)
    {
        return _calculateProportionalDeposit(curve, _deposit, true);
    }

    function _calculateProportionalDeposit(
        Storage.Curve storage curve,
        uint256 _deposit,
        bool isView
    )
        private
        view
        returns (uint256 lpTokens_, uint256[] memory depositUintAmts)
    {
        uint256 _length = curve.assimilators.length;
        depositUintAmts = new uint256[](_length);

        DepositParams memory params = _buildDepositParams(curve, _deposit);

        // Handle first deposit
        if (params.oGLiq == 0) {
            // Deposit proportional to weights, mint LP tokens 1:1
            for (uint256 i = 0; i < 2; i++) {
                int128 _d = params.deposit64Fp.mul(curve.weights[i]).add(
                    ONE_WEI
                );
                depositUintAmts[i] = Assimilators.viewRawAmount(
                    curve.assimilators[i],
                    _d
                );
            }
        } else {
            // Calculate proportional amounts to maintain weights
            int128 _multiplier = params.deposit64Fp.div(params.oGLiq).add(
                ONE_WEI
            );
            for (uint256 i = 0; i < 2; i++) {
                depositUintAmts[i] =
                    1 +
                    Assimilators.viewRawAmountLPRatio(
                        curve.assimilators[i],
                        params.weights[0],
                        params.weights[1],
                        params.oBals[i].add(ONE_WEI).mul(_multiplier),
                        address(curve.vault),
                        curve.fxPoolAddress
                    );
            }
        }

        // Calculate LP tokens to mint
        int128 _totalSupplyFp = IERC20(curve.fxPoolAddress).totalSupply().divu(
            1e18
        );
        int128 _lpTokensFp = params.deposit64Fp;
        if (_totalSupplyFp > 0) {
            _lpTokensFp = params.oGLiq.inv().mul(params.deposit64Fp);
            _lpTokensFp = _lpTokensFp.mul(_totalSupplyFp);
        }

        // Validate invariant unless view function
        if (!isView) {
            requireLiquidityInvariant(
                curve,
                _totalSupplyFp,
                _lpTokensFp,
                params.oGLiqProp,
                params.oBalsProp,
                depositUintAmts,
                true
            );
        }

        lpTokens_ = _lpTokensFp.mulu(1e18) - 1;
        return (lpTokens_, depositUintAmts);
    }
    function viewInitialProportionalDeposit(
        Storage.Curve storage curve,
        uint256 _deposit
    )
        external
        view
        returns (uint256 deposit_, uint256[] memory depositUintAmts)
    {
        // Initialize array for two tokens
        depositUintAmts = new uint256[](2);

        // Convert deposit amount to 64.64 fixed point
        int128 deposit64Fp = _deposit.divu(1e18);

        // Get weights in 18 decimal fixed point
        uint256[] memory weights = new uint256[](2);
        weights[0] = curve.weights[0].mulu(1e18);
        weights[1] = curve.weights[1].mulu(1e18);

        // Calculate deposit amounts proportional to weights
        for (uint256 i = 0; i < curve.assimilators.length; i++) {
            depositUintAmts[i] = Assimilators.viewRawAmount(
                curve.assimilators[i],
                deposit64Fp.mul(curve.weights[i])
            );
        }

        // Return deposit value as LP tokens to mint
        return (_deposit, depositUintAmts);
    }

    function _buildDepositParams(
        Storage.Curve storage curve,
        uint256 _deposit
    ) private view returns (DepositParams memory params) {
        // Get regular balances
        (
            int128 _oGLiq,
            int128[] memory _oBals
        ) = getGrossLiquidityAndBalancesForDeposit(curve);

        // Get proportional balances
        (
            int128 _oGLiqProp,
            int128[] memory _oBalsProp
        ) = getGrossLiquidityAndBalances(curve);

        // Convert deposit to 64.64 fixed point
        params.deposit64Fp = _deposit.divu(1e18);
        params.oGLiq = _oGLiq;
        params.oBals = _oBals;
        params.oGLiqProp = _oGLiqProp;
        params.oBalsProp = _oBalsProp;

        // Convert weights to 18 decimal fixed point
        params.weights = new uint256[](2);
        params.weights[0] = curve.weights[0].mulu(1e18);
        params.weights[1] = curve.weights[1].mulu(1e18);

        return params;
    }
    function emergencyProportionalWithdraw(
        Storage.Curve storage curve,
        uint256 _withdrawal
    ) external view returns (uint256[] memory) {
        uint256 _length = curve.assimilators.length;

        // Get current balances
        (, int128[] memory _oBals) = getGrossLiquidityAndBalances(curve);
        uint256[] memory withdrawals_ = new uint256[](_length);

        // Convert withdrawal amount and total supply to 64.64
        int128 _totalSupplyFp = IERC20(curve.fxPoolAddress).totalSupply().divu(
            1e18
        );
        int128 __withdrawal = _withdrawal.divu(1e18);

        // Calculate withdrawal fraction
        int128 _multiplier = __withdrawal.div(_totalSupplyFp);

        // Calculate proportional withdrawals
        for (uint256 i = 0; i < _length; i++) {
            withdrawals_[i] = Assimilators.viewRawAmount(
                curve.assimilators[i],
                _oBals[i].mul(_multiplier)
            );
        }

        return withdrawals_;
    }
    function proportionalWithdraw(
        Storage.Curve storage curve,
        uint256 _withdrawal
    ) external view returns (uint256[] memory) {
        return _calculateProportionalWithdraw(curve, _withdrawal, false);
    }

    function viewProportionalWithdraw(
        Storage.Curve storage curve,
        uint256 _withdrawal
    ) external view returns (uint256[] memory) {
        return _calculateProportionalWithdraw(curve, _withdrawal, true);
    }

    function _calculateProportionalWithdraw(
        Storage.Curve storage curve,
        uint256 _withdrawal,
        bool isView
    ) private view returns (uint256[] memory withdrawUintAmts) {
        uint256 _length = curve.assimilators.length;
        withdrawUintAmts = new uint256[](_length);

        // Convert to fixed point
        int128 _totalSupplyFp = IERC20(curve.fxPoolAddress).totalSupply().divu(
            1e18
        );
        int128 __withdrawal = _withdrawal.divu(1e18);
        int128 _multiplier = __withdrawal.div(_totalSupplyFp);

        // Get current state
        (int128 _oGLiq, int128[] memory _oBals) = getGrossLiquidityAndBalances(
            curve
        );

        // Calculate proportional withdrawals
        for (uint256 i = 0; i < _length; i++) {
            withdrawUintAmts[i] =
                Assimilators.viewRawAmount(
                    curve.assimilators[i],
                    _oBals[i].mul(_multiplier)
                ) -
                1;
        }

        // Validate invariant unless view function
        if (!isView) {
            requireLiquidityInvariant(
                curve,
                _totalSupplyFp,
                __withdrawal.neg(),
                _oGLiq,
                _oBals,
                withdrawUintAmts,
                false
            );
        }

        return withdrawUintAmts;
    }

    function viewLiquidity(
        Storage.Curve storage curve
    ) external view returns (uint256 total_, uint256[] memory individual_) {
        uint256 _length = curve.assimilators.length;
        individual_ = new uint256[](_length);

        // Get each token's balance and convert to numeraire
        for (uint256 i = 0; i < _length; i++) {
            uint256 _liquidity = Assimilators
                .viewNumeraireBalance(
                    curve.assimilators[i],
                    address(curve.vault),
                    curve.fxPoolAddress
                )
                .mulu(1e18);
            total_ += _liquidity;
            individual_[i] = _liquidity;
        }

        return (total_, individual_);
    }
    /// @notice Calculates gross liquidity and balances for deposit
    /// @param curve The curve parameters
    /// @return grossLiquidity_ Total gross liquidity
    /// @return Array of individual token balances
    function getGrossLiquidityAndBalancesForDeposit(
        Storage.Curve storage curve
    ) internal view returns (int128 grossLiquidity_, int128[] memory) {
        uint256 _length = curve.assimilators.length;

        int128[] memory balances_ = new int128[](_length);
        uint256 _baseWeight = curve.weights[0].mulu(1e18);
        uint256 _quoteWeight = curve.weights[1].mulu(1e18);

        for (uint256 i = 0; i < _length; i++) {
            int128 _bal = Assimilators.viewNumeraireBalanceLPRatio(
                _baseWeight,
                _quoteWeight,
                curve.assimilators[i],
                address(curve.vault),
                curve.fxPoolAddress
            );

            balances_[i] = _bal;
            grossLiquidity_ += _bal;
        }

        return (grossLiquidity_, balances_);
    }

    /// @notice Calculates gross liquidity and balances
    /// @param curve The curve parameters
    /// @return grossLiquidity_ Total gross liquidity
    /// @return Array of individual token balances
    function getGrossLiquidityAndBalances(
        Storage.Curve storage curve
    ) internal view returns (int128 grossLiquidity_, int128[] memory) {
        uint256 _length = curve.assimilators.length;

        int128[] memory balances_ = new int128[](_length);

        for (uint256 i = 0; i < _length; i++) {
            int128 _bal = Assimilators.viewNumeraireBalance(
                curve.assimilators[i],
                address(curve.vault),
                curve.fxPoolAddress
            );
            balances_[i] = _bal;
            grossLiquidity_ += _bal;
        }

        return (grossLiquidity_, balances_);
    }

    /// @notice Calculates virtual gross liquidity and balances after deposit
    /// @param curve The curve parameters
    /// @param intakeAmounts Array of deposit amounts
    /// @return grossLiquidity_ Total gross liquidity after deposit
    /// @return Array of individual token balances after deposit
    function getVirtualGrossLiquidityAndBalancesAfterIntake(
        Storage.Curve storage curve,
        uint256[] memory intakeAmounts
    ) internal view returns (int128 grossLiquidity_, int128[] memory) {
        uint256 _length = curve.assimilators.length;

        int128[] memory balances_ = new int128[](_length);

        for (uint256 i = 0; i < _length; i++) {
            int128 _bal = Assimilators.virtualViewNumeraireBalanceIntake(
                curve.assimilators[i],
                address(curve.vault),
                curve.fxPoolAddress,
                intakeAmounts[i]
            );
            balances_[i] = _bal;
            grossLiquidity_ += _bal;
        }

        return (grossLiquidity_, balances_);
    }

    /// @notice Calculates virtual gross liquidity and balances after withdrawal
    /// @param curve The curve parameters
    /// @param outputAmounts Array of withdrawal amounts
    /// @return grossLiquidity_ Total gross liquidity after withdrawal
    /// @return Array of individual token balances after withdrawal
    function getVirtualGrossLiquidityAndBalancesAfterOuttake(
        Storage.Curve storage curve,
        uint256[] memory outputAmounts
    ) internal view returns (int128 grossLiquidity_, int128[] memory) {
        uint256 _length = curve.assimilators.length;

        int128[] memory balances_ = new int128[](_length);

        for (uint256 i = 0; i < _length; i++) {
            int128 _bal = Assimilators.virtualViewNumeraireBalanceOutput(
                curve.assimilators[i],
                address(curve.vault),
                curve.fxPoolAddress,
                outputAmounts[i]
            );
            balances_[i] = _bal;
            grossLiquidity_ += _bal;
        }

        return (grossLiquidity_, balances_);
    }

    /// @notice Enforces the liquidity invariant for deposits and withdrawals
    /// @dev This function ensures that the liquidity change maintains the pool's properties
    /// @param curve The curve parameters
    /// @param _totalSupplyFp Total LP tokens before operation
    /// @param _lpTokensFp Amount of LP tokens being minted or burned
    /// @param _oGLiq Old gross liquidity
    /// @param _oBals Old token balances
    /// @param depositAmounts Amounts being deposited or withdrawn
    /// @param isDeposit True if deposit, false if withdrawal
    function requireLiquidityInvariant(
        Storage.Curve storage curve,
        int128 _totalSupplyFp,
        int128 _lpTokensFp,
        int128 _oGLiq,
        int128[] memory _oBals,
        uint256[] memory depositAmounts,
        bool isDeposit
    ) private view {
        int128 _nGLiq;
        int128[] memory _nBals;

        // Simulate the new state after deposit/withdrawal
        if (isDeposit) {
            (_nGLiq, _nBals) = getVirtualGrossLiquidityAndBalancesAfterIntake(
                curve,
                depositAmounts
            );
        } else {
            (_nGLiq, _nBals) = getVirtualGrossLiquidityAndBalancesAfterOuttake(
                curve,
                depositAmounts
            );
        }

        int128 _beta = curve.beta;
        int128 _delta = curve.delta;
        int128[] memory _weights = curve.weights;

        // Calculate fees for old and new states
        int128 _omega = CurveMath.calculateFee(
            _oGLiq,
            _oBals,
            _beta,
            _delta,
            _weights
        );
        int128 _psi = CurveMath.calculateFee(
            _nGLiq,
            _nBals,
            _beta,
            _delta,
            _weights
        );

        CurveMath.enforceLiquidityInvariant(
            _totalSupplyFp,
            _lpTokensFp,
            _oGLiq,
            _nGLiq,
            _omega,
            _psi
        );
    }
}
