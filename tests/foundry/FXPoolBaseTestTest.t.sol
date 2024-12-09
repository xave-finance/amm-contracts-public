// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

import {FXPoolBaseTest} from "./FXPoolBaseTest.sol";

struct TwoUintTest {
    uint256 left;
    uint256 right;
    bool shouldPass;
}

contract FXPoolBaseTestTest is FXPoolBaseTest {
    using Strings for uint256;

    function test_assertLeBounded() public {
        assertLeBounded(2, 2, 0, "");
        assertLeBounded(1, 2, 1, "");
        assertLeBounded(1, 2, 3, "");
        vm.expectRevert();
        assertLeBounded(4, 3, 0, "");
        vm.expectRevert();
        assertLeBounded(4, 3, 1, "");
        vm.expectRevert();
        assertLeBounded(2, 4, 1, "");
    }

    function test_assertLeBoundedPercentMax() public {
        TwoUintTest[] memory data = new TwoUintTest[](100);
        data[0] = TwoUintTest(2e27 - 3e20, 2e27, true);
        data[1] = TwoUintTest(1e7 - 1, 1e7, true);
        data[1] = TwoUintTest(1e8 - 99, 1e8, true);

        data[1] = TwoUintTest(1e7 - 2, 1e7, false);
        data[1] = TwoUintTest(1e7 + 1, 1e7, false);
        data[1] = TwoUintTest(1, 1, false);
        data[1] = TwoUintTest(1, 1e2, false);
        data[1] = TwoUintTest(1, 1e3, false);
        data[1] = TwoUintTest(1, 1e4, false);
        data[1] = TwoUintTest(1, 1e5, false);
        data[1] = TwoUintTest(1, 1e6, false);

        for (uint256 i; i <= data.length - 1; i++) {
            if (data[i].left == 0 && data[i].right == 0) {
                continue;
            }

            string memory m = string.concat(
                data[i].left.toString(),
                " <=~ ",
                data[i].right.toString()
            );
            if (data[i].shouldPass) {
                assertLeBoundedPercentMax(data[i].left, data[i].right, m);
            } else {
                vm.expectRevert();
                assertLeBoundedPercentMax(data[i].left, data[i].right, m);
            }
        }
    }

    function test_tokenAmount() public view {
        assertEq(
            tokenAmount(1_000, address(token2Dec)),
            1_000 * 1e2,
            "tokenAmount 2 dec"
        );
        assertEq(
            tokenAmount(1_000, address(token6Dec)),
            1_000 * 1e6,
            "tokenAmount 6 dec"
        );
        assertEq(
            tokenAmount(1_000, address(token13Dec)),
            1_000 * 1e13,
            "tokenAmount 13 dec"
        );
        assertEq(
            tokenAmount(0, address(token13Dec)),
            0,
            "tokenAmount 13 dec (0 val)"
        );
    }

    function test_tokenAmountScaled18() public view {
        uint256 amtDec2 = tokenAmount(1_000, address(token2Dec));
        uint256 amtDec13 = tokenAmount(1_000, address(token13Dec));
        assertEq(
            tokenAmountScaled18(amtDec2, address(token2Dec)),
            tokenAmountScaled18(amtDec13, address(token13Dec)),
            "1000 token2Dec == 1000 token13Dec when scaled to 18"
        );
    }
}
