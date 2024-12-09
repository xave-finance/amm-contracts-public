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
import {IOracle} from "../../contracts/core/interfaces/IOracle.sol";
import {IFXPool} from "../../contracts/core/interfaces/IFXPool.sol";
import {FXPoolBaseTest} from "./FXPoolBaseTest.sol";
import {
    FXAssets,
    FXGreeks,
    NewPoolParams
} from "../../contracts/core/FXPoolTypes.sol";

contract FXPoolXSGDTest is FXPoolBaseTest {
    address public FX_POOL;

    function setUp() public override {
        super.setUp();
    }

    function testAddLiquidity() public {
        DeployFXPoolParams memory params = DeployFXPoolParams({
            name: "FX_XSGD_USDC",
            lp: lp,
            protocolPercentFee: 60,
            depositNumeraire: 100 * 1e18,
            quoteToken: address(usdc2),
            baseToken: address(xsgd),
            quoteOracleName: "USDC / USD",
            quoteOraclePrice: 100_000_000,
            baseOracleName: "SGD / USD",
            baseOraclePrice: 74_376_600,
            greeks: _fxDefaultGreeks()
        });
        (FX_POOL, , ) = _deployAndInitializeFXPool(params);

        approveForPool(IERC20(FX_POOL));

        // numeraire for deposits is always in 1e18
        // value taken from "Initial USDC Input" row 38 of the spreadsheet
        // 2 * value of initial USDC Input (or Initial fxXSGD input in numeraire)
        uint256 depositNumeraire = 40000.77048 * 1e18;

        vm.startPrank(lp);
        (
            uint256 quoteTokenTaken,
            uint256 baseTokenTaken,
            uint256 lpMinted
        ) = _addLiquidity("[testAddLiquidity]", FX_POOL, depositNumeraire, lp);

        vm.stopPrank();
        // USDC is 18 decimals in VaultBaseTest
        // slightly more tokens were taken due to roundi    ng - that's correct, what we don't want is to
        // give less tokens for more LP tokens minted

        assertApproxEqAbs(
            quoteTokenTaken,
            20_000.38524 * 1e6,
            1027,
            "quoteTokenTaken"
        );
        assertApproxEqAbs(baseTokenTaken, 26890695783, 222, "baseTokenTaken");

        uint256 errorOffset = 400007704841563; // error is 0.00040001 in 1e18 or approx 0.000001% error margin
        assertApproxEqAbs(
            lpMinted,
            depositNumeraire,
            errorOffset,
            "correct amount of LP tokens minted"
        );
        // the assert above does Abs() so it ensures that the LP tokens minted are
        // slightly less *or more* than the deposited amount; the below assert ensures that it's less
        assertTrue(
            lpMinted <= depositNumeraire,
            "same or slightly less LP tokens minted than deposited"
        );
    }

    function testSwapUsdcToXsgdAndBack() public {
        // synced with the values from the old test
        DeployFXPoolParams memory params = DeployFXPoolParams({
            name: "FX_XSGD_USDC",
            lp: lp,
            protocolPercentFee: 60,
            depositNumeraire: 20000.38524 * 2 * 1e18,
            quoteToken: address(usdc2),
            baseToken: address(xsgd),
            quoteOracleName: "USDC / USD",
            quoteOraclePrice: 100_000_000,
            baseOracleName: "SGD / USD",
            baseOraclePrice: 74_376_600,
            greeks: _fxDefaultGreeks()
        });
        (FX_POOL, , ) = _deployAndInitializeFXPool(params);
        approveForPool(IERC20(FX_POOL));

        vm.startPrank(charlie);

        int256[2][] memory testData = new int256[2][](100);
        // format [swap amount, expected delta]
        // here, "delta" means the amount of tokens that the user received
        testData[0] = [int256(19.469 * 1e6), int256(26163154)];
        testData[1] = [int256(1394.583939 * 1e6), int256(1874092990)];
        testData[2] = [int256(290.341197 * 1e6), int256(390171137)];
        testData[3] = [int256(570.480638 * 1e6), int256(766632781)];
        testData[4] = [int256(1456.067041 * 1e6), int256(1956716234)];
        testData[5] = [int256(1554.833278 * 1e6), int256(2089441922)];
        testData[6] = [int256(1320.738022 * 1e6), int256(1774856140)];
        testData[7] = [int256(1707.528645 * 1e6), int256(2294639550)];
        testData[8] = [int256(524.786895 * 1e6), int256(705227855)];
        testData[9] = [int256(1209.394811 * 1e6), int256(1618089905)];
        testData[10] = [int256(1300.821235 * 1e6), int256(1650779539)];

        _runSwapTestLoop(
            "[swapUsdcToXsgd] test loop #1",
            testData,
            address(usdc2),
            address(xsgd),
            SwapKind.EXACT_IN,
            charlie,
            FX_POOL
        );

        uint256 depositNumeraire = 10_000 * 1e18;
        (, , uint256 lpMinted) = _addLiquidity(
            "[swapUsdcToXsgd]",
            FX_POOL,
            depositNumeraire,
            charlie
        );

        assertApproxEqPctAbsMax(
            lpMinted,
            6379824219177497929914,
            "correct amount of LP tokens minted"
        );

        testData = new int256[2][](100);
        // format [swap amount, expected delta]
        // here, "delta" means the amount of tokens that the user received
        testData[0] = [int256(1000 * 1e6), int256(760095201)];
        testData[1] = [int256(2050 * 1e6), int256(1534262966)];
        testData[2] = [int256(411 * 1e6), int256(305534982)];
        testData[3] = [int256(780 * 1e6), int256(579847411)];
        testData[4] = [int256(1986 * 1e6), int256(1476380716)];
        testData[5] = [int256(2055 * 1e6), int256(1527674910)];
        testData[6] = [int256(1808 * 1e6), int256(1344056563)];
        testData[7] = [int256(2330 * 1e6), int256(1732108292)];
        testData[8] = [int256(720 * 1e6), int256(535243764)];
        testData[9] = [int256(1660 * 1e6), int256(1234034234)];
        testData[10] = [int256(1780 * 1e6), int256(1323241528)];
        testData[11] = [int256(2500 * 1e6), int256(1858485292)];

        _runSwapTestLoop(
            "[swapXsgdToUsdc] test loop #2",
            testData,
            address(xsgd),
            address(usdc2),
            SwapKind.EXACT_IN,
            charlie,
            FX_POOL
        );

        depositNumeraire = 1e18;
        _addLiquidity("[swapUsdcToXsgd]", FX_POOL, depositNumeraire, charlie);

        // burn the exact same amount of LP tokens
        // as received from the 1st deposit
        // @TODO assert that we received the same or slightly less amount of tokens vs deposit
        _removeLiquidity("[swapXsgdToUsdc]", FX_POOL, lpMinted, charlie);
        vm.stopPrank();
    }
}
