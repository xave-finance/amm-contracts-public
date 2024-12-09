// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {IVault} from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import {
    BalancerPoolToken
} from "@balancer-labs/v3-vault/contracts/BalancerPoolToken.sol";
import {PoolInfo} from "@balancer-labs/v3-pool-utils/contracts/PoolInfo.sol";
import {
    SwapKind,
    AddLiquidityKind,
    PoolData,
    AddLiquidityParams,
    RemoveLiquidityKind,
    PoolSwapParams,
    LiquidityManagement,
    TokenConfig,
    HookFlags,
    Rounding
} from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";
import {FXScalingHelpers} from "./core/lib/FXScalingHelpers.sol";
import {
    FixedPoint
} from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import {
    ArrayHelpers
} from "@balancer-labs/v3-solidity-utils/contracts/test/ArrayHelpers.sol";
import {
    Version
} from "@balancer-labs/v3-solidity-utils/contracts/helpers/Version.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Storage} from "./core/Storage.sol";
import {ProportionalLiquidity} from "./core/ProportionalLiquidity.sol";
import {FXSwaps, FXSwapsSwapParams} from "./core/FXSwaps.sol";
import {
    FXAssets,
    FXGreeks,
    NewPoolParams,
    PoolBoundaries
} from "./core/FXPoolTypes.sol";
import {CurveMath} from "./core/CurveMath.sol";
import {Assimilators} from "./core/Assimilators.sol";
import {ABDKMath64x64} from "./core/lib/ABDKMath64x64.sol";
import {Errs, _require, _revert} from "./core/lib/FXPoolErrors.sol";

contract FXPool is
    BalancerPoolToken,
    PoolInfo,
    Storage,
    ReentrancyGuard,
    Ownable,
    Version
{
    using ABDKMath64x64 for int128;
    using ABDKMath64x64 for uint256;
    using FXScalingHelpers for uint256;
    using ArrayHelpers for *;

    uint256 public protocolPercentFee;
    address public collectorAddress;
    int256 public unclaimedProtocolFeesNumeraire;
    int128 private constant ONE_WEI = 0x12;

    event ParametersSet(
        uint256 alpha,
        uint256 beta,
        uint256 delta,
        uint256 epsilon,
        uint256 lambda
    );
    event AssetIncluded(
        address indexed token,
        address indexed assimilator,
        uint256 weight
    );
    event ChangeCollectorAddress(address newCollector);
    event Deposit(
        address poolAddress,
        uint256 lptAmountMinted,
        uint256[] amountsDeposited
    );
    event Withdraw(
        address poolAddress,
        uint256 lptAmountBurned,
        uint256[] amountsWithdrawn
    );
    event EmergencyAlarm(bool isEmergency);
    event EmergencyWithdraw(
        address poolAddress,
        uint256 lptAmountBurned,
        uint256[] amountsWithdrawn
    );
    event Trade(
        address indexed origin,
        address indexed target,
        uint256 originAmount,
        uint256 targetAmount
    );
    event FeesCollected(address recipient, uint256 feesCollected);
    event FeesAccrued(uint256 feesCollected);
    event RewardPaid(uint256 reward);
    event ProtocolFeeShareUpdated(
        address updater,
        uint256 newProtocolPercentage
    );

    constructor(
        IVault vault,
        NewPoolParams memory params,
        address baseAssimilator,
        address quoteAssimilator
    )
        BalancerPoolToken(vault, params.name, params.symbol)
        PoolInfo(vault)
        Ownable(params.owner)
        Version("3")
    {
        // ensure that baseAssimilator is not mistakenly passed as quoteAssimilator and vice versa
        // only BaseAssimilator has a baseToken() function
        _require(
            address(IHasBaseAssimilator(baseAssimilator).baseToken()) ==
                params.assets.baseToken,
            Errs.BASE_ASSIM_MISMATCH
        );

        protocolPercentFee = params.protocolPercentFee;
        curve.vault = vault;
        curve.fxPoolAddress = address(this);

        quoteToken = params.assets.quoteToken;
        baseToken = params.assets.baseToken;

        bool _isQuoteIndexZero = quoteToken < baseToken;
        _initializeAsset(
            _isQuoteIndexZero
                ? params.assets.quoteToken
                : params.assets.baseToken,
            _isQuoteIndexZero ? quoteAssimilator : baseAssimilator,
            _isQuoteIndexZero
                ? params.assets.quoteWeight
                : params.assets.baseWeight
        );
        _initializeAsset(
            _isQuoteIndexZero
                ? params.assets.baseToken
                : params.assets.quoteToken,
            _isQuoteIndexZero ? baseAssimilator : quoteAssimilator,
            _isQuoteIndexZero
                ? params.assets.baseWeight
                : params.assets.quoteWeight
        );

        _setParamsNoCheck(
            params.greeks.alpha,
            params.greeks.beta,
            params.greeks.max,
            params.greeks.epsilon,
            params.greeks.lambda,
            params.greeks.kappa,
            false
        );
    }

    function getHookFlags() public pure returns (HookFlags memory) {
        HookFlags memory hookFlags;
        hookFlags.shouldCallBeforeAddLiquidity = true;
        hookFlags.shouldCallBeforeRemoveLiquidity = true;
        return hookFlags;
    }

    function onRegister(
        address,
        address,
        TokenConfig[] memory,
        LiquidityManagement calldata
    ) public view onlyVault returns (bool) {
        return true;
    }

    function onBeforeAddLiquidity(
        address,
        address,
        AddLiquidityKind kind,
        uint256[] memory,
        uint256,
        uint256[] memory,
        bytes memory
    ) public onlyVault returns (bool) {
        if (kind != AddLiquidityKind.CUSTOM) {
            return false;
        }

        _mintProtocolFees();
        return true;
    }

    function onBeforeRemoveLiquidity(
        address,
        address,
        RemoveLiquidityKind kind,
        uint256,
        uint256[] memory,
        uint256[] memory,
        bytes memory
    ) public onlyVault returns (bool) {
        if (kind != RemoveLiquidityKind.CUSTOM) {
            return false;
        }

        _mintProtocolFees();
        return true;
    }

    function _initializeAsset(
        address token,
        address assim,
        uint256 weight
    ) internal {
        _require(token != address(0), Errs.FP_TOKEN_ZERO_ADDRESS);
        _require(assim != address(0), Errs.FP_ASSIMILATOR_ZERO_ADDRESS);
        _require(weight < 1e18, Errs.FP_WEIGHT_MUST_BE_LESS_THAN_ONE);

        tokens.push(token);
        curve.assimilators.push(assim);
        curve.weights.push(weight.divu(1e18).add(uint256(1).divu(1e18)));

        emit AssetIncluded(token, assim, weight);
    }

    function getFee() private view returns (int128 fee_) {
        int128 _gLiq;
        int128[] memory _bals = new int128[](2);
        for (uint256 i = 0; i < _bals.length; i++) {
            int128 _bal = Assimilators.viewNumeraireBalance(
                curve.assimilators[i],
                address(curve.vault),
                curve.fxPoolAddress
            );
            _bals[i] = _bal;
            _gLiq += _bal;
        }
        fee_ = CurveMath.calculateFee(
            _gLiq,
            _bals,
            curve.beta,
            curve.delta,
            curve.weights
        );
    }

    function _setParamsNoCheck(
        uint256 _alpha,
        uint256 _beta,
        uint256 _feeAtHalt,
        uint256 _epsilon,
        uint256 _lambda,
        uint256 _kappa,
        bool _checkOmegaPsi
    ) private {
        _require(0 < _alpha && _alpha < 1e18, Errs.FP_INVALID_ALPHA);
        _require(_beta < _alpha, Errs.FP_INVALID_BETA);
        _require(_feeAtHalt <= 5e17, Errs.FP_INVALID_MAX);
        _require(_epsilon <= 1e16, Errs.FP_INVALID_EPSILON);
        _require(_lambda <= 1e18, Errs.FP_INVALID_LAMBDA);
        // within the beta region:
        //   - from 0 to epsilon, kappa is a discount on the base fee
        //   - from epsilon to 2 * epsilon, kappa becomes a reward
        _require(_kappa <= 2 * _epsilon, Errs.FP_INVALID_KAPPA);
        int128 _omega = _checkOmegaPsi ? getFee() : int128(0);

        curve.alpha = (_alpha + 1).divu(1e18);
        curve.beta = (_beta + 1).divu(1e18);
        curve.delta =
            (_feeAtHalt).divu(1e18).div(
                uint256(2).fromUInt().mul(curve.alpha.sub(curve.beta))
            ) +
            ONE_WEI;
        curve.epsilon = (_epsilon + 1).divu(1e18);
        curve.lambda = (_lambda + 1).divu(1e18);
        curve.kappa = (_kappa + 1).divu(1e18);

        if (_checkOmegaPsi) {
            int128 _psi = getFee();
            _require(_omega >= _psi, Errs.FP_PARAMETERS_INCREASE_FEE);
        }

        emit ParametersSet(
            _alpha,
            _beta,
            curve.delta.mulu(1e18),
            _epsilon,
            _lambda
        );
    }

    function viewParameters()
        external
        view
        returns (
            uint256 alpha_,
            uint256 beta_,
            uint256 delta_,
            uint256 epsilon_,
            uint256 lambda_,
            uint256 kappa_
        )
    {
        alpha_ = curve.alpha.mulu(1e18);
        beta_ = curve.beta.mulu(1e18);
        delta_ = curve.delta.mulu(1e18);
        epsilon_ = curve.epsilon.mulu(1e18);
        lambda_ = curve.lambda.mulu(1e18);
        kappa_ = curve.kappa.mulu(1e18);
    }

    function onSwap(
        PoolSwapParams memory swapRequest
    ) external onlyVault returns (uint256) {
        PoolData memory poolData = IVault(curve.vault).getPoolData(
            address(this)
        );

        uint256 amount = swapRequest.amountGivenScaled18.toRawRoundDown(
            poolData.decimalScalingFactors[
                swapRequest.kind == SwapKind.EXACT_IN
                    ? swapRequest.indexIn
                    : swapRequest.indexOut
            ]
        );

        FXSwapsSwapParams memory fxSwapsParams = FXSwapsSwapParams({
            curve: curve,
            assimilators: curve.assimilators,
            originIx: swapRequest.indexIn,
            targetIx: swapRequest.indexOut,
            amount: amount
        });

        (uint256 outputAmount, int128 fees) = swapRequest.kind ==
            SwapKind.EXACT_IN
            ? FXSwaps.viewOriginSwap(fxSwapsParams)
            : FXSwaps.viewTargetSwap(fxSwapsParams);

        _calculateAndStoreUnclaimedProtocolFee(fees);

        outputAmount = swapRequest.kind == SwapKind.EXACT_IN
            ? outputAmount.toScaled18RoundDown(
                poolData.decimalScalingFactors[swapRequest.indexOut]
            )
            : outputAmount.toScaled18RoundUp(
                poolData.decimalScalingFactors[swapRequest.indexIn]
            );

        emit Trade(
            address(tokens[swapRequest.indexIn]),
            address(tokens[swapRequest.indexOut]),
            amount,
            outputAmount
        );
        return outputAmount;
    }

    /// @notice Adds liquidity to the pool
    /// @dev This function is called by:
    /// - the Balancer V3 Vault when adding liquidity
    /// - this contract when adding liquidity in order to pay protocol fees
    /// @param router Address initiating the liquidity addition
    /// @param userData Encoded deposit amount
    /// @return amountsInScaled18 Scaled amounts of tokens to be added
    /// @return bptAmountOut Amount of pool tokens to be minted
    /// @return swapFeeAmountsScaled18 Swap fees (always zero for this pool)
    /// @return returnData Additional return data (unused)
    function onAddLiquidityCustom(
        address router,
        uint256[] memory,
        uint256,
        uint256[] memory,
        bytes memory userData
    )
        external
        onlyVault
        nonReentrant
        returns (
            uint256[] memory amountsInScaled18,
            uint256 bptAmountOut,
            uint256[] memory swapFeeAmountsScaled18,
            bytes memory returnData
        )
    {
        swapFeeAmountsScaled18 = [uint256(0), uint256(0)].toMemoryArray();
        returnData = "0x";

        uint256 totalDepositNumeraire = abi.decode(userData, (uint256));

        PoolData memory poolData = IVault(curve.vault).getPoolData(
            address(this)
        );
        if (router != address(this)) {
            _enforceCap(totalDepositNumeraire);
        }

        (
            uint256 lpTokens,
            uint256[] memory amountToDeposit
        ) = ProportionalLiquidity.proportionalDeposit(
                curve,
                totalDepositNumeraire
            );

        bptAmountOut = lpTokens;

        if (router != address(this)) {
            amountsInScaled18 = [
                amountToDeposit[0].toScaled18RoundUp(
                    poolData.decimalScalingFactors[0]
                ),
                amountToDeposit[1].toScaled18RoundUp(
                    poolData.decimalScalingFactors[1]
                )
            ].toMemoryArray();
            emit Deposit(address(this), bptAmountOut, amountToDeposit);
        } else {
            // if router / msg.sender is this pool, we're adding liquidity in order to pay protocol fees
            // in this case no tokens are being deposited, so amountsInScaled18 is 0
            amountsInScaled18 = [uint256(0), uint256(0)].toMemoryArray();
        }
    }

    /// @notice Removes liquidity from the pool
    /// @dev This function is called by the Balancer V3 Vault when removing liquidity
    /// @param userData Encoded amount of pool tokens to be burned
    /// @return bptAmountIn Amount of pool tokens to be burned
    /// @return amountsOutScaled18 Amounts of tokens to be received, sorted in token registration order
    /// @return swapFeeAmountsScaled18 Swap fees (always zero for this pool)
    /// @return returnData Additional return data (unused)
    function onRemoveLiquidityCustom(
        address, // router is msg.sender in hte vault for custom liquidity
        uint256, // maxBptAmountIn, this is valdidated in the vault
        uint256[] memory, // minAmountsOutScaled18. this is valdidated in the vault
        uint256[] memory, //balancesScaled18
        bytes memory userData
    )
        external
        onlyVault
        returns (
            uint256 bptAmountIn,
            uint256[] memory amountsOutScaled18,
            uint256[] memory swapFeeAmountsScaled18,
            bytes memory returnData
        )
    {
        PoolData memory poolData = IVault(curve.vault).getPoolData(
            address(this)
        );
        bptAmountIn = abi.decode(userData, (uint256));

        uint256[] memory amountToWithdraw = emergency
            ? ProportionalLiquidity.emergencyProportionalWithdraw(
                curve,
                bptAmountIn
            )
            : ProportionalLiquidity.proportionalWithdraw(curve, bptAmountIn);

        amountsOutScaled18 = [
            amountToWithdraw[0].toScaled18RoundDown(
                poolData.decimalScalingFactors[0]
            ),
            amountToWithdraw[1].toScaled18RoundDown(
                poolData.decimalScalingFactors[1]
            )
        ].toMemoryArray();

        if (emergency) {
            emit EmergencyWithdraw(
                address(this),
                bptAmountIn,
                amountToWithdraw
            );
        } else {
            emit Withdraw(address(this), bptAmountIn, amountToWithdraw);
        }

        swapFeeAmountsScaled18 = [uint256(0), uint256(0)].toMemoryArray();
        returnData = "0x";
    }

    function getMinimumSwapFeePercentage() external pure returns (uint256) {
        return 0;
    }

    function getMaximumSwapFeePercentage() external pure returns (uint256) {
        return 0;
    }

    function getCurve() external view returns (Storage.Curve memory) {
        return curve;
    }

    // ADMIN AND ACCESS CONTROL FUNCTIONS

    // /// @notice Set cap for pool
    // /// @param _cap cap value
    function setCap(uint256 _cap) external onlyOwner {
        (uint256 total, ) = liquidity();
        _require(_cap > total, Errs.FP_CAP_IS_NOT_GREATER_THAN_TOTAL_LIQUIDITY);
        curve.cap = _cap;
    }

    // /// @notice Set emergency alarm
    // /// @param _emergency turn on or off
    function setEmergency(bool _emergency) external onlyOwner {
        emergency = _emergency;
        emit EmergencyAlarm(_emergency);
    }

    /// @notice Change collector address
    /// @param _collectorAddress collector's new address
    function setCollectorAddress(address _collectorAddress) external onlyOwner {
        collectorAddress = _collectorAddress;
        emit ChangeCollectorAddress(_collectorAddress);
    }

    // /// @notice Change protocol percentage in fees
    // /// @param _protocolPercentFee collector's new address
    function setProtocolPercentFee(
        uint256 _protocolPercentFee
    ) external onlyOwner {
        protocolPercentFee = _protocolPercentFee;
        emit ProtocolFeeShareUpdated(msg.sender, protocolPercentFee);
    }

    // UTILITY VIEW FUNCTIONS

    /// @notice views the total amount of liquidity in the curve in numeraire value and format - 18 decimals
    /// @return total_ the total value in the curve
    /// @return individual_ the individual values in the curve
    function liquidity()
        public
        view
        returns (uint256 total_, uint256[] memory individual_)
    {
        return ProportionalLiquidity.viewLiquidity(curve);
    }

    /// @notice view the assimilator address for a token
    /// @return assimilator_ the assimilator address
    function assimilator(
        address _token
    ) public view returns (address assimilator_) {
        // @TODO test
        return
            tokens[0] == _token ? curve.assimilators[0] : curve.assimilators[1];
    }

    /// @notice view LP tokens and token needed for deposit
    function viewDeposit(
        uint256 totalDepositNumeraire
    ) external view returns (uint256, uint256[] memory) {
        if (IVault(curve.vault).isPoolInitialized(curve.fxPoolAddress)) {
            return
                ProportionalLiquidity.viewProportionalDeposit(
                    curve,
                    totalDepositNumeraire
                );
        } else {
            return
                ProportionalLiquidity.viewInitialProportionalDeposit(
                    curve,
                    totalDepositNumeraire
                );
        }
    }

    /// @notice view tokens to be received given LP tokens to burn
    function viewWithdraw(
        uint256 _curvesToBurn
    ) external view returns (uint256[] memory) {
        return
            ProportionalLiquidity.viewProportionalWithdraw(
                curve,
                _curvesToBurn
            );
    }

    // INTERNAL LOGIC FUNCTIONS
    function _enforceCap(uint256 _amount) private view {
        if (curve.cap == 0) return;

        (uint256 total, ) = liquidity();

        _require(total + _amount < curve.cap, Errs.FP_AMOUNT_BEYOND_SET_CAP);
    }

    function computeInvariant(
        uint256[] memory,
        Rounding rounding
    ) public view returns (uint256) {
        (int128 _oGLiq, ) = ProportionalLiquidity.getGrossLiquidityAndBalances(
            curve
        );
        return _oGLiq.mulu(1e18);
    }

    function getRate() public view override returns (uint256) {
        uint256 totalSupply = totalSupply();
        if (totalSupply == 0) {
            return 1e18;
        }

        (int128 _oGLiq, ) = ProportionalLiquidity.getGrossLiquidityAndBalances(
            curve
        );

        return (_oGLiq.mulu(1e18) * 1e18) / totalSupply;
    }

    /// @dev How much of a token to swap to balance the pool
    /// @return fromToken tokenAddress as tokenIn
    /// @return toToken tokenAddress as tokenOut
    /// @return rawAmount amount of token to swap to balance the pool
    /// @return numeraireAmount numeraire amount of token to swap to balance the pool
    function viewSwapToBalancePool()
        public
        view
        returns (
            address fromToken,
            address toToken,
            uint256 rawAmount,
            uint256 numeraireAmount
        )
    {
        PoolBoundaries memory b = getPoolBoundaries();

        fromToken = b.isBalanced ? address(0) : b.balancedSwapToken;
        toToken = b.isBalanced
            ? address(0)
            : (
                fromToken == b.betaSwapAmtMinToken
                    ? b.betaSwapAmtMaxToken
                    : b.betaSwapAmtMinToken
            );
        rawAmount = b.isBalanced
            ? 0
            : convertNumeraireToRaw(fromToken, b.balancedSwapAmt);
        numeraireAmount = b.isBalanced ? 0 : b.balancedSwapAmt;
    }

    /// @dev Checks if the given swap amount will take the pool to OR keep the pool within beta
    /// @param tokenIn token address in
    /// @param amountRaw amount to swap
    /// @return if the swap will keep the pool inside the beta region
    function isSwapWithinBeta(
        address tokenIn,
        uint256 amountRaw
    ) public view returns (bool) {
        PoolBoundaries memory b = getPoolBoundaries();
        uint256 amountNumeraire = convertRawToNumeraire(tokenIn, amountRaw);
        if (!b.isWithinBeta) {
            // if pool is already outside beta then assess whether the direction will bring it back
            // _twards_ the beta region; rationale here is that whoever is using this function will want to
            // not pay outside-of-beta fees
            // in this case, bringing the pool _towards_ the beta region means a more advantageous swap
            // and therefore we return true in that case as well
            // when outside the beta region, the betaSwapAmtMinToken will reflect the tokenIn which
            // will bring the pool towards beta region. In this case we only need to check if the amount
            // is less than the betaSwapAmtMax to ensure that the swap does not push the pool outside
            // the opposite beta edge
            return
                b.betaSwapAmtMinToken == tokenIn &&
                amountNumeraire <= b.betaSwapAmtMax;
        } else {
            // if the pool is inside beta region then we need to check if the swap will take it outside
            // either of the beta region edges
            return
                (tokenIn == b.betaSwapAmtMinToken &&
                    amountNumeraire <= b.betaSwapAmtMin) ||
                (tokenIn == b.betaSwapAmtMaxToken &&
                    amountNumeraire <= b.betaSwapAmtMax);
        }
    }

    /// @dev Checks if the function is in the beta region. it will return true if it is, if not then it will return false.
    // If false, it returns the amount of token to go back to beta region and the address of the token in
    /// @return if it's in the beta region
    /// @return swap in to bring back the pool within beta
    /// @return tokenIn address
    function isInBeta() public view returns (bool, uint256, address) {
        PoolBoundaries memory boundaries = getPoolBoundaries();
        return (
            boundaries.isWithinBeta,
            boundaries.isWithinBeta ? 0 : boundaries.betaSwapAmtMin,
            boundaries.isWithinBeta
                ? address(0)
                : boundaries.betaSwapAmtMinToken
        );
    }

    function isBalanced() public view returns (bool) {
        return getPoolBoundaries().isBalanced;
    }

    function isQuoteIndexZero() public view returns (bool) {
        return quoteToken < baseToken;
    }

    /// @notice Calculates the beta and halt boundaries of the pool
    /// @return boundaries Struct containing information in numeraire values
    /// about the current boundaries
    function getPoolBoundaries()
        public
        view
        returns (PoolBoundaries memory boundaries)
    {
        // Get current pool liquidity
        (uint256 totalLiquidity, uint256[] memory individualLiquidity) = this
            .liquidity();

        // Convert to int128 for compatibility with ABDKMath64x64
        int128 totalLiq = totalLiquidity.divu(1e18);
        int128 token0Liq = individualLiquidity[0].divu(1e18);

        // Get curve parameters
        int128 alpha = curve.alpha;
        int128 beta = curve.beta;

        // Calculate ideal ratio based on weights
        int128 idealRatio = curve.weights[0];
        int128 idealToken0Liq = totalLiq.mul(idealRatio);

        int128 ONE = 0x10000000000000000;

        {
            // Calculate boundaries
            boundaries.lowerBeta = idealRatio
                .mul(ONE - beta)
                .mul(totalLiq)
                .mulu(1e18);
            boundaries.upperBeta = idealRatio
                .mul(ONE + beta)
                .mul(totalLiq)
                .mulu(1e18);
            boundaries.lowerHalt = idealRatio
                .mul(ONE - alpha)
                .mul(totalLiq)
                .mulu(1e18);
            boundaries.upperHalt = idealRatio
                .mul(ONE + alpha)
                .mul(totalLiq)
                .mulu(1e18);
            int128 balanceThreshold = idealToken0Liq.mul(
                ABDKMath64x64.divu(1, 100)
            ); // 1% of ideal liquidity

            // Determine if balanced (within 1% threshold)
            bool balanced = (token0Liq >= idealToken0Liq - balanceThreshold) &&
                (token0Liq <= idealToken0Liq + balanceThreshold);
            boundaries.isBalanced = balanced;
            if (!balanced) {
                // Calculate balancedSwapAmt and balancedSwapToken
                int128 balanceSwapAmount = idealToken0Liq - token0Liq;
                if (balanceSwapAmount > 0) {
                    // Need more token0, so swap in token0
                    boundaries.balancedSwapAmt = uint256(
                        balanceSwapAmount.mulu(1e18)
                    );
                    boundaries.balancedSwapToken = address(tokens[0]);
                } else {
                    boundaries.balancedSwapAmt = uint256(
                        balanceSwapAmount.abs().mulu(1e18)
                    );
                    boundaries.balancedSwapToken = address(tokens[1]);
                }
            }
        }

        {
            // Calculate swap amounts
            int128 toLowerBeta = token0Liq -
                idealRatio.mul(ONE - beta).mul(totalLiq);
            int128 toUpperBeta = idealRatio.mul(ONE + beta).mul(totalLiq) -
                token0Liq;
            boundaries.isWithinBeta = (toLowerBeta >= 0 && toUpperBeta >= 0);

            // Determine beta swap amounts and tokens
            if (toLowerBeta.abs() < toUpperBeta.abs()) {
                boundaries.betaSwapAmtMin = uint256(
                    toLowerBeta.abs().mulu(1e18)
                );
                boundaries.betaSwapAmtMinToken = toLowerBeta > 0
                    ? address(tokens[1])
                    : address(tokens[0]);
                boundaries.betaSwapAmtMax = uint256(
                    toUpperBeta.abs().mulu(1e18)
                );
                boundaries.betaSwapAmtMaxToken = boundaries
                    .betaSwapAmtMinToken == address(tokens[0])
                    ? address(tokens[1])
                    : address(tokens[0]);
            } else {
                boundaries.betaSwapAmtMin = uint256(
                    toUpperBeta.abs().mulu(1e18)
                );
                boundaries.betaSwapAmtMinToken = toUpperBeta > 0
                    ? address(tokens[0])
                    : address(tokens[1]);
                boundaries.betaSwapAmtMax = uint256(
                    toLowerBeta.abs().mulu(1e18)
                );
                boundaries.betaSwapAmtMaxToken = boundaries
                    .betaSwapAmtMinToken == address(tokens[0])
                    ? address(tokens[1])
                    : address(tokens[0]);
            }
        }

        int128 toLowerHalt = token0Liq -
            idealRatio.mul(ONE - alpha).mul(totalLiq);
        int128 toUpperHalt = idealRatio.mul(ONE + alpha).mul(totalLiq) -
            token0Liq;

        // Determine halt swap amounts and tokens
        if (toLowerHalt.abs() < toUpperHalt.abs()) {
            boundaries.haltSwapAmtMin = uint256(toLowerHalt.abs().mulu(1e18));
            boundaries.haltSwapAmtMinToken = toLowerHalt > 0
                ? address(tokens[1])
                : address(tokens[0]);
            boundaries.haltSwapAmtMax = uint256(toUpperHalt.abs().mulu(1e18));
            boundaries.haltSwapAmtMaxToken = boundaries.haltSwapAmtMinToken ==
                address(tokens[0])
                ? address(tokens[1])
                : address(tokens[0]);
        } else {
            boundaries.haltSwapAmtMin = uint256(toUpperHalt.abs().mulu(1e18));
            boundaries.haltSwapAmtMinToken = toUpperHalt > 0
                ? address(tokens[0])
                : address(tokens[1]);
            boundaries.haltSwapAmtMax = uint256(toLowerHalt.abs().mulu(1e18));
            boundaries.haltSwapAmtMaxToken = boundaries.haltSwapAmtMinToken ==
                address(tokens[0])
                ? address(tokens[1])
                : address(tokens[0]);
        }

        return boundaries;
    }

    // Helper function to convert numeraire amounts (1e18) to raw token amounts (token decimals)
    function convertNumeraireToRaw(
        address asset,
        uint256 numeraireAmount
    ) public view returns (uint256) {
        return
            Assimilators.viewRawAmount(
                curve.assimilators[getAssetIndex(asset)],
                numeraireAmount.divu(1e18)
            );
    }

    // Helper function to convert raw token amounts (token decimals) to numeraire amounts (1e18)
    function convertRawToNumeraire(
        address asset,
        uint256 rawAmount
    ) public view returns (uint256) {
        return
            Assimilators
                .viewNumeraireAmount(
                    curve.assimilators[getAssetIndex(asset)],
                    rawAmount
                )
                .mulu(1e18);
    }

    function getAssetIndex(
        address asset
    ) public view returns (uint8 assetIndex) {
        if (tokens[0] == asset) {
            assetIndex = 0;
        } else if (tokens[1] == asset) {
            assetIndex = 1;
        } else {
            _revert(Errs.FP_INVALID_ASSET);
        }
    }

    function _calculateAndStoreUnclaimedProtocolFee(int128 fees) private {
        // fees can be negative, which signals that a (kappa) reward has been paid for a pool balancing swap
        if (_isProtocolMintingOn()) {
            int256 feesToAdd = (fees.muli(1e18) * int256(protocolPercentFee)) /
                1e2;
            if (feesToAdd == 0) {
                // rounded to zero by division above
                return;
            }
            // in some cases the unclaimed fees value can be negative: when a subsequent swap that brings the pool towards balance
            // is made after an increase in kappa parameter; this is a valid scenario
            unclaimedProtocolFeesNumeraire += feesToAdd;

            if (feesToAdd > 0) {
                emit FeesAccrued(uint256(feesToAdd));
            } else {
                emit RewardPaid(uint256(-feesToAdd));
            }
        }
    }

    function _mintProtocolFees() private {
        // checks
        if (_isProtocolMintingOn() && unclaimedProtocolFeesNumeraire > 0) {
            int256 _unclaimedProtocolFeesNumeraire = unclaimedProtocolFeesNumeraire;
            // effects: this needs to be set to 0 before calling addLiquidity
            // otherwise we will mint fees forever
            unclaimedProtocolFeesNumeraire = 0;

            // interactions
            // pay fees in LP token by re-joining the pool
            // note the `to` parameter is set to the collector address
            // this is because we want to collect the protocol fees in
            // the collector address and not in the vault
            // LP fees are accrued in the vault
            AddLiquidityParams memory joinParams = AddLiquidityParams({
                pool: address(this),
                to: collectorAddress,
                maxAmountsIn: [uint256(1e29), uint256(1e29)].toMemoryArray(),
                // here we rely on the fact that the vault is already protecting against
                // slippage through the add / remove liquidity slippage parameter
                minBptAmountOut: 0,
                kind: AddLiquidityKind.CUSTOM,
                userData: abi.encode(_unclaimedProtocolFeesNumeraire)
            });
            (, uint256 bptAmountOut, ) = _vault.addLiquidity(joinParams);

            emit FeesCollected(collectorAddress, bptAmountOut);
        }
    }

    function _isProtocolMintingOn() private view returns (bool) {
        return collectorAddress != address(0) && totalSupply() > 0;
    }
}

interface IHasBaseAssimilator {
    function baseToken() external view returns (address);
}
