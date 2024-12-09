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
import {
    Initializable
} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IVault} from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import {
    ScalingHelpers
} from "@balancer-labs/v3-solidity-utils/contracts/helpers/ScalingHelpers.sol";
import {ABDKMath64x64} from "../core/lib/ABDKMath64x64.sol";
import {IAssimilator} from "../core/interfaces/IAssimilator.sol";
import {IOracle} from "../core/interfaces/IOracle.sol";
import {IERC20Detailed} from "../interfaces/IERC20Detailed.sol";
import {_revert, Errs} from "../core/lib/FXPoolErrors.sol";

// Initializable because in the FXPoolDeployer we need to be able to
// clone the baseAssimilatorTemplate
contract BaseAssimilator is Initializable, IAssimilator {
    using ABDKMath64x64 for int128;
    using ABDKMath64x64 for uint256;
    using ScalingHelpers for uint256;

    IERC20 public quoteToken;
    IERC20 public baseToken;
    uint256 public quoteMultiplier;
    uint256 public baseMultiplier;
    IOracle public oracle;
    uint256 public oracleMultiplier;

    function initialize(
        IERC20 _baseToken,
        IERC20 _quoteToken,
        IOracle _oracle
    ) public override initializer {
        baseToken = _baseToken;
        quoteToken = _quoteToken;
        oracle = _oracle;
        if (
            address(_baseToken) != address(0) ||
            address(_baseToken) != address(0) ||
            address(_oracle) != address(0)
        ) {
            quoteMultiplier =
                10 ** IERC20Detailed(address(_quoteToken)).decimals();
            baseMultiplier =
                10 ** IERC20Detailed(address(_baseToken)).decimals();
            oracleMultiplier =
                10 ** IERC20Detailed(address(_oracle)).decimals();
        }
    }

    function getRate() public view override returns (uint256) {
        (, int256 price, , , ) = oracle.latestRoundData();
        if (price <= 0) _revert(Errs.FP_ORACLE_PRICE_ZERO);
        return uint256(price);
    }

    // takes a numeraire amount and returns the raw amount
    function viewRawAmount(
        int128 _amount
    ) external view override returns (uint256 amount_) {
        uint256 _rate = getRate();

        amount_ = (_amount.mulu(baseMultiplier) * oracleMultiplier) / _rate;
    }

    function viewRawAmountLPRatio(
        uint256 _baseWeight,
        uint256 _quoteWeight,
        int128 _amount,
        address vault,
        address pool
    ) external view override returns (uint256 amount_) {
        (uint256 baseTokenBal, uint256 quoteTokenBal) = _getBalancesFromVault(
            vault,
            pool,
            address(quoteToken)
        );

        if (baseTokenBal == 0) return 0;

        baseTokenBal = (baseTokenBal * 1e18) / _baseWeight;
        quoteTokenBal = (quoteTokenBal * 1e18) / _quoteWeight;

        uint256 _rate = (quoteTokenBal * baseMultiplier) / baseTokenBal;
        amount_ = (_amount.mulu(baseMultiplier) * quoteMultiplier) / _rate;
    }

    // takes a raw amount and returns the numeraire amount
    function viewNumeraireAmount(
        uint256 _amount
    ) external view override returns (int128 amount_) {
        uint256 _rate = getRate();

        amount_ = ((_amount * _rate) / oracleMultiplier).divu(baseMultiplier);
    }

    // views the numeraire value of the current balance of the reserve, in this case baseToken
    function viewNumeraireBalance(
        address vault,
        address pool
    ) external view override returns (int128 balance_) {
        uint256 _rate = getRate();

        (uint256 baseTokenBal, ) = _getBalancesFromVault(
            vault,
            pool,
            address(quoteToken)
        );

        if (baseTokenBal <= 0) return ABDKMath64x64.fromUInt(0);

        balance_ = ((baseTokenBal * _rate) / oracleMultiplier).divu(
            baseMultiplier
        );
    }

    // views the numeraire value of the current balance of the reserve, in this case baseToken
    // adds intakeAmount to baseTokenBal to simulate LP deposit
    function virtualViewNumeraireBalanceIntake(
        address vault,
        address pool,
        uint256 intakeAmount
    ) external view override returns (int128 balance_) {
        uint256 _rate = getRate();

        (uint256 baseTokenBal, ) = _getBalancesFromVault(
            vault,
            pool,
            address(quoteToken)
        );
        baseTokenBal += intakeAmount;

        if (baseTokenBal <= 0) return ABDKMath64x64.fromUInt(0);

        balance_ = ((baseTokenBal * _rate) / oracleMultiplier).divu(
            baseMultiplier
        );
    }

    // views the numeraire value of the current balance of the reserve, in this case baseToken
    // subtracts outputAmount to baseTokenBal to simulate LP withdrawal
    function virtualViewNumeraireBalanceOutput(
        address vault,
        address pool,
        uint256 outputAmount
    ) external view override returns (int128 balance_) {
        uint256 _rate = getRate();

        (uint256 baseTokenBal, ) = _getBalancesFromVault(
            vault,
            pool,
            address(quoteToken)
        );
        baseTokenBal = baseTokenBal - outputAmount;

        if (baseTokenBal <= 0) return ABDKMath64x64.fromUInt(0);

        balance_ = ((baseTokenBal * _rate) / oracleMultiplier).divu(
            baseMultiplier
        );
    }

    // views the numeraire value of the current balance of the reserve, in this case baseToken
    // called for swaps
    function viewNumeraireAmountAndBalance(
        uint256 _amount,
        address vault,
        address pool
    ) external view override returns (int128 amount_, int128 balance_) {
        uint256 _rate = getRate();
        amount_ = ((_amount * _rate) / oracleMultiplier).divu(baseMultiplier);

        (uint256 baseTokenBal, ) = _getBalancesFromVault(
            vault,
            pool,
            address(quoteToken)
        );

        balance_ = ((baseTokenBal * _rate) / oracleMultiplier).divu(
            baseMultiplier
        );
    }

    // views the numeraire value of the current balance of the reserve, in this case baseToken
    // instead of calculating with chainlink's "rate" it'll be determined by the existing
    // token ratio. This is in here to prevent LPs from losing out on future oracle price updates
    function viewNumeraireBalanceLPRatio(
        uint256 _baseWeight,
        uint256 _quoteWeight,
        // address _addr,
        address vault,
        address pool
    ) external view override returns (int128 balance_) {
        (uint256 baseTokenBal, uint256 quoteTokenBal) = _getBalancesFromVault(
            vault,
            pool,
            address(quoteToken)
        );

        if (baseTokenBal <= 0) return ABDKMath64x64.fromUInt(0);

        quoteTokenBal = (quoteTokenBal * 1e18) / _quoteWeight;
        uint256 _rate = (quoteTokenBal * 1e18) /
            ((baseTokenBal * 1e18) / _baseWeight);
        balance_ = ((baseTokenBal * _rate) / quoteMultiplier).divu(1e18);
    }

    function _getBalancesFromVault(
        address vault,
        address pool,
        address quoteTokenAddressToCompare
    ) internal view returns (uint256 baseTokenBal, uint256 quoteTokenBal) {
        (IERC20[] memory tokens, , uint256[] memory balancesRaw, ) = IVault(
            vault
        ).getPoolTokenInfo(pool);

        if (address(tokens[0]) == quoteTokenAddressToCompare) {
            baseTokenBal = balancesRaw[1];
            quoteTokenBal = balancesRaw[0];
        } else if (address(tokens[1]) == quoteTokenAddressToCompare) {
            baseTokenBal = balancesRaw[0];
            quoteTokenBal = balancesRaw[1];
        } else {
            _revert(Errs.FP_QUOTE_TOKEN_NOT_IN_POOL);
        }
    }
}
