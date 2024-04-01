pragma solidity 0.7.6;

import {ABDKMath64x64} from './ABDKMath64x64.sol';

import {Errs, _require} from './FXPoolErrors.sol';

import {FXPool} from '../../FXPool.sol';
import {IOracle} from '../interfaces/IOracle.sol';
import {IAssimilator} from '../interfaces/IAssimilator.sol';
import {IERC20Detailed} from '../../interfaces/IERC20Detailed.sol';

import {IVault} from '@balancer-labs/v2-vault/contracts/interfaces/IVault.sol';

library FXPoolDeployerLib {
    using ABDKMath64x64 for uint256;
    using ABDKMath64x64 for int128;

    int128 private constant ONE_WEI = 0x12;
    // oracle rate decimals is _expected_ to be 1e8 in assimilators as well
    uint256 private constant RATE_DECIMALS = 1e8;

    /// by instantiating the FXPool in this library we can avoid
    /// including it in the FXPoolDeployerProxy contract thus
    /// reducing that contract size
    /// NB: function needs to be public so that the library is
    /// deployed as linked rather than inlined
    function createFXPool(
        address[] memory _assetsToRegister,
        IVault vault,
        uint256 _protocolPercentFee,
        string memory _name,
        string memory _symbol
    ) public returns (address) {
        FXPool fxPool = new FXPool(_assetsToRegister, vault, _protocolPercentFee, _name, _symbol);
        return address(fxPool);
    }

    function viewDepositNoLiquidity(
        uint256 _deposit,
        address _baseToken,
        address _baseOracle,
        address _quoteToken,
        address _quoteAssimilator,
        uint256 _baseWeight,
        uint256 _quoteWeight
    ) public view returns (uint256 expectedShares, uint256 baseTokenAmount, uint256 quoteTokenAmount) {
        int128 __deposit = _deposit.divu(1e18);
        // perform the operation in case there is a rounding error
        expectedShares = __deposit.mulu(1e18);

        int128 __baseWeight = _baseWeight.divu(1e18).add(uint256(1).divu(1e18));
        int128 __quoteWeight = _quoteWeight.divu(1e18).add(uint256(1).divu(1e18));

        baseTokenAmount = viewRawAmountBase(_baseToken, __deposit.mul(__baseWeight).add(ONE_WEI), _baseOracle);

        quoteTokenAmount = viewRawAmountQuote(
            _quoteToken,
            __deposit.mul(__quoteWeight).add(ONE_WEI),
            _quoteAssimilator
        );
    }

    function viewRawAmountBase(address _baseToken, int128 _amount, address _baseOracle) private view returns (uint256) {
        uint256 baseRate = getOracleRate(_baseOracle);
        uint256 decimals = 10 ** IERC20Detailed(_baseToken).decimals();
        return (_amount.mulu(decimals) * RATE_DECIMALS) / baseRate;
    }

    function viewRawAmountQuote(
        address _quotetoken,
        int128 _amount,
        address _quoteAssimilator
    ) private view returns (uint256) {
        uint256 quoteRate = IAssimilator(_quoteAssimilator).getRate();
        uint256 decimals = 10 ** IERC20Detailed(_quotetoken).decimals();
        return (_amount.mulu(decimals) * RATE_DECIMALS) / quoteRate;
    }

    function getOracleRate(address _baseOracle) public view returns (uint256) {
        (uint80 roundId, int256 price, uint256 startedAt, , /*uint256 updatedAt*/ uint80 answeredInRound) = IOracle(
            _baseOracle
        ).latestRoundData();

        _require(price > 0, Errs.ORACLE_PRICE_ZERO);
        _require(startedAt != 0, Errs.ORACLE_ROUND_NOT_COMPLETE);
        // in cases where the time threshold is reached, allow for an additional 15 minute
        // window during which the oracle nodes can push new data to the aggregator
        // only after this time the price is considered stale
        // this fixes the issue whereby nodes might wait until the 24h time limit is reached
        // in order to push new price data to the aggregator. During this short period of time
        // the price would be considered stale and the assimilator would revert
        _require(startedAt + (3600 * 24) + 900 > block.timestamp, Errs.ORACLE_STALE_PRICE);

        return uint256(price);
    }
}
