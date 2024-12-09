// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import {IVault} from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import {
    IRouter
} from "@balancer-labs/v3-interfaces/contracts/vault/IRouter.sol";
import "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";
import {
    SwapKind
} from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {
    ArrayHelpers
} from "@balancer-labs/v3-solidity-utils/contracts/test/ArrayHelpers.sol";

import {
    BaseVaultTest
} from "@balancer-labs/v3-vault/test/foundry/utils/BaseVaultTest.sol";
import {
    ERC20TestToken
} from "@balancer-labs/v3-solidity-utils/contracts/test/ERC20TestToken.sol";
import {
    CastingHelpers
} from "@balancer-labs/v3-solidity-utils/contracts/helpers/CastingHelpers.sol";
import {
    ScalingHelpers
} from "@balancer-labs/v3-solidity-utils/contracts/helpers/ScalingHelpers.sol";
import {
    IERC20Metadata
} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {FXScalingHelpers} from "../../contracts/core/lib/FXScalingHelpers.sol";
import {
    FixedPoint
} from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";

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
import {MoreArrayHelpers} from "./helpers/MoreArrayHelpers.sol";
import {FXPoolFactory} from "../../contracts/FXPoolFactory.sol";
import {IERC20Detailed} from "../../contracts/interfaces/IERC20Detailed.sol";
import {
    FXAssets,
    FXGreeks,
    NewPoolParams,
    PoolBoundaries
} from "../../contracts/core/FXPoolTypes.sol";

abstract contract FXPoolBaseTest is BaseVaultTest {
    using CastingHelpers for address[];
    using ArrayHelpers for *;
    using MoreArrayHelpers for *;
    using ScalingHelpers for *;
    using FXScalingHelpers for *;

    uint256 internal ALPHA = 0.8 * 1e18;
    uint256 internal BETA = 0.48 * 1e18;
    uint256 internal MAX = 0.175 * 1e18;
    uint256 internal EPSILON = 0.0005 * 1e18;
    uint256 internal LAMBDA = 0.3 * 1e18;
    // most tests with fixed value are based on having kappa = 0
    uint256 internal KAPPA = 0;
    // maximum error percentage in 5 decimal places
    uint256 constant MAX_ERROR_PCT5e = 100; // 100 == 0.001%

    FXPoolFactory internal fxPoolFactory;
    ERC20TestToken internal xsgd;
    ERC20TestToken internal usdc2;
    // 2 decimals token
    ERC20TestToken internal eurs;

    ERC20TestToken internal token2Dec;
    ERC20TestToken internal token6Dec;
    ERC20TestToken internal token13Dec;

    uint256 constant defaultBalanceNoDecimals = 1e12;
    // @TODO remove once Balancer fixes issue with `createUser` not being token decimals aware
    address payable internal charlie;
    uint256 internal charlieKey;
    address payable internal eve;
    uint256 internal eveKey;
    address payable internal grace;
    uint256 internal graceKey;

    // multi sig
    address internal adminMultiSig;

    struct DeployFXPoolParams {
        string name;
        address lp; // user where tokens should transfer from for initial deposit
        uint256 protocolPercentFee;
        uint256 depositNumeraire;
        address quoteToken;
        address baseToken;
        string quoteOracleName;
        int256 quoteOraclePrice;
        string baseOracleName;
        int256 baseOraclePrice;
        FXGreeks greeks;
    }

    function setUp() public virtual override {
        // create and add the custom token to the list of tokens
        xsgd = createERC20("XSGD", 6);
        vm.label(address(xsgd), "XSGD");
        usdc2 = createERC20("USDC", 6);
        vm.label(address(usdc2), "USDC");
        eurs = createERC20("EURS", 2);
        vm.label(address(eurs), "EURS");
        token2Dec = createERC20("2DEC", 2);
        vm.label(address(token2Dec), "Token 2 Decimals");
        token6Dec = createERC20("6DEC", 6);
        vm.label(address(token6Dec), "Token 6 Decimals");
        token13Dec = createERC20("13DEC", 13);
        vm.label(address(token13Dec), "Token 13 Decimals");
        tokens.push(xsgd);
        tokens.push(usdc2);
        tokens.push(eurs);
        tokens.push(token2Dec);
        tokens.push(token6Dec);
        tokens.push(token13Dec);

        adminMultiSig = makeAddr("XaveMultiSig");
        super.setUp();

        // create the new users after parent::setUp in order to have access
        // to parent tokens like DAI, USDC, etc.
        (charlie, charlieKey) = _createUser("charlie");
        users.push(charlie);
        (eve, eveKey) = _createUser("eve");
        users.push(eve);
        (grace, graceKey) = _createUser("grace");
        users.push(grace);

        // Approve vault allowances
        for (uint256 i = 0; i < users.length; ++i) {
            address user = users[i];
            vm.startPrank(user);
            approveForSender();
            vm.stopPrank();
        }

        // assimilator templates for FXPoolFactory
        QuoteAssimilator quoteAssim = new QuoteAssimilator();
        BaseAssimilator baseAssim = new BaseAssimilator();
        quoteAssim.initialize(
            IERC20(address(0)),
            IERC20(address(0)),
            IOracle(address(0))
        );
        baseAssim.initialize(
            IERC20(address(0)),
            IERC20(address(0)),
            IOracle(address(0))
        );

        fxPoolFactory = new FXPoolFactory(
            IVault(address(vault)),
            address(baseAssim),
            address(quoteAssim),
            address(permit2),
            365 days,
            "Factory v1",
            adminMultiSig
        );
        vm.label(address(fxPoolFactory), "fxpool factory");
        vm.label(address(baseAssim), "baseAssimTemplate");
        vm.label(address(quoteAssim), "quoteAssimTemplate");
    }

    function _approveUserPool(
        address _pool,
        address _user,
        address _quoteToken,
        address _baseToken
    ) internal {
        // Approve tokens for the _user
        vm.startPrank(_user);
        // _user gives allowance to permit2 to spend their tokens
        IERC20(_quoteToken).approve(address(permit2), type(uint256).max);
        IERC20(_baseToken).approve(address(permit2), type(uint256).max);
        IFXPool(_pool).approve(address(permit2), type(uint256).max);
        IFXPool(_pool).approve(address(router), type(uint256).max);
        // _user approves permit2 to approve the router to spend the _user's tokens
        permit2.approve(
            _quoteToken,
            address(router),
            type(uint160).max,
            type(uint48).max
        );
        permit2.approve(
            _baseToken,
            address(router),
            type(uint160).max,
            type(uint48).max
        );
        vm.stopPrank();
    }

    function _deployAndInitializeFXPool(
        DeployFXPoolParams memory params
    )
        internal
        returns (
            address fxPool,
            uint256[] memory initAmounts,
            uint256[] memory initAmountsScaled18
        )
    {
        NewPoolParams memory newPoolParams = NewPoolParams({
            name: params.name,
            symbol: params.name,
            protocolPercentFee: params.protocolPercentFee,
            owner: address(this),
            assets: FXAssets({
                quoteToken: params.quoteToken,
                quoteWeight: 5e17,
                baseToken: params.baseToken,
                baseWeight: 5e17
            }),
            greeks: params.greeks
        });

        address baseOracle = address(
            new StaticPriceOracle(
                params.baseOraclePrice,
                8,
                params.baseOracleName
            )
        );
        address quoteOracle = address(
            new StaticPriceOracle(
                params.quoteOraclePrice,
                8,
                params.quoteOracleName
            )
        );

        fxPoolFactory.adminApproveBaseOracle(baseOracle);
        fxPoolFactory.adminApproveQuoteOracle(quoteOracle);
        fxPool = fxPoolFactory.create(newPoolParams, baseOracle, quoteOracle);
        // set approvals for all test users for this pool
        approveForPool(IERC20(fxPool));

        if (params.depositNumeraire > 0) {
            (initAmounts, initAmountsScaled18) = _initializeFXPool(
                fxPool,
                params.quoteToken,
                params.baseToken,
                params.depositNumeraire,
                params.lp
            );
        } else {
            initAmounts = new uint256[](2);
            initAmounts[0] = 0;
            initAmounts[1] = 0;

            initAmountsScaled18 = new uint256[](2);
            initAmountsScaled18[0] = 0;
            initAmountsScaled18[1] = 1;
        }

        vm.label(fxPool, params.name);
    }

    function _initializeFXPool(
        address fxPool,
        address quoteToken,
        address baseToken,
        uint256 depositNumeraire,
        address user
    )
        internal
        returns (
            uint256[] memory initAmounts,
            uint256[] memory initAmountsScaled18
        )
    {
        uint256 quoteBal = IERC20(quoteToken).balanceOf(user);
        uint256 baseBal = IERC20(baseToken).balanceOf(user);

        // Initialize pool
        vm.startPrank(user);
        (, initAmounts) = IFXPool(fxPool).viewDeposit(depositNumeraire);

        router.initialize(
            fxPool,
            [quoteToken, baseToken].toMemoryArraySortedAsc().asIERC20(),
            [initAmounts[0], initAmounts[1]].toMemoryArray(),
            0,
            false,
            ""
        );
        vm.stopPrank();

        uint256 quoteBalDelta = quoteBal - IERC20(quoteToken).balanceOf(user);
        uint256 baseBalDelta = baseBal - IERC20(baseToken).balanceOf(user);
        assertEq(
            quoteBalDelta,
            IFXPool(fxPool).isQuoteIndexZero()
                ? initAmounts[0]
                : initAmounts[1],
            "correct quote token delta transferred from user"
        );
        assertEq(
            baseBalDelta,
            IFXPool(fxPool).isQuoteIndexZero()
                ? initAmounts[1]
                : initAmounts[0],
            "correct base token delta transferred from user"
        );
        initAmountsScaled18 = new uint256[](2);

        initAmountsScaled18[0] = initAmounts[0].toScaled18RoundUp(
            computeScalingFactor(IERC20(IFXPool(fxPool).tokens(0)))
        );
        initAmountsScaled18[1] = initAmounts[1].toScaled18RoundUp(
            computeScalingFactor(IERC20(IFXPool(fxPool).tokens(1)))
        );
    }

    function _deployToken13DecToken2DecPool(
        uint256 _depositNumeraire
    )
        internal
        returns (
            address fxPool,
            uint256[] memory initAmounts,
            uint256[] memory initAmountsScaled18
        )
    {
        DeployFXPoolParams memory params = DeployFXPoolParams({
            name: "FX_DAI_USDC",
            lp: lp,
            protocolPercentFee: 60,
            depositNumeraire: _depositNumeraire,
            quoteToken: address(token13Dec),
            baseToken: address(token2Dec),
            quoteOracleName: "2DEC / 13DEC",
            quoteOraclePrice: 100_000_000,
            baseOracleName: "2DEC / 13DEC",
            baseOraclePrice: 100_000_000,
            greeks: _fxDefaultGreeks()
        });

        (fxPool, initAmounts, initAmountsScaled18) = _deployAndInitializeFXPool(
            params
        );
    }

    function _deployZeroFeeFXPool(
        uint256 _depositNumeraire,
        address _user,
        address _quoteToken,
        address _baseToken
    ) internal returns (address fxPoolAddr) {
        FXGreeks memory gks = _fxDefaultGreeks();
        gks.epsilon = 0; // fixed fee
        gks.lambda = 0; // dynamic fee
        DeployFXPoolParams memory params = DeployFXPoolParams({
            // @TODO use quote token symbol
            name: "FX_BASE_TOKEN_QUOTE_TOKEN",
            lp: _user,
            protocolPercentFee: 0,
            depositNumeraire: _depositNumeraire,
            quoteToken: _quoteToken,
            baseToken: _baseToken,
            // @TODO use quote token symbol
            quoteOracleName: "QUOTE_TOKEN / USD",
            quoteOraclePrice: 100_000_000,
            baseOracleName: "BASE_TOKEN / USD",
            // set the oracle as $1 for BASE_TOKEN to make calculations easier
            baseOraclePrice: 100_000_000,
            greeks: gks
        });

        vm.startPrank(_user);
        IERC20(_quoteToken).approve(address(permit2), type(uint256).max);
        IERC20(_baseToken).approve(address(permit2), type(uint256).max);
        permit2.approve(
            address(_quoteToken),
            address(router),
            type(uint160).max,
            type(uint48).max
        );
        permit2.approve(
            address(_baseToken),
            address(router),
            type(uint160).max,
            type(uint48).max
        );
        permit2.approve(
            address(_quoteToken),
            address(vault),
            type(uint160).max,
            type(uint48).max
        );
        permit2.approve(
            address(_baseToken),
            address(vault),
            type(uint160).max,
            type(uint48).max
        );
        vm.stopPrank();

        (fxPoolAddr, , ) = _deployAndInitializeFXPool(params);
    }

    function _addLiquidity(
        string memory,
        /*_testName*/ address fxPool,
        uint256 depositNumeraire,
        address walletAddr
    )
        internal
        returns (
            uint256 quoteTokenTaken,
            uint256 baseTokenTaken,
            uint256 lpMinted
        )
    {
        IVault vault = IFXPool(fxPool).getVault();

        (, , uint256[] memory balancesBefore, ) = IVault(vault)
            .getPoolTokenInfo(fxPool);

        uint256 lpBalBefore = IFXPool(fxPool).balanceOf(address(walletAddr));

        router.addLiquidityCustom(
            fxPool,
            // @TODO cannot provide max uint256 because of arithmetic overflow in toScaled18ApplyRateRoundDown
            [uint256(1e42), uint256(1e42)].toMemoryArray(),
            0,
            false,
            abi.encode(depositNumeraire)
        );

        (, , uint256[] memory balancesAfter, ) = IVault(vault).getPoolTokenInfo(
            fxPool
        );

        quoteTokenTaken = IFXPool(fxPool).isQuoteIndexZero()
            ? balancesAfter[0] - balancesBefore[0]
            : balancesAfter[1] - balancesBefore[1];
        baseTokenTaken = IFXPool(fxPool).isQuoteIndexZero()
            ? balancesAfter[1] - balancesBefore[1]
            : balancesAfter[0] - balancesBefore[0];

        lpMinted = IFXPool(fxPool).balanceOf(address(walletAddr)) - lpBalBefore;

        // console.log(_testName, 'quoteTokenTaken:', quoteTokenTaken);
        // console.log(_testName, 'baseTokenTaken:', baseTokenTaken);
        // console.log(_testName, 'lpTokensReceived:', lpMinted);
        // console.log(_testName, 'fxPool.totalSupply:', IFXPool(fxPool).totalSupply());
        // console.log('-----------------------------------------------------');

        assertTrue(
            quoteTokenTaken > 0,
            "[addLiquidity] has quote token balance"
        );
        assertTrue(baseTokenTaken > 0, "[addLiquidity] has base token balance");
        assertTrue(lpMinted > 0, "[addLiquidity] has minted LP tokens");
        // changed to do accomodate calculations in terms of pool ratio
        // assertTrue(lpMinted <= lpTokens, '[addLiquidity] has minted correct amount of LP tokens');
    }

    function _collectProtocolFees(address fxPool) internal {
        router.addLiquidityCustom(
            fxPool,
            // @TODO cannot provide max uint256 because of arithmetic overflow in toScaled18ApplyRateRoundDown
            [uint256(1e42), uint256(1e42)].toMemoryArray(),
            0,
            false,
            abi.encode(1e16)
        );
    }

    function _removeLiquidity(
        string memory,
        /*_testName*/ address fxPool,
        uint256 lpToBurn,
        address walletAddr
    )
        internal
        returns (
            uint256 quoteTokenGiven,
            uint256 baseTokenGiven,
            uint256 lpBurnt
        )
    {
        // console.log(_testName, '-------------- WITHDRAWAL --------------');
        // console.log(_testName, 'lpToBurn:', lpToBurn);

        IVault vault = IFXPool(fxPool).getVault();

        (, , uint256[] memory balancesBefore, ) = IVault(vault)
            .getPoolTokenInfo(fxPool);

        uint256 lpBalBefore = IFXPool(fxPool).balanceOf(address(walletAddr));

        router.removeLiquidityCustom(
            fxPool,
            lpToBurn,
            [uint256(0), uint256(0)].toMemoryArray(),
            false,
            abi.encode(lpToBurn)
        );
        (, , uint256[] memory balancesAfter, ) = IVault(vault).getPoolTokenInfo(
            fxPool
        );

        quoteTokenGiven = IFXPool(fxPool).isQuoteIndexZero()
            ? balancesBefore[0] - balancesAfter[0]
            : balancesBefore[1] - balancesAfter[1];
        baseTokenGiven = IFXPool(fxPool).isQuoteIndexZero()
            ? balancesBefore[1] - balancesAfter[1]
            : balancesBefore[0] - balancesAfter[0];
        lpBurnt = lpBalBefore - IFXPool(fxPool).balanceOf(address(walletAddr));

        // console.log(_testName, 'quoteTokenGiven:', quoteTokenGiven);
        // console.log(_testName, 'baseTokenGiven:', baseTokenGiven);
        // console.log(_testName, 'lpTokens burnt:', lpBurnt);
        // console.log(_testName, 'fxPool.totalSupply:', IFXPool(fxPool).totalSupply());
        // console.log('-----------------------------------------------------');

        assertTrue(
            quoteTokenGiven > 0,
            "[removeLiquidity] has quote token balance"
        );
        assertTrue(
            baseTokenGiven > 0,
            "[removeLiquidity] has base token balance"
        );
        assertTrue(
            lpBurnt == lpToBurn,
            "[removeLiquidity] has burnt LP tokens"
        );
    }

    function _swapExactIn(
        string memory _testName,
        address fxPool,
        IERC20 tokenIn,
        IERC20 tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address walletAddr
    ) internal returns (uint256 inBalDelta, uint256 amountOut) {
        uint256 balNumeraireBefore = _userTotalBalancesNumeraire(
            fxPool,
            walletAddr
        );

        // flag to check user balances to ensure that they are not increasing after a swap
        // the only times user balances should increase is when they swap back into beta region
        // or when kappa > epsilon and the swap is a balance improving one within beta region
        bool checkBalances;

        {
            (bool isInBeta, , address betaToken) = IFXPool(fxPool).isInBeta();
            // if we're not in beta region AND tokenIn == betaToken, then we should not enforce
            // balances to not increase since the pool should reward the user for swapping back into beta
            checkBalances = isInBeta || tokenIn != IERC20(betaToken);
            // another case is when kappa > epsilon and the swap is a balance improving one
            // within beta region
            // get fxpool params
            (, , , uint256 epsilon, , uint256 kappa) = IFXPool(fxPool)
                .viewParameters();
            checkBalances = checkBalances && kappa <= epsilon;
        }

        {
            uint256 inBalBefore = tokenIn.balanceOf(address(walletAddr));

            amountOut = router.swapSingleTokenExactIn(
                fxPool,
                tokenIn,
                tokenOut,
                amountIn,
                amountOutMin,
                block.timestamp + 1000,
                false,
                abi.encode("")
            );
            inBalDelta = inBalBefore - tokenIn.balanceOf(address(walletAddr));
        }

        if (checkBalances) {
            uint256 balNumeraireAfter = _userTotalBalancesNumeraire(
                fxPool,
                walletAddr
            );
            assertLe(
                balNumeraireAfter,
                balNumeraireBefore,
                string(
                    abi.encodePacked(
                        "[",
                        _testName,
                        "]: ",
                        "numeraire balance should not increase after swap"
                    )
                )
            );
        }
    }

    function _swapExactOut(
        string memory _testName,
        address fxPool,
        IERC20 tokenIn,
        IERC20 tokenOut,
        uint256 amountOut,
        uint256 amountInMax,
        address walletAddr
    ) internal returns (uint256 tokenInBalDelta, uint256 amountIn) {
        uint256 balNumeraireBefore = _userTotalBalancesNumeraire(
            fxPool,
            walletAddr
        );

        // flag to check user balances to ensure that they are not increasing after a swap
        // the only times user balances should increase is when they swap back into beta region
        // or when kappa > epsilon and the swap is a balance improving one within beta region
        bool checkBalances;

        {
            (bool isInBeta, , address betaToken) = IFXPool(fxPool).isInBeta();
            // if we're not in beta region AND tokenIn == betaToken, then we should not enforce
            // balances to not increase since the pool should reward the user for swapping back into beta
            checkBalances = isInBeta || tokenIn != IERC20(betaToken);
            // another case is when kappa > epsilon and the swap is a balance improving one
            // within beta region
            // get fxpool params
            (, , , uint256 epsilon, , uint256 kappa) = IFXPool(fxPool)
                .viewParameters();
            checkBalances = checkBalances && kappa <= epsilon;
        }

        {
            uint256 inBalBefore = tokenIn.balanceOf(address(walletAddr));
            uint256 outBalBefore = tokenOut.balanceOf(address(walletAddr));

            amountIn = router.swapSingleTokenExactOut(
                fxPool,
                tokenIn,
                tokenOut,
                amountOut,
                amountInMax,
                block.timestamp + 1000,
                false,
                abi.encode("")
            );

            uint256 inBalDelta = inBalBefore -
                tokenIn.balanceOf(address(walletAddr));
            tokenInBalDelta =
                tokenOut.balanceOf(address(walletAddr)) -
                outBalBefore;

            assertEq(amountIn, inBalDelta, "correct amount in");
        }

        if (checkBalances) {
            uint256 balNumeraireAfter = _userTotalBalancesNumeraire(
                fxPool,
                walletAddr
            );
            assertLe(
                balNumeraireAfter,
                balNumeraireBefore,
                string(
                    abi.encodePacked(
                        "[",
                        _testName,
                        "]: ",
                        "numeraire balance should not increase after swap"
                    )
                )
            );
        }
    }

    function _swapToBalance(
        address _fxPool,
        address _user,
        SwapKind _swapKind
    ) internal returns (uint256 inBalDelta, uint256 amountOut) {
        (
            address fromToken,
            address toToken,
            ,
            uint256 swapAmtNumeraire
        ) = IFXPool(_fxPool).viewSwapToBalancePool();

        uint256 swapAmt = _swapKind == SwapKind.EXACT_IN
            ? IFXPool(_fxPool).convertNumeraireToRaw(
                fromToken,
                swapAmtNumeraire
            )
            : IFXPool(_fxPool).convertNumeraireToRaw(toToken, swapAmtNumeraire);

        vm.startPrank(_user);
        if (_swapKind == SwapKind.EXACT_IN) {
            (inBalDelta, amountOut) = _swapExactIn(
                "_swapToBalance",
                _fxPool,
                IERC20(fromToken),
                IERC20(toToken),
                swapAmt,
                0,
                _user
            );
        } else {
            (inBalDelta, amountOut) = _swapExactOut(
                "_swapToBalance",
                _fxPool,
                IERC20(fromToken),
                IERC20(toToken),
                swapAmt,
                type(uint256).max,
                _user
            );
        }
        vm.stopPrank();
    }

    function _swapToMaxBetaEdge(
        address _fxPool,
        address _user,
        SwapKind _swapKind
    ) internal {
        PoolBoundaries memory b = IFXPool(_fxPool).getPoolBoundaries();

        address tokenIn = b.betaSwapAmtMaxToken;
        address tokenOut = b.betaSwapAmtMinToken;
        uint256 swapAmtNumeraire = b.betaSwapAmtMax;
        uint256 swapAmt = _swapKind == SwapKind.EXACT_IN
            ? IFXPool(_fxPool).convertNumeraireToRaw(tokenIn, swapAmtNumeraire)
            : IFXPool(_fxPool).convertNumeraireToRaw(
                tokenOut,
                swapAmtNumeraire
            );

        vm.startPrank(_user);
        if (_swapKind == SwapKind.EXACT_IN) {
            _swapExactIn(
                "_swapToMaxBetaEdge",
                _fxPool,
                IERC20(tokenIn),
                IERC20(tokenOut),
                swapAmt,
                0,
                _user
            );
        } else {
            _swapExactOut(
                "_swapToMaxBetaEdge",
                _fxPool,
                IERC20(tokenIn),
                IERC20(tokenOut),
                swapAmt,
                type(uint256).max,
                _user
            );
        }
        vm.stopPrank();
    }

    function _swapToMaxHalt(
        address _fxPool,
        address _user
    ) internal returns (uint256 inBalDelta, uint256 amountOut) {
        PoolBoundaries memory b = IFXPool(_fxPool).getPoolBoundaries();

        address tokenIn = b.haltSwapAmtMaxToken;
        address tokenOut = b.haltSwapAmtMinToken;
        uint256 swapAmtNumeraire = b.haltSwapAmtMax;
        uint256 swapAmt = IFXPool(_fxPool).convertNumeraireToRaw(
            tokenIn,
            swapAmtNumeraire
        );

        vm.startPrank(_user);
        (inBalDelta, amountOut) = _swapExactIn(
            "_swapToMaxHalt",
            _fxPool,
            IERC20(tokenIn),
            IERC20(tokenOut),
            swapAmt,
            0,
            _user
        );
        vm.stopPrank();
    }

    function _runSwapTestLoop(
        string memory _testName,
        int256[2][] memory _testData,
        address _tokenIn,
        address _tokenOut,
        SwapKind _swapKind,
        address user,
        address _fxPool
    ) internal {
        for (uint256 i; i < _testData.length; i++) {
            // console.log('swap loop #:', i);
            if (_testData[i][0] == 0) {
                // console2.log(string(abi.encodePacked(_testName, ' ', 'skipping index: ', i)));
                break;
            }

            if (_swapKind == SwapKind.EXACT_IN) {
                uint256 tokenOutTokenBal = IERC20(_tokenOut).balanceOf(user);
                (uint256 inBalDelta, uint256 amountOut) = _swapExactIn(
                    _testName,
                    _fxPool,
                    IERC20(_tokenIn),
                    IERC20(_tokenOut),
                    uint256(_testData[i][0]),
                    0, //max out
                    user
                );

                assertEq(
                    int256(inBalDelta),
                    int256(_testData[i][0]),
                    string(abi.encodePacked(_testName, " ", "deltas[0]"))
                );
                assertEq(
                    int256(amountOut),
                    int256(_testData[i][1]),
                    string(abi.encodePacked(_testName, " ", "deltas[1]"))
                );

                uint256 tokenOutBalDelta = IERC20(_tokenOut).balanceOf(user) -
                    tokenOutTokenBal;
                assertEq(amountOut, tokenOutBalDelta, "token out delta");
            } else {
                // currently not used
                uint256 tokenInTokenBal = IERC20(_tokenIn).balanceOf(user);
                (uint256 outBalDelta, uint256 amountIn) = _swapExactOut(
                    "",
                    _fxPool,
                    IERC20(_tokenIn),
                    IERC20(_tokenOut),
                    uint256(_testData[i][0]),
                    0, //max
                    user
                );

                assertEq(
                    int256(outBalDelta),
                    int256(_testData[i][0]),
                    string(abi.encodePacked(_testName, " ", "deltas[0]"))
                );
                assertEq(
                    int256(amountIn),
                    int256(_testData[i][1]),
                    string(abi.encodePacked(_testName, " ", "deltas[1]"))
                );

                uint256 tokenInBalDelta = tokenInTokenBal -
                    IERC20(_tokenIn).balanceOf(user);
                assertEq(outBalDelta, tokenInBalDelta);
            }
        }
    }

    function _fxDefaultGreeks() internal view returns (FXGreeks memory) {
        return
            FXGreeks({
                alpha: ALPHA,
                beta: BETA,
                max: MAX,
                epsilon: EPSILON,
                lambda: LAMBDA,
                kappa: KAPPA
            });
    }

    function _getScaledUserBalance(
        address _user,
        address _token
    ) internal view returns (uint256 scaledBalance) {
        uint256 balance = IERC20(_token).balanceOf(_user);
        uint256 sf = computeScalingFactor(IERC20(_token));
        return balance.toScaled18RoundUp(sf);
    }

    function _userTotalBalancesNumeraire(
        address _fxpool,
        address _user
    ) internal view returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 0; i < 2; ++i) {
            uint256 rawBalance = IERC20(IFXPool(_fxpool).tokens(i)).balanceOf(
                _user
            );
            total += IFXPool(_fxpool).convertRawToNumeraire(
                IFXPool(_fxpool).tokens(i),
                rawBalance
            );
        }
        return total;
    }

    /**
     * @dev Converts a token amount to its smallest unit based on the token's decimals.
     * @param _amount The amount of tokens in whole units. eg. 1000 (1000 tokens)
     * @param _token The address of the token contract.
     * @return The token amount in its smallest unit (e.g., wei for 18 decimal tokens).
     */
    function tokenAmount(
        uint256 _amount,
        address _token
    ) internal view returns (uint256) {
        return _amount * (10 ** IERC20Metadata(_token).decimals());
    }

    /**
     * @notice Convert the token `decimals` into a scaling factor.
     * @dev Called during registration, this reads the `decimals` from the token contract and construct
     * a conversion factor to be used when scaling up to full precision and back down to native decimals.
     *
     * As noted below, the Vault does not support tokens with more than 18 decimals, or tokens that do
     * not implement `IERC20Metadata`.
     */
    function computeScalingFactor(
        IERC20 token
    ) internal view returns (uint256) {
        // Tokens that don't implement the `decimals` method are not supported.
        uint256 tokenDecimals = IERC20Metadata(address(token)).decimals();

        // Tokens with more than 18 decimals are not supported.
        uint256 decimalsDifference = 18 - tokenDecimals;
        return 10 ** decimalsDifference;
    }

    /**
     * @dev Converts a token amount to a scaled 18 decimal representation.
     * This is useful for normalizing token amounts with different decimal places.
     * @param _amount The amount of tokens in whole units.
     * @param _token The address of the token contract.
     * @return The token amount scaled to 18 decimal places.
     */
    function tokenAmountScaled18(
        uint256 _amount,
        address _token
    ) internal view returns (uint256) {
        uint256 sf = computeScalingFactor(IERC20(_token));
        return _amount.toScaled18RoundUp(sf);
    }

    /**
     * @dev Asserts that the left value is less than or equal to the right value
     * but not lower than the right value minus the maxDelta.
     */
    function assertLeBounded(
        uint256 _left,
        uint256 _right,
        uint256 _maxDelta,
        string memory _msg
    ) internal pure {
        assertLe(_left, _right, _msg);
        assertApproxEqAbs(_left, _right, _maxDelta, _msg);
    }

    /**
     * @dev Asserts that the left value is less than or equal to the right value
     * but not lower than _max_err_pct of left value.
     */
    function assertLeBoundedPercent(
        uint256 _left,
        uint256 _right,
        uint256 _max_err_pct,
        string memory _msg
    ) internal pure {
        assertLe(_left, _right, _msg);
        uint256 pctDiff = calculatePercentage(_right - _left, _right);
        assertLe(pctDiff, _max_err_pct, _msg);
    }

    function assertApproxEqPctAbs(
        uint256 _left,
        uint256 _right,
        uint256 _max_err_pct,
        string memory _msg
    ) internal pure {
        if (_left == _right) {
            return;
        }

        uint256 delta = _left > _right ? _left - _right : _right - _left;

        uint256 pctDiff;
        if (_right != 0) {
            pctDiff = calculatePercentage(delta, _right);
        } else {
            pctDiff = calculatePercentage(delta, _left);
        }
        _msg = string(
            abi.encodePacked(
                _msg,
                " ",
                Strings.toString(_left),
                " != ",
                Strings.toString(_right),
                " pct diff(1e5): ",
                Strings.toString(pctDiff)
            )
        );
        assertLe(pctDiff, _max_err_pct, _msg);
    }

    function assertApproxEqPctAbsMax(
        uint256 _left,
        uint256 _right,
        string memory _msg
    ) internal pure {
        assertApproxEqPctAbs(_left, _right, MAX_ERROR_PCT5e, _msg);
    }

    /**
     * @dev Asserts that the left value is less than or equal to the right value
     * but not lower than MAX_ERROR_PCT5e of left value.
     */
    function assertLeBoundedPercentMax(
        uint256 _left,
        uint256 _right,
        string memory _msg
    ) internal pure {
        assertLeBoundedPercent(_left, _right, MAX_ERROR_PCT5e, _msg);
    }

    function errMarginForScaled18(
        uint256 _val
    ) internal pure returns (uint256) {
        uint256 multiplier = getMultiplier(_val);
        uint256 errorMargin = 1;
        if (multiplier >= 16) {
            errorMargin = 10 ** (multiplier - 16);
        }
        return errorMargin;
    }

    function getMultiplier(uint256 value) public pure returns (uint256) {
        if (value == 0) return 0;

        uint256 multiplier = 0;
        while (value >= 10) {
            value /= 10;
            multiplier++;
        }

        return multiplier;
    }

    // Calculate percentage with 5 decimal places precision
    // Returns the result as parts per 10,000,000 (7 decimal places)
    // E.g., 12.34567% would be returned as 1234567
    function calculatePercentage(
        uint256 numerator,
        uint256 denominator
    ) public pure returns (uint256) {
        require(denominator != 0, "Denominator cannot be zero");

        // Multiply by 10,000,000 to get 7 decimal places
        // This allows for 5 decimal places in the percentage (hundredths of thousands)
        uint256 percentage = (numerator * 10000000) / denominator;

        return percentage;
    }

    /**
     * @dev returns percentage of a number in bips.
     * eg. 1% = 100, 0.1% = 10, 0.01% = 1
     */
    function pctOf(
        uint256 _amount,
        uint256 _pct
    ) internal pure returns (uint256) {
        return (_amount * _pct) / 10_000;
    }

    /// @dev Generates a user, labels its address, and funds it with test assets.
    function _createUser(
        string memory name
    ) internal returns (address payable, uint256) {
        (address user, uint256 key) = makeAddrAndKey(name);
        vm.label(user, name);
        vm.deal(payable(user), defaultBalanceNoDecimals * 1e18);

        for (uint256 i = 0; i < tokens.length; ++i) {
            uint256 tokenDecimals = IERC20Metadata(address(tokens[i]))
                .decimals();
            deal(
                address(tokens[i]),
                user,
                defaultBalanceNoDecimals * (10 ** tokenDecimals)
            );
        }

        return (payable(user), key);
    }
}
