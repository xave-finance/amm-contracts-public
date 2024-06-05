/**
 * @title RebalanceAddLiq
 * @dev Given a 20_000 numeraire deposit, the `swapAddLiq` function will:
 * - calculate the amount of base or quote tokens to swap in order to rebalance the pool
 * - if the pool is imbalanced, it will perform a swap based on the above
 * - it will add the rest of the liquidity to the pool
 * - ensure that the FXPool minted at least the expected amount of shares (expectedShares)
 * - return the amount of shares to the caller (including at dust from the tokens added to the pool)
 *
 * The `viewSwapAddLiq` function should be used **OFFCHAIN** in order to get the amount of tokens to
 * approve to this contract and the minimum shares (`expectedShares`) to expect back. These 3 values
 * act as a slippage parameter that ensure that the call to `swapAddLiq` cannot be price manipulated.
 *
 * In general you will want to allow for room for the price to move slightly between the `viewSwapAddLiq`
 * and `swapAddLiq` calls. For example, if you'd like to allow for a maximum of 1.5% slippage,
 * call `viewSwapAddLiq` with a slippage parameter of `150` - slippage is denominated in 1e4 units.
 */

pragma solidity 0.7.6;
pragma experimental ABIEncoderV2;
import '@openzeppelin/contracts/math/SafeMath.sol';
import '@openzeppelin/contracts/utils/ReentrancyGuard.sol';

import {FXPool} from '../FXPool.sol';
import {IVault} from '@balancer-labs/v2-vault/contracts/interfaces/IVault.sol';
import {IERC20} from '@balancer-labs/v2-solidity-utils/contracts/openzeppelin/IERC20.sol';
import {BaseToUsdAssimilator} from '../assimilators/BaseToUsdAssimilator.sol';
import {IAssimilator} from '../core/interfaces/IAssimilator.sol';
import {IAsset} from '@balancer-labs/v2-vault/contracts/interfaces/IAsset.sol';
import {ABDKMath64x64} from '../core/lib/ABDKMath64x64.sol';

interface IERC20Detailed is IERC20 {
    function symbol() external view returns (string memory);

    function decimals() external view returns (uint8);
}

struct DepositCurvesParam {
    FXPool fxp;
    bytes32 poolId;
    // the whole amount of deposit numeraire (in 1e18)
    // Eg. a user wanting to deposit $20,000 worth of liquidity
    // would be represented as 20_000 * 1e18 here
    uint256 deposit;
    // used only in `viewSwapAddLiq` to update the pool's balances
    // after a swap - so that further calculations are based on
    // correct balances
    int256 baseBalDelta;
    // used only in `viewSwapAddLiq`
    int256 quoteBalDelta;
    // the asset to swap in order to rebalance the pool (if a rebalance is needed)
    address assetIn;
    address assetOut;
    // index of the assetIn in the FXPool
    // NB: FXPool order is always base first, quote second
    // while in the vault the tokens are sorted
    uint256 assetInIndex;
    // 10 ** baseToken.decimals
    uint256 baseDecimalsMultiplier;
}

contract RebalanceAddLiq is ReentrancyGuard {
    using SafeMath for uint256;
    using SafeMath for int128;
    using ABDKMath64x64 for int128;
    using ABDKMath64x64 for uint256;

    address private immutable vault; // balancer vault
    address public immutable QUOTE_TOKEN; // USDC
    uint256 public immutable QUOTE_DECIMALS_MULTIPLIER; // 1e6
    uint256 public constant SLIPPAGE_MULTIPLIER = 1e4;
    uint256 private constant POOL_RATIO_PERCENT = 0.5 * 10_000;
    // only try and rebalance the pool when outside of this range
    uint256 private constant RATIO_LOWER_LIMIT = 0.48 * 1e18;
    uint256 private constant RATIO_UPPER_LIMIT = 0.52 * 1e18;

    int128 public constant ONE_WEI = 0x12;

    constructor(address _vault, address _quoteToken) {
        vault = _vault;
        QUOTE_TOKEN = _quoteToken;
        QUOTE_DECIMALS_MULTIPLIER = 10 ** uint256(IERC20Detailed(_quoteToken).decimals());
    }

    /**
     * Note that this function is not 'view' (due to the call to IVault.queryBatchSwap()):
     * the client code must explicitly execute eth_call instead of eth_sendTransaction.
     */
    function viewSwapAddLiq(
        address fxPoolAddr,
        uint256 addLiqNumeraire18e,
        uint256 slippage // slippage in 1e4 units (eg. pass a value of 100 for a slippage of 1%)
    )
        external
        returns (
            uint256 expectedShares, // minimum expected shares to receive back (includes slippage calculation)
            uint256 baseTokenAmount, // amount of base token to approve to this contract
            uint256 quoteTokenAmount, // amount of quote token to approve to this contract
            address targetTokenToSwapIn, // token used to swapIn order to rebalance the pool
            uint256 swapAmountInRaw // amount of `targetTokenToSwapIn` to swap in order to rebalance the pool
        )
    {
        uint256[] memory tokenAmounts;
        {
            DepositCurvesParam memory d;
            uint256 swapAmountOutRaw;
            uint8 assetInIndex;
            (targetTokenToSwapIn, assetInIndex, swapAmountInRaw) = _calculateSwapAmount(FXPool(fxPoolAddr));

            (d, swapAmountOutRaw) = _calculateBalanceDeltas(
                FXPool(fxPoolAddr),
                addLiqNumeraire18e,
                targetTokenToSwapIn,
                swapAmountInRaw,
                assetInIndex
            );

            // tokenAmounts are already ordered in FXPool order: base first index, quote second index
            (expectedShares, tokenAmounts) = _calculateDepositsCurves(d, swapAmountInRaw, swapAmountOutRaw);
        }
        return (
            expectedShares.mul(SLIPPAGE_MULTIPLIER.sub(slippage)).div(SLIPPAGE_MULTIPLIER),
            tokenAmounts[0].mul(SLIPPAGE_MULTIPLIER.add(slippage)).div(SLIPPAGE_MULTIPLIER),
            tokenAmounts[1].mul(SLIPPAGE_MULTIPLIER.add(slippage)).div(SLIPPAGE_MULTIPLIER),
            targetTokenToSwapIn,
            swapAmountInRaw
        );
    }

    /**
     * @dev Swaps the minimum amount of tokens to rebalance the pool and adds the rest of the liquidity
     * @param fxPoolAddr address of the FXPool
     * @param addLiqNumeraire18e the whole amount of deposit numeraire (in 1e18)
     * Eg. a user wanting to deposit $20,000 worth of liquidity
     * would be represented as 20_000 * 1e18 here
     * @param expectedShares the minimum amount of shares to expect back
     */
    function swapAddLiq(
        address fxPoolAddr, // address of the FXPool
        uint256 addLiqNumeraire18e, // total amount of numeraire to add to the pool (in 1e18)
        uint256 maxBaseAmount, // maximum amount of raw base token to add to the pool (> 0)
        uint256 maxQuoteAmount, // maximum amount of raw quote token to add to the pool (> 0)
        uint256 expectedShares // minimum expected shares to receive back
    ) external nonReentrant {
        require(maxBaseAmount > 0 && maxQuoteAmount > 0, 'RebalanceAddLiq/amount-greater-than-zero');

        FXPool fxp = FXPool(fxPoolAddr);
        bytes32 poolId = fxp.getPoolId();

        (IERC20[] memory tokens /*uint256[] memory balances*/, , ) = IVault(vault).getPoolTokens(poolId);

        (uint8 assetInIndex, uint256 swapAmountInRaw) = _transferSwapAsset(fxp);

        address assetIn = fxp.derivatives(assetInIndex);
        address assetOut = fxp.derivatives(assetInIndex == 0 ? 1 : 0);

        IERC20(assetIn).approve(vault, assetIn == QUOTE_TOKEN ? maxQuoteAmount : maxBaseAmount);
        uint256 swapAmountOutRaw;

        if (swapAmountInRaw > 0) {
            swapAmountOutRaw = _swap(poolId, assetIn, assetOut, swapAmountInRaw, 0);
        }
        IERC20(assetOut).approve(
            vault,
            assetOut == QUOTE_TOKEN ? maxQuoteAmount.add(swapAmountOutRaw) : maxBaseAmount.add(swapAmountOutRaw)
        );

        _addLiquidity(
            poolId,
            _transferLiqAssets(
                fxp,
                addLiqNumeraire18e,
                assetIn,
                assetOut,
                assetInIndex,
                assetInIndex == 0 ? 1 : 0,
                swapAmountInRaw,
                swapAmountOutRaw
            ),
            tokens
        );

        uint256 sharesReceived = IERC20(fxPoolAddr).balanceOf(address(this));

        require(sharesReceived >= expectedShares, 'RebalanceAddLiq/expected-shares-violation');

        IERC20(fxPoolAddr).transfer(msg.sender, sharesReceived);
    }

    function _calculateBalanceDeltas(
        FXPool fxp,
        uint256 addLiqNumeraire18e,
        address targetTokenToSwapIn,
        uint256 swapAmountInRaw,
        uint256 assetInIndex
    ) private returns (DepositCurvesParam memory, uint256) {
        address assetIn = fxp.derivatives(assetInIndex);
        address assetOut = fxp.derivatives(assetInIndex == 0 ? 1 : 0);

        uint256 swapAmountOutRaw;
        // only perform a swap if the pool is not balanced (ie. outside `RATIO_LOWER_LIMIT` - `RATIO_UPPER_LIMIT` range)
        if (swapAmountInRaw != 0) {
            swapAmountOutRaw = _quoteSwap(fxp.getPoolId(), swapAmountInRaw, assetIn, assetOut);
        }

        return (
            DepositCurvesParam(
                fxp,
                fxp.getPoolId(),
                _calculateAmountLiqToAdd(fxp, addLiqNumeraire18e, assetIn, swapAmountInRaw),
                targetTokenToSwapIn == QUOTE_TOKEN ? int256(-swapAmountOutRaw) : int256(swapAmountInRaw), // baseBalDelta
                targetTokenToSwapIn == QUOTE_TOKEN ? int256(swapAmountInRaw) : int256(-swapAmountOutRaw), // quoteBalDelta
                assetIn,
                assetOut,
                assetInIndex,
                10 ** IERC20Detailed(assetIn == QUOTE_TOKEN ? assetOut : assetIn).decimals()
            ),
            swapAmountOutRaw
        );
    }

    function _calculateDepositsCurves(
        DepositCurvesParam memory d,
        uint256 swapAmountInRaw,
        uint256 swapAmountOutRaw
    ) private view returns (uint256 curves_, uint256[] memory deposits_) {
        // initialize otherwise we get an out of bounds error
        deposits_ = new uint256[](2);
        (int128 _oGLiq, int128[] memory _oBals, uint256[] memory newBalances) = _getGrossLiquidityAndBalancesForDeposit(
            d.poolId,
            d.quoteBalDelta,
            d.baseBalDelta
        );

        int128 __deposit = d.deposit.divu(1e18);

        if (_oGLiq == 0) {
            // pools that haven't been initialized with liquidity are not supported
            revert('RebalanceAddLiq/no-liquidity-violation');
        } else {
            int128 _multiplier = __deposit.div(_oGLiq);

            deposits_[0] = _viewRawAmountLPRatioBase(
                _oBals[0].mul(_multiplier).add(ONE_WEI),
                newBalances[0], // baseTokenBal
                newBalances[1], // quoteTokenBal
                0.5 * 1e18,
                0.5 * 1e18,
                d.baseDecimalsMultiplier
            );

            deposits_[1] = _viewRawAmountLPRatioQuote(_oBals[1].mul(_multiplier).add(ONE_WEI));

            // ensure that swapAmountInRaw and swapAmountOutRaw are accounted for
            deposits_[d.assetInIndex] = deposits_[d.assetInIndex].add(swapAmountInRaw);
            deposits_[d.assetInIndex == 0 ? 1 : 0] = deposits_[d.assetInIndex == 0 ? 1 : 0].sub(swapAmountOutRaw);
        }

        int128 _totalShells = IERC20(address(d.fxp)).totalSupply().divu(1e18);
        int128 _newShells = __deposit;

        if (_totalShells > 0) {
            _newShells = __deposit.div(_oGLiq);
            _newShells = _newShells.mul(_totalShells);
        }

        curves_ = _newShells.mulu(1e18);
    }

    // UsdcToUsdAssimilator.viewRawAmountLPRatio
    function _viewRawAmountLPRatioQuote(int128 amount) private view returns (uint256) {
        return amount.mulu(QUOTE_DECIMALS_MULTIPLIER);
    }

    // BaseToUsdAssimilator.viewRawAmountLPRatio
    function _viewRawAmountLPRatioBase(
        int128 amount,
        uint256 baseTokenBal,
        uint256 quoteTokenBal,
        uint256 baseWeight,
        uint256 quoteWeight,
        uint256 baseDecimalsMultiplier
    ) private view returns (uint256 amount_) {
        // base decimals
        baseTokenBal = baseTokenBal.mul(1e18).div(baseWeight);

        quoteTokenBal = quoteTokenBal.mul(1e18).div(quoteWeight);

        uint256 _rate = quoteTokenBal.mul(baseDecimalsMultiplier).div(baseTokenBal);

        amount_ = amount.mulu(baseDecimalsMultiplier).mul(QUOTE_DECIMALS_MULTIPLIER).div(_rate);
    }

    /**
     * @param newBalances follows FXPool token order:
     *    - index 0 is base token balance
     *    - index 1 is quote token balance
     */
    function _getGrossLiquidityAndBalancesForDeposit(
        bytes32 poolId,
        int256 quoteBalDelta,
        int256 baseBalDelta
    ) private view returns (int128 _oGLiq, int128[] memory _oBals, uint256[] memory newBalances) {
        _oBals = new int128[](2);
        newBalances = new uint256[](2);

        (IERC20[] memory tokens, uint256[] memory balances, ) = IVault(vault).getPoolTokens(poolId);

        // simulate a swap
        (int256 baseTokenBalInt, int256 quoteTokenBalInt) = address(tokens[0]) == QUOTE_TOKEN
            ? (int256(balances[1]) + baseBalDelta, int256(balances[0]) + quoteBalDelta)
            : (int256(balances[0]) + baseBalDelta, int256(balances[1]) + quoteBalDelta);

        require(baseTokenBalInt >= 0, 'RebalanceAddLiq/base-token-bal-violation');
        require(quoteTokenBalInt >= 0, 'RebalanceAddLiq/quote-token-bal-violation');

        uint256 baseTokenBal = uint256(baseTokenBalInt);
        uint256 quoteTokenBal = uint256(quoteTokenBalInt);

        newBalances[0] = baseTokenBal;
        newBalances[1] = quoteTokenBal;

        uint256 _quoteWeight = 0.5 * 1e18;
        uint256 _baseWeight = 0.5 * 1e18;

        // BaseToUsdAssimilator.viewNumeraireBalanceLPRatio()
        if (baseTokenBal <= 0) {
            _oBals[0] = ABDKMath64x64.fromUInt(0);
        } else {
            uint256 quoteTokenBal2 = quoteTokenBal.mul(1e18).div(_quoteWeight);

            uint256 _rate = quoteTokenBal2.mul(1e18).div(baseTokenBal.mul(1e18).div(_baseWeight));

            _oBals[0] = baseTokenBal.mul(_rate).div(QUOTE_DECIMALS_MULTIPLIER).divu(1e18);

            _oGLiq = _oGLiq.add(_oBals[0]);
        }

        // UsdcToUsdAssimilator.viewNumeraireBalanceLPRatio()
        _oBals[1] = quoteTokenBal.divu(QUOTE_DECIMALS_MULTIPLIER);
        _oGLiq = _oGLiq.add(_oBals[1]);
    }

    function _calculateSwapAmount(
        FXPool fxp
    ) private view returns (address targetTokenToSwapIn, uint8 assetInIndex, uint256 swapAmountInRaw) {
        (uint256 total, uint256[] memory individual) = fxp.liquidity();
        address[] memory tokens = new address[](2);
        tokens[0] = fxp.derivatives(0);
        tokens[1] = fxp.derivatives(1);
        (address quoteTokenAddr, address baseTokenAddr) = tokens[0] == QUOTE_TOKEN
            ? (address(tokens[0]), address(tokens[1]))
            : (address(tokens[1]), address(tokens[0]));
        uint256 quoteBalNumeraire = tokens[0] == QUOTE_TOKEN ? individual[0] : individual[1];

        uint256 currentQuoteRatio = quoteBalNumeraire.mul(1e18).div(total);

        // DO NOT rebalance the pool if it's already within the range
        if (currentQuoteRatio > RATIO_LOWER_LIMIT && currentQuoteRatio < RATIO_UPPER_LIMIT) {
            return (targetTokenToSwapIn, assetInIndex, swapAmountInRaw);
        }

        uint256 idealLiquidityToAttainRatio = total.mul(POOL_RATIO_PERCENT).div(10_000);

        targetTokenToSwapIn = currentQuoteRatio < (POOL_RATIO_PERCENT * 1e18) / 10_000 ? quoteTokenAddr : baseTokenAddr;
        assetInIndex = targetTokenToSwapIn == tokens[0] ? 0 : 1;

        uint256 swapAmountNumeraire = currentQuoteRatio < (POOL_RATIO_PERCENT * 1e18) / 10_000
            ? (idealLiquidityToAttainRatio.sub(quoteBalNumeraire))
            : (quoteBalNumeraire.sub(idealLiquidityToAttainRatio));

        swapAmountInRaw = IAssimilator(fxp.assimilator(targetTokenToSwapIn)).viewRawAmount(
            ABDKMath64x64.fromInt(int256(swapAmountNumeraire / 1e18))
        );
    }

    function _transferSwapAsset(FXPool fxp) private returns (uint8 assetInIndex, uint256 swapAmountInRaw) {
        address targetTokenToSwapIn;
        (targetTokenToSwapIn, assetInIndex, swapAmountInRaw) = _calculateSwapAmount(fxp);
        if (swapAmountInRaw > 0) {
            IERC20(targetTokenToSwapIn).transferFrom(msg.sender, address(this), swapAmountInRaw);
        }
    }

    function _swap(
        bytes32 poolId,
        address assetIn,
        address assetOut,
        uint256 swapAmountRaw,
        uint256 minAmountOut
    ) private returns (uint256) {
        IVault v = IVault(vault);

        IVault.SingleSwap memory swapParams = IVault.SingleSwap({
            poolId: poolId,
            kind: IVault.SwapKind.GIVEN_IN,
            assetIn: IAsset(assetIn),
            assetOut: IAsset(assetOut),
            amount: swapAmountRaw,
            userData: bytes('0x')
        });

        IVault.FundManagement memory fundsParams = IVault.FundManagement({
            sender: address(this),
            fromInternalBalance: false,
            recipient: payable(address(this)),
            toInternalBalance: false
        });

        uint256 fxAmountOut = v.swap(swapParams, fundsParams, minAmountOut, block.timestamp);

        return fxAmountOut;
    }

    function _calculateAmountLiqToAdd(
        FXPool _fxp,
        uint256 _addLiqNumeraire18e,
        address _assetIn,
        uint256 swapAmountRaw
    ) private view returns (uint256 amountLiqToAdd1e18) {
        uint256 assetInToTransfer = IAssimilator(_fxp.assimilator(_assetIn)).viewRawAmount(
            ABDKMath64x64.fromInt(int256(_addLiqNumeraire18e / 1e18))
        );

        return
            uint256(
                IAssimilator(_fxp.assimilator(_assetIn))
                    .viewNumeraireAmount(assetInToTransfer.sub(swapAmountRaw))
                    .toUInt()
            ).mul(1e18);
    }

    function _transferLiqAssets(
        FXPool _fxp,
        uint256 _addLiqNumeraire18e,
        address _assetIn,
        address _assetOut,
        uint256 assetInIndex,
        uint256 assetOutIndex,
        uint256 swapAmountInRaw,
        uint256 swapAmountOutRaw
    ) private returns (uint256 amountLiqToAdd1e18) {
        amountLiqToAdd1e18 = _calculateAmountLiqToAdd(_fxp, _addLiqNumeraire18e, _assetIn, swapAmountInRaw);

        (, uint256[] memory expectedToBeAdded) = _fxp.viewDeposit(amountLiqToAdd1e18);
        IERC20(_assetIn).transferFrom(msg.sender, address(this), expectedToBeAdded[assetInIndex]);
        // account for the `swapAmountOutRaw` that was received upon rebalancing (if any)
        IERC20(_assetOut).transferFrom(
            msg.sender,
            address(this),
            expectedToBeAdded[assetOutIndex].sub(swapAmountOutRaw)
        );
    }

    function _addLiquidity(bytes32 poolId, uint256 depositNumeraire, IERC20[] memory sortedTokens) private {
        uint256[] memory maxAmountsIn = new uint256[](2);
        maxAmountsIn[0] = type(uint256).max;
        maxAmountsIn[1] = type(uint256).max;

        bytes memory userData = abi.encode(depositNumeraire, sortedTokens);
        IVault.JoinPoolRequest memory req = IVault.JoinPoolRequest({
            assets: _asIAsset(sortedTokens),
            maxAmountsIn: maxAmountsIn,
            userData: userData,
            fromInternalBalance: false
        });

        IVault(vault).joinPool(poolId, address(this), address(this), req);

        uint256 balLeft0 = sortedTokens[0].balanceOf(address(this));
        uint256 balLeft1 = sortedTokens[1].balanceOf(address(this));

        if (balLeft0 > 0) {
            sortedTokens[0].transfer(msg.sender, balLeft0);
        }
        if (balLeft1 > 0) {
            sortedTokens[1].transfer(msg.sender, balLeft1);
        }
    }

    function _quoteSwap(bytes32 poolId, uint256 amountIn, address tokenIn, address tokenOut) private returns (uint256) {
        IAsset[] memory assets = new IAsset[](2);
        assets[0] = IAsset(tokenIn);
        assets[1] = IAsset(tokenOut);

        IVault.BatchSwapStep[] memory swaps = new IVault.BatchSwapStep[](1);
        swaps[0] = IVault.BatchSwapStep({
            poolId: poolId,
            assetInIndex: 0,
            assetOutIndex: 1,
            amount: amountIn,
            userData: bytes('0x')
        });

        IVault.FundManagement memory funds = IVault.FundManagement({
            sender: msg.sender,
            fromInternalBalance: false,
            recipient: payable(msg.sender),
            toInternalBalance: false
        });

        IVault v = IVault(vault);
        int256[] memory amountOut = v.queryBatchSwap(IVault.SwapKind.GIVEN_IN, swaps, assets, funds);

        // https://github.com/balancer-labs/balancer-v2-monorepo/blob/a51c126c6a868d717a01461c0aa782f03a7990db/pkg/standalone-utils/contracts/BalancerQueries.sol#L66
        uint256 amountOut_ = uint256(-amountOut[1]);
        return amountOut_;
    }

    // ERC20 helper functions copied from balancer-core-v2 ERC20Helpers.sol
    function _asIAsset(IERC20[] memory addresses) internal pure returns (IAsset[] memory assets) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            assets := addresses
        }
    }
}
