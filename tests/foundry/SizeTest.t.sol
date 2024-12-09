// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {FXPoolBaseTest} from "./FXPoolBaseTest.sol";

// forge test that tests the size of the FXPool contract

contract SizeTest is FXPoolBaseTest {
    uint256 constant MAX_SIZE = 24576; // 24KB in bytes

    function testSize() public {
        (address fxPool, , ) = _deployToken13DecToken2DecPool(100 ether);
        bool exceeds = false;
        if (checkContractSize("FXPool", address(fxPool).code.length)) {
            exceeds = true;
        }
        if (
            checkContractSize(
                "FXPoolFactory",
                address(fxPoolFactory).code.length
            )
        ) {
            exceeds = true;
        }
        assertFalse(
            exceeds,
            "One of the contracts exceeds max contract size of 24KB"
        );
    }

    function checkContractSize(
        string memory name,
        uint256 size
    ) internal pure returns (bool exceeds) {
        uint256 sizeKB = (size / 1024) + 1;
        uint256 percentage = (size * 100) / MAX_SIZE;

        console.log(
            string.concat(
                name,
                ": ",
                vm.toString(sizeKB),
                "KB (",
                vm.toString(percentage),
                "% of max)"
            )
        );

        if (size > MAX_SIZE) {
            console.log("[X] Exceeds maximum size!");
            exceeds = true;
        } else if (size > ((MAX_SIZE * 90) / 100)) {
            console.log("[!] Warning: Close to maximum size!");
        } else {
            console.log("[+] Size is okay");
        }
        console.log("---------------------");
    }
}
