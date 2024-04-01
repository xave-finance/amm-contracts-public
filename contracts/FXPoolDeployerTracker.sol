// SPDX-License-Identifier: MIT

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is disstributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

pragma solidity 0.7.6;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';

/**
 * @title FXPoolDeployerTracker
 * @notice Tracks FXPoolDeployers in the subgraph
 */
contract FXPoolDeployerTracker is Ownable {
    event NewFXPoolDeployer(address indexed quoteToken, address indexed deployer, address indexed caller);

    // quote token => deployer address
    mapping(address => address) public fxPoolDeployers;

    function broadcastNewDeployer(address _quoteToken, address _deployer) external onlyOwner {
        require(fxPoolDeployers[_quoteToken] == address(0));
        fxPoolDeployers[_quoteToken] = _deployer;
        emit NewFXPoolDeployer(_quoteToken, _deployer, msg.sender);
    }

    function setDeployer(address _quoteToken, address _deployer) external onlyOwner {
        require(fxPoolDeployers[_quoteToken] == address(0));
        fxPoolDeployers[_quoteToken] = _deployer;
    }
}
