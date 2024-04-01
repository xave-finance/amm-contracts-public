// SPDX-License-Identifier: agpl-3.0
pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

import {WETH9} from './dependencies/WETH9.sol';

contract MockWETH9 is WETH9 {
	// Mint not backed by Ether: only for testing purposes
	function mint(uint256 value) public returns (bool) {
		balanceOf[msg.sender] += value;
		emit Transfer(address(0), msg.sender, value);
	}
}
