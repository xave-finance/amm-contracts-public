// SPDX-License-Identifier: MIT
pragma solidity ^0.7.3;

import '../core/lib/ABDKMath64x64.sol';

contract MockABDK {
    using ABDKMath64x64 for int128;
    using ABDKMath64x64 for uint256;

    function mulu(int128 x, uint256 y) public pure returns (uint256) {
        return x.mulu(y);
    }

    function divu(uint256 x, uint256 y) public pure returns (int128) {
        return x.divu(y);
    }
}
