// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import {IVault} from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import {
    IRouter
} from "@balancer-labs/v3-interfaces/contracts/vault/IRouter.sol";
import {
    IVaultErrors
} from "@balancer-labs/v3-interfaces/contracts/vault/IVaultErrors.sol";
import "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import {
    ArrayHelpers
} from "@balancer-labs/v3-solidity-utils/contracts/test/ArrayHelpers.sol";

import {
    BalancerPoolToken
} from "@balancer-labs/v3-vault/contracts/BalancerPoolToken.sol";
import {
    BaseVaultTest
} from "@balancer-labs/v3-vault/test/foundry/utils/BaseVaultTest.sol";
import {
    ERC20TestToken
} from "@balancer-labs/v3-solidity-utils/contracts/test/ERC20TestToken.sol";

import {FXPoolFactory} from "../../contracts/FXPoolFactory.sol";
import {FXPool} from "../../contracts/FXPool.sol";
import {
    QuoteAssimilator
} from "../../contracts/assimilators/QuoteAssimilator.sol";
import {
    BaseAssimilator
} from "../../contracts/assimilators/BaseAssimilator.sol";
import {
    StaticPriceOracle
} from "../../contracts/periphery/StaticPriceOracle.sol";
import {IOracle} from "../../contracts/core/interfaces/IOracle.sol";
import {IFXPool} from "../../contracts/core/interfaces/IFXPool.sol";
import {
    FXAssets,
    FXGreeks,
    NewPoolParams
} from "../../contracts/core/FXPoolTypes.sol";
import {FXPoolBaseTest} from "./FXPoolBaseTest.sol";

contract FXPoolFactoryTest is FXPoolBaseTest {
    using ArrayHelpers for *;

    function testSetAdminMultiSig() public {
        address newMultisig = makeAddr("newMultisig");
        fxPoolFactory.setAdminMultisig(newMultisig);
        assertEq(fxPoolFactory.adminMultisig(), newMultisig);
    }

    // @TODO test all the other setters in FXPoolFactory

    function testFailSetAdminMultiSig() public {
        address newMultisig = makeAddr("newMultisig");
        vm.prank(eve);
        fxPoolFactory.setAdminMultisig(newMultisig);
    }

    function testFactoryPausedState() public view {
        uint32 pauseWindowDuration = fxPoolFactory.getPauseWindowDuration();
        assertEq(pauseWindowDuration, 365 days);
    }
}
