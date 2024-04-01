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

pragma solidity ^0.7.3;
import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '../core/interfaces/IOracle.sol';
import {IBaseToUsdAssimilatorInitializable} from '../core/interfaces/IBaseToUsdAssimilatorInitializable.sol';
import {IUsdcToUsdAssimilatorInitializable} from '../core/interfaces/IUsdcToUsdAssimilatorInitializable.sol';
import './BaseToUsdAssimilator.sol';
import './UsdcToUsdAssimilator.sol';

contract AssimilatorFactory is Ownable {
    event NewAssimilator(address indexed caller, bytes32 indexed id, address indexed assimilatorAddress);

    mapping(bytes32 => address) public assimilators;
    IOracle public immutable usdcOracle;
    IERC20 public immutable usdc;
    UsdcToUsdAssimilator public usdcAssimilator;

    constructor(IOracle _usdcOracle, IERC20 _usdc) {
        usdcOracle = _usdcOracle;
        usdc = _usdc;

        usdcAssimilator = new UsdcToUsdAssimilator();
        IUsdcToUsdAssimilatorInitializable(address(usdcAssimilator)).initialize(_usdcOracle, _usdc);
    }

    function getAssimilator(address _base) external view returns (address) {
        bytes32 id = keccak256(abi.encode(_base, usdc));
        return (assimilators[id]);
    }

    function newBaseAssimilator(
        IERC20 _base,
        uint256 _baseDecimals,
        IOracle _baseOracle
    ) public onlyOwner returns (BaseToUsdAssimilator) {
        bytes32 id = keccak256(abi.encode(_base, usdc));
        if (assimilators[id] != address(0)) revert('AssimilatorFactory/already-exists');
        BaseToUsdAssimilator assimilator = new BaseToUsdAssimilator();
        IBaseToUsdAssimilatorInitializable(address(assimilator)).initialize(_baseDecimals, _base, usdc, _baseOracle);
        assimilators[id] = address(assimilator);
        emit NewAssimilator(msg.sender, id, address(assimilator));
        return assimilator;
    }
}
