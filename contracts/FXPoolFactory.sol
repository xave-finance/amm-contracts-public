// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IVault} from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import {
    IRateProvider
} from "@balancer-labs/v3-interfaces/contracts/solidity-utils/helpers/IRateProvider.sol";
import {
    IPoolVersion
} from "@balancer-labs/v3-interfaces/contracts/solidity-utils/helpers/IPoolVersion.sol";
import "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import {
    BasePoolFactory
} from "@balancer-labs/v3-pool-utils/contracts/BasePoolFactory.sol";

import {
    Version
} from "@balancer-labs/v3-solidity-utils/contracts/helpers/Version.sol";

import {FXPool} from "./FXPool.sol";
import {IFXPool} from "./core/interfaces/IFXPool.sol";
import {IFXPoolFactory} from "./core/interfaces/IFXPoolFactory.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IOracle} from "./core/interfaces/IOracle.sol";
import {Errs, _require} from "./core/lib/FXPoolErrors.sol";
import {IERC20Detailed} from "./interfaces/IERC20Detailed.sol";
import {IAssimilator} from "./core/interfaces/IAssimilator.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFXPool} from "./core/interfaces/IFXPool.sol";
import {IFXPoolFactory} from "./core/interfaces/IFXPoolFactory.sol";
import {
    IRouter
} from "@balancer-labs/v3-interfaces/contracts/vault/IRouter.sol";
import {
    ArrayHelpers
} from "@balancer-labs/v3-solidity-utils/contracts/test/ArrayHelpers.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {
    FXAssets,
    FXGreeks,
    FXAssetType,
    FXPoolData,
    NewPoolParams
} from "./core/FXPoolTypes.sol";
import {
    PoolRoleAccounts
} from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {IVault} from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import {
    ReentrancyGuardTransient
} from "@balancer-labs/v3-solidity-utils/contracts/openzeppelin/ReentrancyGuardTransient.sol";
import {
    CastingHelpers
} from "@balancer-labs/v3-solidity-utils/contracts/helpers/CastingHelpers.sol";

contract FXPoolFactory is
    IPoolVersion,
    IFXPoolFactory,
    BasePoolFactory,
    Version,
    Ownable,
    ReentrancyGuardTransient
{
    using CastingHelpers for address[];
    using ArrayHelpers for *;

    /// @dev Event emitted after fx pool creation
    /// @param caller fxpool creator
    /// @param fxpool fxpool address
    event NewFXPool(address indexed caller, address indexed fxpool);

    /// @dev Events emitted after quote/base assimilator creation
    event NewQuoteAssimilator(
        address indexed caller,
        address indexed assimilatorAddress,
        FXAssetType indexed assimType,
        address quoteTemplate
    );
    event NewBaseAssimilator(
        address indexed caller,
        address indexed assimilatorAddress,
        FXAssetType indexed assimType,
        address baseTemplate
    );

    event AssimilatorTemplateSet(
        address indexed caller,
        address indexed assimilatorAddress,
        FXAssetType indexed assimType
    );

    /// @dev Event emitted after approving a  oracle
    event ApproveOracle(
        address indexed caller,
        address indexed oracleAddress,
        FXAssetType indexed assetType
    );
    /// @dev Event emitted after disapproving a  oracle
    event DisapproveOracle(
        address indexed caller,
        address indexed oracleAddress,
        FXAssetType indexed assetType
    );

    /// @dev Event emitted after setting new minimum protocol percent fee
    event SetMinProtocolPercentFee(
        address indexed caller,
        uint256 indexed minProtocolPercentFee
    );
    event FXPoolCollectorSet(
        address indexed caller,
        address indexed collectorAddress
    );
    event FXPoolOwnerSet(address indexed caller, address indexed ownerAddress);

    /// @dev when minting LP tokens, there is a rounding error of up by 1 wei
    uint256 public constant LP_MINTED_ROUNDING_ERR_THRESHOLD = 1 wei;

    /// @dev version of the factory
    string public constant VERSION = "1.0";

    uint256 public MIN_PERCENT_FEE;
    address public immutable permit2;
    address public immutable vault;

    uint256 private nonce;
    address public adminMultisig;
    address public fxPoolCollector;
    address public fxPoolOwner;

    /// keccak256(abi.encode(_quoteToken, _quoteOracle, quoteAssimilatorTemplate)) => quoteAssimilator
    mapping(bytes32 => address) public quoteAssimilators;

    /// assimilator templates
    address public quoteAssimilatorTemplate;
    address public baseAssimilatorTemplate;

    mapping(address => bool) public baseOraclesWhitelist;
    mapping(address => bool) public quoteOraclesWhitelist;
    /// fxPoolAddress => FXPoolData
    mapping(address => FXPoolData) public poolsData;

    event ChangedAdminMultisig(
        address indexed updater,
        address indexed newAdminMultisig
    );

    modifier onlyVault() {
        _require(msg.sender == vault, Errs.SENDER_NOT_VAULT);
        _;
    }

    constructor(
        IVault _vault,
        address _baseAssimilatorTemplate,
        address _quoteAssimilatorTemplate,
        address _permit2,
        uint32 pauseWindowDuration,
        string memory factoryVersion,
        address _adminMultisig
    )
        BasePoolFactory(_vault, pauseWindowDuration, type(FXPool).creationCode)
        Version(factoryVersion)
        Ownable(msg.sender)
    {
        // ensure that baseAssimilatorTemplate is not mistakenly passed as quoteAssimilatorTemplate and vice versa
        _require(
            address(
                IHasBaseAssimilator(_baseAssimilatorTemplate).baseToken()
            ) == address(0),
            Errs.BASE_ASSIM_MISMATCH
        );

        _require(_permit2 != address(0), Errs.NULL_ADDRESS);

        vault = address(_vault);
        adminMultisig = _adminMultisig;
        permit2 = _permit2;
        quoteAssimilatorTemplate = _quoteAssimilatorTemplate;
        baseAssimilatorTemplate = _baseAssimilatorTemplate;

        fxPoolOwner = owner();
        fxPoolCollector = owner();
    }

    function create(
        NewPoolParams memory _newFxPoolParams,
        address _baseOracle,
        address _quoteOracle
    ) external returns (address pool) {
        _require(
            _newFxPoolParams.assets.baseToken != address(0),
            Errs.NULL_ADDRESS
        );
        _require(_baseOracle != address(0), Errs.NULL_ADDRESS);
        _require(_quoteOracle != address(0), Errs.NULL_ADDRESS);
        _require(
            _newFxPoolParams.protocolPercentFee >= MIN_PERCENT_FEE,
            Errs.BELOW_MIN_PROTOCOL_FEE
        );

        address baseAssimilator = _processBaseAssimilator(
            _newFxPoolParams.assets.baseToken,
            _baseOracle,
            _newFxPoolParams.assets.quoteToken
        );

        // check if quote assimilator already exists, if not we create a new one
        address quoteAssimilator = _processQuoteAssimilator(
            _newFxPoolParams.assets.quoteToken,
            _quoteOracle
        );

        _newFxPoolParams.owner = fxPoolOwner;

        pool = _create(
            abi.encode(
                vault,
                NewPoolParams({
                    name: _newFxPoolParams.name,
                    symbol: _newFxPoolParams.symbol,
                    protocolPercentFee: _newFxPoolParams.protocolPercentFee,
                    owner: adminMultisig,
                    assets: _newFxPoolParams.assets,
                    greeks: _newFxPoolParams.greeks
                }),
                address(baseAssimilator),
                address(quoteAssimilator)
            ),
            _computeFinalSalt()
        );

        {
            PoolRoleAccounts memory roleAccounts;
            // setting to admin multisig so protocol can have control over the pools vs delegating it to the governance
            roleAccounts.pauseManager = adminMultisig;
            roleAccounts.swapFeeManager = adminMultisig;
            roleAccounts.poolCreator = adminMultisig;

            LiquidityManagement
                memory liquidityManagement = getDefaultLiquidityManagement();
            liquidityManagement.enableDonation = false;
            liquidityManagement.disableUnbalancedLiquidity = true;
            liquidityManagement.enableAddLiquidityCustom = true;
            liquidityManagement.enableRemoveLiquidityCustom = true;

            _registerPoolWithVault(
                pool,
                _fxAssetsToTokenConfig(_newFxPoolParams.assets),
                0, // swapFeePercentage
                false, // not exempt from protocol fees
                roleAccounts, // set above
                pool, // poolHooksContract
                liquidityManagement
            );
        }

        // emit the event before the liquidity supply to the pool
        // this is needed so that the order of events makes sense in the Balancer Subgraph
        emit NewFXPool(msg.sender, pool);

        FXPoolData memory newFxPoolData;
        newFxPoolData.poolAddress = pool;
        newFxPoolData.exists = true;
        newFxPoolData.baseAssimilatorTemplate = baseAssimilatorTemplate;
        poolsData[pool] = newFxPoolData;
    }

    /// @inheritdoc IPoolVersion
    function getPoolVersion() external pure returns (string memory) {
        return "3";
    }

    // We want to allow multiple pools to be created with the same
    // tokens and parameters;
    function _computeFinalSalt() internal returns (bytes32) {
        return keccak256(abi.encode(block.chainid, nonce++));
    }

    function _fxAssetsToTokenConfig(
        FXAssets memory assets
    ) private pure returns (TokenConfig[] memory) {
        // FXPools are restricted to exactly 2 tokens
        TokenConfig[] memory tokens = new TokenConfig[](2);
        tokens[0] = TokenConfig({
            token: IERC20(
                assets.quoteToken < assets.baseToken
                    ? assets.quoteToken
                    : assets.baseToken
            ),
            tokenType: TokenType.STANDARD,
            rateProvider: IRateProvider(address(0)),
            paysYieldFees: false
        });
        tokens[1] = TokenConfig({
            token: IERC20(
                assets.quoteToken > assets.baseToken
                    ? assets.quoteToken
                    : assets.baseToken
            ),
            tokenType: TokenType.STANDARD,
            rateProvider: IRateProvider(address(0)),
            paysYieldFees: false
        });

        return tokens;
    }

    function _initializeFxPool(
        address pool,
        IERC20[] memory tokens,
        uint256[] memory exactAmountsIn,
        uint256 minBptAmountOut,
        bool wethIsEth,
        bytes memory userData
    ) internal returns (uint256 bptAmountOut) {
        return
            abi.decode(
                IVault(vault).unlock(
                    abi.encodeWithSelector(
                        FXPoolFactory.initializeHook.selector,
                        IRouter.InitializeHookParams({
                            sender: msg.sender,
                            pool: pool,
                            tokens: tokens,
                            exactAmountsIn: exactAmountsIn,
                            minBptAmountOut: minBptAmountOut,
                            wethIsEth: wethIsEth,
                            userData: userData
                        })
                    )
                ),
                (uint256)
            );
    }

    function initializeHook(
        IRouter.InitializeHookParams calldata params
    ) external nonReentrant onlyVault returns (uint256 bptAmountOut) {
        bptAmountOut = IVault(vault).initialize(
            params.pool,
            params.sender,
            params.tokens,
            params.exactAmountsIn,
            params.minBptAmountOut,
            params.userData
        );

        for (uint256 i = 0; i < params.tokens.length; ++i) {
            IERC20 token = params.tokens[i];
            uint256 amountIn = params.exactAmountsIn[i];

            // transfer tokens from the user to the Vault'
            IPermit2(permit2).transferFrom(
                params.sender,
                vault,
                uint160(amountIn),
                address(token)
            );
            IVault(vault).settle(token, amountIn);
        }
    }

    /// @dev internal function to process base assimilator
    /// @notice if base assimilator already exists, it will return its address
    /// @param _baseToken base token address
    /// @param _baseOracle base oracle address
    /// @return baseAssimClone address of the base assimilator
    function _processBaseAssimilator(
        address _baseToken,
        address _baseOracle,
        address _quoteToken
    ) private returns (address) {
        // we first check if the baseOracle is whitelisted
        // even if we have created baseAssimilator(s) with a baseOracle that was subsequently removed from the whitelist,
        // we will not be able to create new baseAssimilators with that baseOracle once it is removed from the whitelist
        _require(
            baseOraclesWhitelist[_baseOracle] == true,
            Errs.ORACLE_NOT_WHITELISTED
        );
        // we're not caching baseAssimilators because the likelyhood of cache efficiency is low
        // create / clone new BaseAssimilator
        address baseAssimClone = Clones.clone(baseAssimilatorTemplate);

        IAssimilator(baseAssimClone).initialize(
            IERC20(_baseToken),
            IERC20(_quoteToken),
            IOracle(_baseOracle)
        );

        emit NewBaseAssimilator(
            msg.sender,
            baseAssimClone,
            FXAssetType.Base,
            baseAssimilatorTemplate
        );

        return baseAssimClone;
    }

    function _processQuoteAssimilator(
        address _quoteToken,
        address _quoteOracle
    ) private returns (address) {
        _require(
            quoteOraclesWhitelist[_quoteOracle] == true,
            Errs.ORACLE_NOT_WHITELISTED
        );

        bytes32 h = keccak256(
            abi.encode(_quoteToken, _quoteOracle, quoteAssimilatorTemplate)
        );
        if (quoteAssimilators[h] != address(0)) {
            // reuse this quoteAssimilator
            return quoteAssimilators[h];
        }

        // create / clone new BaseAssimilator
        address quoteAssimClone = Clones.clone(quoteAssimilatorTemplate);

        IAssimilator(quoteAssimClone).initialize(
            IERC20(address(0)),
            IERC20(_quoteToken),
            IOracle(_quoteOracle)
        );

        // add to quoteAssimilators mapping mapping
        quoteAssimilators[h] = quoteAssimClone;

        emit NewQuoteAssimilator(
            msg.sender,
            quoteAssimClone,
            FXAssetType.Quote,
            quoteAssimilatorTemplate
        );

        return quoteAssimClone;
    }

    function setAdminMultisig(address _adminMultisig) public onlyOwner {
        adminMultisig = _adminMultisig;
        emit ChangedAdminMultisig(msg.sender, _adminMultisig);
    }

    /// @dev adds a new base oracle to the whitelist
    function adminApproveBaseOracle(address _baseOracle) external onlyOwner {
        baseOraclesWhitelist[_baseOracle] = true;
        emit ApproveOracle(msg.sender, _baseOracle, FXAssetType.Base);
    }

    /// @dev remove a base oracle from the whitelist
    function adminDisapproveBaseOracle(address _baseOracle) external onlyOwner {
        baseOraclesWhitelist[_baseOracle] = false;
        emit DisapproveOracle(msg.sender, _baseOracle, FXAssetType.Base);
    }

    /// @dev adds a new base oracle to the whitelist
    function adminApproveQuoteOracle(address _quoteOracle) external onlyOwner {
        quoteOraclesWhitelist[_quoteOracle] = true;
        emit ApproveOracle(msg.sender, _quoteOracle, FXAssetType.Quote);
    }

    /// @dev remove a base oracle from the whitelist
    function adminDisapproveQuoteOracle(
        address _quoteOracle
    ) external onlyOwner {
        quoteOraclesWhitelist[_quoteOracle] = false;
        emit DisapproveOracle(msg.sender, _quoteOracle, FXAssetType.Quote);
    }

    /// @dev sets minimum protocol perecent fee
    function adminSetMinProtocolPercentFee(
        uint256 _minPercentProtocolFee
    ) external onlyOwner {
        MIN_PERCENT_FEE = _minPercentProtocolFee;

        emit SetMinProtocolPercentFee(msg.sender, _minPercentProtocolFee);
    }

    function adminSetQuoteAssimilatorTemplate(
        address _quoteAssim
    ) external onlyOwner {
        _require(_quoteAssim != address(0), Errs.NULL_ADDRESS);

        quoteAssimilatorTemplate = _quoteAssim;
        emit AssimilatorTemplateSet(msg.sender, _quoteAssim, FXAssetType.Quote);
    }

    function adminSetBaseAssimilatorTemplate(
        address _baseAssim
    ) external onlyOwner {
        _require(_baseAssim != address(0), Errs.NULL_ADDRESS);

        baseAssimilatorTemplate = _baseAssim;
        emit AssimilatorTemplateSet(msg.sender, _baseAssim, FXAssetType.Base);
    }

    function adminSetFxpoolCollector(address _a) external onlyOwner {
        _require(_a != address(0), Errs.NULL_ADDRESS);
        fxPoolCollector = _a;
        emit FXPoolCollectorSet(msg.sender, _a);
    }

    function adminSetFxpoolOwner(address _a) external onlyOwner {
        _require(_a != address(0), Errs.NULL_ADDRESS);
        fxPoolOwner = _a;
        emit FXPoolOwnerSet(msg.sender, _a);
    }

    /// @dev helper function to receive details about a pool created by this contract
    /// @param _fxpoolAddr address of the FXPool
    function getFXPoolDetails(
        address _fxpoolAddr
    )
        external
        view
        returns (
            string memory name,
            address baseToken_,
            address baseOracle_,
            uint256 protocolPercentFee_,
            uint256 liquidity,
            uint256 alpha,
            uint256 beta,
            uint256 delta,
            uint256 epsilon,
            uint256 lambda,
            uint256 kappa
        )
    {
        FXPoolData memory fxpData = poolsData[_fxpoolAddr];
        _require(fxpData.exists, Errs.POOL_DOES_NOT_EXIST);

        // in current versions of the FXPool, the baseToken is the first derivative
        // this might change in the future and the code below cater for this possiblity

        baseToken_ = IFXPool(_fxpoolAddr).baseToken();
        address baseAssim = IFXPool(_fxpoolAddr).assimilator(baseToken_);

        name = IERC20Detailed(_fxpoolAddr).name();
        baseOracle_ = IHasOracle(baseAssim).oracle();
        protocolPercentFee_ = IFXPool(_fxpoolAddr).protocolPercentFee();
        (uint256 totalLiquidity, ) = IFXPool(_fxpoolAddr).liquidity();
        liquidity = totalLiquidity;
        (alpha, beta, delta, epsilon, lambda, kappa) = IFXPool(_fxpoolAddr)
            .viewParameters();
    }
}

interface IHasOracle {
    function oracle() external view returns (address);
}

interface IHasBaseAssimilator {
    function baseToken() external view returns (address);
}
