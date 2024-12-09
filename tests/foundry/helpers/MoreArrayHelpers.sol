// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

library MoreArrayHelpers {
    function toMemoryArraySortedAsc(
        address[2] memory array
    ) internal pure returns (address[] memory) {
        address[] memory ret = new address[](2);
        if (array[0] < array[1]) {
            ret[0] = array[0];
            ret[1] = array[1];
        } else {
            ret[0] = array[1];
            ret[1] = array[0];
        }
        return ret;
    }
}
