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
import {ABDKMath64x64} from "../core/lib/ABDKMath64x64.sol";
import {IAssimilator} from "../core/interfaces/IAssimilator.sol";
import {IOracle} from "../core/interfaces/IOracle.sol";
import {
    ScalingHelpers
} from "@balancer-labs/v3-solidity-utils/contracts/helpers/ScalingHelpers.sol";
import {IERC20Detailed} from "../interfaces/IERC20Detailed.sol";
import {_revert, Errs} from "../core/lib/FXPoolErrors.sol";

// Initializable because in the FXPoolDeployer we need to be able to
// clone the baseAssimilatorTemplate
contract QuoteAssimilator is Initializable, IAssimilator {
    using ABDKMath64x64 for int128;
    using ABDKMath64x64 for uint256;
    using ScalingHelpers for uint256;

    IOracle public oracle;
    IERC20 public quoteToken;
    uint256 public quoteMultiplier;
    uint256 public oracleMultiplier;

    function initialize(
        IERC20,
         IERC20 _quoteToken,
        IOracle _oracle
    ) public override initializer {
        oracle = _oracle;
        quoteToken = _quoteToken;

        if (
            address(_quoteToken) != address(0) || address(_oracle) != address(0)
        ) {
            quoteMultiplier =
                10 ** IERC20Detailed(address(_quoteToken)).decimals();
            oracleMultiplier =
                10 ** IERC20Detailed(address(_oracle)).decimals();
        }
    }

    // solhint-disable-next-line
    function getRate() public view override returns (uint256) {
        (, int256 price, , , ) = oracle.latestRoundData();
        if (price <= 0) _revert(Errs.FP_ORACLE_PRICE_ZERO);
        return uint256(price);
    }

    function viewRawAmount(
        int128 _amount
    ) external view override returns (uint256 amount_) {
        uint256 _rate = getRate();

        amount_ = (_amount.mulu(quoteMultiplier) * oracleMultiplier) / _rate;
    }

    function viewRawAmountLPRatio(
        uint256,
        uint256,
        int128 _amount,
        address,
        address
    ) external view override returns (uint256 amount_) {
        amount_ = _amount.mulu(quoteMultiplier);
    }

    function viewNumeraireAmount(
        uint256 _amount
    ) external view override returns (int128 amount_) {
        uint256 _rate = getRate();

        amount_ = ((_amount * _rate) / oracleMultiplier).divu(quoteMultiplier);
    }

    function viewNumeraireBalance(
        address vault,
        address pool
    ) public view override returns (int128 balance_) {
        uint256 _rate = getRate();

        uint256 quoteBalance = _getBalancesFromVault(
            vault,
            pool,
            address(quoteToken)
        );

        if (quoteBalance <= 0) return ABDKMath64x64.fromUInt(0);

        balance_ = ((quoteBalance * _rate) / oracleMultiplier).divu(
            quoteMultiplier
        );
    }

    // adds intakeAmount to baseTokenBal to simulate LP deposit
    function virtualViewNumeraireBalanceIntake(
        address vault,
        address pool,
        uint256 intakeAmount
    ) external view override returns (int128 balance_) {
        uint256 _rate = getRate();

        uint256 quoteBalance = _getBalancesFromVault(
            vault,
            pool,
            address(quoteToken)
        );
        quoteBalance += intakeAmount;

        if (quoteBalance <= 0) return ABDKMath64x64.fromUInt(0);

        balance_ = ((quoteBalance * _rate) / oracleMultiplier).divu(
            quoteMultiplier
        );
    }

    // adds outputAmount to baseTokenBal to simulate LP deposit
    function virtualViewNumeraireBalanceOutput(
        address vault,
        address pool,
        uint256 outputAmount
    ) external view override returns (int128 balance_) {
        uint256 _rate = getRate();

        uint256 quoteBalance = _getBalancesFromVault(
            vault,
            pool,
            address(quoteToken)
        );

        quoteBalance = quoteBalance - outputAmount;

        if (quoteBalance <= 0) return ABDKMath64x64.fromUInt(0);

        balance_ = ((quoteBalance * _rate) / oracleMultiplier).divu(
            quoteMultiplier
        );
    }

    function viewNumeraireAmountAndBalance(
        uint256 _amount,
        address vault,
        address pool
    ) external view override returns (int128 amount_, int128 balance_) {
        uint256 _rate = getRate();

        amount_ = ((_amount * _rate) / oracleMultiplier).divu(quoteMultiplier);

        uint256 quoteBalance = _getBalancesFromVault(
            vault,
            pool,
            address(quoteToken)
        );

        balance_ = ((quoteBalance * _rate) / oracleMultiplier).divu(
            quoteMultiplier
        );
    }

    // views the numeraire value of the current balance of the reserve wrt to USD
    // since this is already the USD assimlator, the ratio is just 1
    function viewNumeraireBalanceLPRatio(
        uint256,
        uint256,
        // address _addr,
        address vault,
        address pool
    ) external view override returns (int128 balance_) {
        (IERC20[] memory tokens, , uint256[] memory balancesRaw, ) = IVault(
            vault
        ).getPoolTokenInfo(pool);

        if (address(tokens[0]) == address(quoteToken)) {
            balance_ = balancesRaw[0].divu(quoteMultiplier);
        } else {
            balance_ = balancesRaw[1].divu(quoteMultiplier);
        }
    }

    function _getBalancesFromVault(
        address vault,
        address pool,
        address quoteTokenAddressToCompare
    ) internal view returns (uint256 quoteTokenBal) {
        (IERC20[] memory tokens, , uint256[] memory balancesRaw, ) = IVault(
            vault
        ).getPoolTokenInfo(pool);

        if (address(tokens[0]) == quoteTokenAddressToCompare) {
            quoteTokenBal = balancesRaw[0];
        } else if (address(tokens[1]) == quoteTokenAddressToCompare) {
            quoteTokenBal = balancesRaw[1];
        } else {
            _revert(Errs.FP_QUOTE_TOKEN_NOT_IN_POOL);
        }
    }
}
