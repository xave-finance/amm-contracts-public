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

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IOracle} from "./IOracle.sol";

interface IAssimilator {
    function initialize(
        IERC20 _baseToken,
        IERC20 _quoteToken,
        IOracle _oracle
    ) external;

    function getRate() external view returns (uint256);

    function viewRawAmount(int128) external view returns (uint256);

    function viewRawAmountLPRatio(
        uint256,
        uint256,
        // address,
        int128,
        address,
        address
    ) external view returns (uint256);

    function viewNumeraireAmount(uint256) external view returns (int128);

    function viewNumeraireBalanceLPRatio(
        uint256,
        uint256,
        // address,
        address,
        address
    ) external view returns (int128);

    function viewNumeraireBalance(
        address,
        address
    ) external view returns (int128);

    function virtualViewNumeraireBalanceIntake(
        address,
        address,
        uint256
    ) external view returns (int128);

    function virtualViewNumeraireBalanceOutput(
        address,
        address,
        uint256
    ) external view returns (int128);

    function viewNumeraireAmountAndBalance(
        uint256,
        address,
        address
    ) external view returns (int128, int128);
}
