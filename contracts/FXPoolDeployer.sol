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
pragma experimental ABIEncoderV2;

pragma solidity 0.7.6;

import {IOracle} from './core/interfaces/IOracle.sol';
import {Errs, _require} from './core/lib/FXPoolErrors.sol';
import {FXPoolDeployerLib} from './core/lib/FXPoolDeployerLib.sol';
import {IERC20Detailed} from './interfaces/IERC20Detailed.sol';

import {IVault} from '@balancer-labs/v2-vault/contracts/interfaces/IVault.sol';
import {IBaseToUsdAssimilatorInitializable} from './core/interfaces/IBaseToUsdAssimilatorInitializable.sol';
import {OwnableUpgradeable} from '@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol';
import '@openzeppelin/contracts-upgradeable/proxy/Initializable.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IAsset} from '@balancer-labs/v2-vault/contracts/interfaces/IAsset.sol';
import '@openzeppelin/contracts-upgradeable/proxy/ClonesUpgradeable.sol';

struct FXPoolData {
    bytes32 poolId;
    address poolAddress;
    address baseAssimilatorTemplate;
    bool exists;
}

/**
 * @title FXPoolDeployer
 * @notice Deploys and keeps track of new FXPool contracts.
 *
 * FXPools use two assimilators: one for the base token and one for the quote token.
 * This contract supports upgrading the template logic for the base assimilator and quote assimilator.
 */
contract FXPoolDeployer is Initializable, OwnableUpgradeable {
    /// @dev Event emitted after fx pool creation
    /// @param caller fxpool creator
    /// @param id fxpool id for the factory (different from poolId in balancer)
    /// @param fxpool fxpool address
    event NewFXPool(address indexed caller, bytes32 indexed id, address indexed fxpool);

    /// @dev Event emitted after base assimilator creation
    event NewBaseAssimilator(address indexed caller, address indexed assimilatorAddress);
    event QuoteAssimilatorSet(address indexed caller, address indexed assimilatorAddress);
    event BaseAssimilatorTemplateSet(address indexed caller, address indexed assimilatorAddress);

    /// @dev Event emitted after approving a base oracle
    event ApproveBaseOracle(address indexed caller, address indexed oracleAddress);
    /// @dev Event emitted after disapproving a base oracle
    event DisapproveBaseOracle(address indexed caller, address indexed oracleAddress);

    /// @dev Event emitted after setting new minimum protocol percent fee
    event SetMinProtocolPercentFee(address indexed caller, uint256 indexed minProtocolPercentFee);
    event FXPoolCollectorSet(address indexed caller, address indexed collectorAddress);
    event FXPoolOwnerSet(address indexed caller, address indexed ownerAddress);

    /// @dev when minting LP tokens, there is a rounding error of up by 1 wei
    uint256 public constant LP_MINTED_ROUNDING_ERR_THRESHOLD = 1 wei;

    string public constant VERSION = '0.3';

    /// @dev cannot have default values on non-constant variables. these need to be
    /// set in the `initialize` function see
    /// https://docs.openzeppelin.com/upgrades-plugins/1.x/writing-upgradeable#avoid-initial-values-in-field-declarations
    uint256 public MIN_PERCENT_FEE;
    uint256 public BASE_WEIGHT; // in 1e18
    uint256 public QUOTE_WEIGHT; // in 1e18

    /// Balancer Vault address
    address public vault;
    /// Quote Token address
    address public quoteToken; /// USDC normally

    /// Quote Assimilator address; Can be updated by owner of this contract
    address public quoteAssimilator; /// USDC normally
    /// address of the baseAssimilatorTemplate logic that will be cloned
    /// whenever a new baseAssimilator is needed
    address public baseAssimilatorTemplate;

    address public fxpoolCollector;
    address public fxpoolOwner;

    /// keccak256(abi.encode(_baseToken, _baseOracle, baseAssimilatorTemplate)) => baseAssimilator
    mapping(bytes32 => address) public baseAssimilators;

    /// mapping of whitelisted baseToken oracles
    mapping(address => bool) public baseOraclesWhitelist;

    /// fxPoolAddress => FXPoolData
    mapping(address => FXPoolData) public poolsData;

    function initialize(
        address _vault,
        address _quoteToken,
        address _quoteAssimilator,
        address _baseAssimilatorTemplate
    ) public initializer {
        // @dev see https://docs.openzeppelin.com/contracts/5.x/upgradeable
        __Context_init_unchained();
        __Ownable_init_unchained();

        vault = _vault;
        quoteToken = _quoteToken;
        quoteAssimilator = _quoteAssimilator;
        baseAssimilatorTemplate = _baseAssimilatorTemplate;

        fxpoolOwner = owner();
        fxpoolCollector = owner();
        MIN_PERCENT_FEE = 50;
        BASE_WEIGHT = 5 * 1e17; // 0.5 * 1e18
        QUOTE_WEIGHT = 5 * 1e17; // 0.5 * 1e18
    }

    /// @dev Deploy a new FXPool. The quoteToken and quoteAssimilator are already known as part of this FXPoolDeployer.
    /// @param _baseToken base token address
    /// @param _baseOracle base oracle address; needs to have been whitelisted already by admin
    /// @param _initialDepositInNumeraire initial deposit in numeraire
    /// @param _params abi.encode(protocolPercentFee, ALPHA, BETA, FEE_AT_HALT, EPSILON, LAMBDA, nameSuffix)
    function newFXPool(
        address _baseToken,
        address _baseOracle,
        uint256 _initialDepositInNumeraire,
        bytes calldata _params
    ) public returns (bytes32 balancerPoolId, address fxpoolAddr) {
        _require(_baseToken != address(0), Errs.NULL_ADDRESS);
        _require(_baseOracle != address(0), Errs.NULL_ADDRESS);

        address baseAssimilator = _processBaseAssimilator(_baseToken, _baseOracle);

        (balancerPoolId, fxpoolAddr) = _createPool(_baseToken, baseAssimilator, _initialDepositInNumeraire, _params);

        FXPoolData memory newFxPoolData;
        newFxPoolData.poolAddress = fxpoolAddr;
        newFxPoolData.poolId = balancerPoolId;
        newFxPoolData.exists = true;
        newFxPoolData.baseAssimilatorTemplate = baseAssimilatorTemplate;

        poolsData[fxpoolAddr] = newFxPoolData;

        return (balancerPoolId, fxpoolAddr);
    }

    function _createPool(
        address _baseToken,
        address _baseAssimilator,
        uint256 _initialDepositInNumeraire,
        bytes calldata _params
    ) private returns (bytes32, address) {
        // decode only the needed variables from the _params
        (uint256 protocolPercentFee, , , , , , string memory nameSuffix) = abi.decode(
            _params,
            (uint256, uint256, uint256, uint256, uint256, uint256, string)
        );

        _require(protocolPercentFee >= MIN_PERCENT_FEE, Errs.BELOW_MIN_PROTOCOL_FEE);
        address[] memory sortedTokens = _sortAssetsList(_baseToken, quoteToken);

        string memory symbol = string(
            abi.encodePacked('LP-', IERC20Detailed(_baseToken).symbol(), '-', IERC20Detailed(quoteToken).symbol())
        );
        string memory name = string(abi.encodePacked(symbol, nameSuffix));

        address fxpool = FXPoolDeployerLib.createFXPool(sortedTokens, IVault(vault), protocolPercentFee, name, symbol);
        bytes32 fxpoolId = IFXPool(fxpool).getPoolId();
        _initializePool(fxpool, _baseToken, _baseAssimilator);
        _setParams(fxpool, _params);

        IFXPool(fxpool).setCollectorAddress(fxpoolCollector);
        // transfer the ownership to the same owner as the FXPoolDeployer
        IFXPool(fxpool).transferOwnership(fxpoolOwner);

        // emit the event before the liquidity supply to the pool
        // this is needed so that the order of events makes sense in the Balancer Subgraph
        emit NewFXPool(msg.sender, fxpoolId, fxpool);

        if (_initialDepositInNumeraire > 0) {
            _addLiquidity(fxpool, _initialDepositInNumeraire, sortedTokens);
        }

        return (fxpoolId, address(fxpool));
    }

    function _addLiquidity(address fxpool, uint256 depositNumeraire, address[] memory sortedTokens) private {
        // the viewDeposit will return values based on the Chainlink oracles
        (, uint256[] memory deposits) = IFXPool(fxpool).viewDeposit(depositNumeraire);

        // the tokens in the sortedTokens array are ordered based on the Vault logic
        // so we need to check if the order in the FXPool is the same
        (uint256 deposit0, uint256 deposit1) = sortedTokens[0] == IFXPool(fxpool).derivatives(0)
            ? (deposits[0], deposits[1])
            : (deposits[1], deposits[0]);

        IERC20(sortedTokens[0]).transferFrom(msg.sender, address(this), deposit0);
        IERC20(sortedTokens[1]).transferFrom(msg.sender, address(this), deposit1);

        // approve the vault to transferFrom the tokens
        IERC20(sortedTokens[0]).approve(vault, deposit0);
        IERC20(sortedTokens[1]).approve(vault, deposit1);

        bytes32 balancerPoolId = IFXPool(fxpool).getPoolId();

        uint256[] memory maxAmountsIn = new uint256[](2);
        maxAmountsIn[0] = deposit0;
        maxAmountsIn[1] = deposit1;

        bytes memory userData = abi.encode(depositNumeraire, sortedTokens);

        IVault.JoinPoolRequest memory req = IVault.JoinPoolRequest({
            assets: _asIAsset(sortedTokens),
            maxAmountsIn: maxAmountsIn,
            userData: userData,
            fromInternalBalance: false
        });

        IVault(vault).joinPool(balancerPoolId, address(this), address(this), req);

        uint256 lpBal = IERC20(fxpool).balanceOf(address(this));
        _require(lpBal >= depositNumeraire - LP_MINTED_ROUNDING_ERR_THRESHOLD, Errs.LP_BALANCE_VIOLATION);
        // transfer LP tokens to the user
        IERC20(fxpool).transfer(msg.sender, lpBal);
    }

    function _initializePool(address _fxPool, address _baseToken, address _baseAssimilator) private {
        address[] memory assets = new address[](10);

        assets[0] = address(_baseToken);
        assets[1] = address(_baseAssimilator);
        assets[2] = address(_baseToken);
        assets[3] = address(_baseAssimilator);
        assets[4] = address(_baseToken);
        assets[5] = quoteToken;
        assets[6] = address(quoteAssimilator);
        assets[7] = quoteToken;
        assets[8] = address(quoteAssimilator);
        assets[9] = quoteToken;

        uint256[] memory weights = new uint256[](2);
        weights[0] = BASE_WEIGHT;
        weights[1] = QUOTE_WEIGHT;
        IFXPool(_fxPool).initialize(assets, weights);
    }

    /// @dev internal function to process base assimilator
    /// @notice if base assimilator already exists, it will return its address
    /// @param _baseToken base token address
    /// @param _baseOracle base oracle address
    /// @return baseAssimClone address of the base assimilator
    function _processBaseAssimilator(address _baseToken, address _baseOracle) private returns (address) {
        // we first check if the baseOracle is whitelisted
        // even if we have created baseAssimilator(s) with a baseOracle that was subsequently removed from the whitelist,
        // we will not be able to create new baseAssimilators with that baseOracle once it is removed from the whitelist
        _require(baseOraclesWhitelist[_baseOracle] == true, Errs.ORACLE_NOT_WHITELISTED);

        // do we already have a baseAssimilator that is configured with this baseToken, baseOracle and from
        // the current baseAssimilatorTemplate?
        // include baseAssimilatorTemplate in the hash to ensure we can upgrade the baseAssimilator logic if needed
        bytes32 h = keccak256(abi.encode(_baseToken, _baseOracle, baseAssimilatorTemplate));
        if (baseAssimilators[h] != address(0)) {
            // reuse this baseAssimilator
            return baseAssimilators[h];
        }

        // create / clone new BaseToUsdAssimilator
        address baseAssimClone = ClonesUpgradeable.clone(baseAssimilatorTemplate);
        IBaseToUsdAssimilatorInitializable(baseAssimClone).initialize(
            10 ** IERC20Detailed(_baseToken).decimals(),
            IERC20(_baseToken),
            IERC20(quoteToken),
            IOracle(_baseOracle)
        );

        // add to baseAssimilators mapping
        baseAssimilators[h] = baseAssimClone;
        emit NewBaseAssimilator(msg.sender, baseAssimClone);

        return baseAssimClone;
    }

    /// @dev view function to get the expected LP tokens to receive and the
    /// base and quote token amounts to deposit
    /// @param _initialDepositInNumeraire initial deposit in numeraire
    /// @param _baseToken base token address
    /// @param _baseOracle base oracle address
    function viewDepositNoLiquidity(
        uint256 _initialDepositInNumeraire,
        address _baseToken,
        address _baseOracle
    )
        public
        view
        returns (
            uint256 expectedShares, // minimum expected LP shares to receive
            uint256 baseTokenAmount, // base token amount to deposit
            uint256 quoteTokenAmount // quote token amount to deposit
        )
    {
        return
            FXPoolDeployerLib.viewDepositNoLiquidity(
                _initialDepositInNumeraire,
                _baseToken,
                _baseOracle,
                quoteToken,
                quoteAssimilator,
                BASE_WEIGHT,
                QUOTE_WEIGHT
            );
    }

    function _sortAssets(address _t0, address _t1) private pure returns (address, address) {
        return _t0 < _t1 ? (_t0, _t1) : (_t1, _t0);
    }

    function _sortAssetsList(address _t0, address _t1) private pure returns (address[] memory) {
        (address t0, address t1) = _sortAssets(_t0, _t1);
        address[] memory sortedTokens = new address[](2);
        sortedTokens[0] = t0;
        sortedTokens[1] = t1;

        return sortedTokens;
    }

    // ERC20 helper functions copied from balancer-core-v2 ERC20Helpers.sol
    function _asIAsset(address[] memory addresses) internal pure returns (IAsset[] memory assets) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            assets := addresses
        }
    }

    function _setParams(address _fxPool, bytes calldata _params) private {
        // only decode the required params
        (, uint256 alpha, uint256 beta, uint256 max, uint256 epsilon, uint256 lambda, ) = abi.decode(
            _params,
            (uint256, uint256, uint256, uint256, uint256, uint256, string)
        );
        IFXPool(_fxPool).setParams(alpha, beta, max, epsilon, lambda);
    }

    /// @dev adds a new base oracle to the whitelist
    function adminApproveBaseOracle(address _baseOracle) external onlyOwner {
        baseOraclesWhitelist[_baseOracle] = true;
        emit ApproveBaseOracle(msg.sender, _baseOracle);
    }

    /// @dev remove a base oracle from the whitelist
    function adminDisapproveBaseOracle(address _baseOracle) external onlyOwner {
        baseOraclesWhitelist[_baseOracle] = false;
        emit DisapproveBaseOracle(msg.sender, _baseOracle);
    }

    /// @dev sets minimum protocol perecent fee
    function adminSetMinProtocolPercentFee(uint256 _minPercentProtocolFee) external onlyOwner {
        MIN_PERCENT_FEE = _minPercentProtocolFee;

        emit SetMinProtocolPercentFee(msg.sender, _minPercentProtocolFee);
    }

    /**
     * @dev sets new quote assimilator template
     */
    function adminSetQuoteAssimilator(address _quoteAssim) external onlyOwner {
        _require(_quoteAssim != address(0), Errs.NULL_ADDRESS);

        quoteAssimilator = _quoteAssim;
        emit QuoteAssimilatorSet(msg.sender, _quoteAssim);
    }

    /**
     * @dev sets new base assimilator template
     */
    function adminSetbaseAssimilatorTemplate(address _baseAssim) external onlyOwner {
        _require(_baseAssim != address(0), Errs.NULL_ADDRESS);

        baseAssimilatorTemplate = _baseAssim;
        emit BaseAssimilatorTemplateSet(msg.sender, _baseAssim);
    }

    function adminSetFxpoolCollector(address _a) external onlyOwner {
        _require(_a != address(0), Errs.NULL_ADDRESS);
        fxpoolCollector = _a;
        emit FXPoolCollectorSet(msg.sender, _a);
    }

    function adminSetFxpoolOwner(address _a) external onlyOwner {
        _require(_a != address(0), Errs.NULL_ADDRESS);
        fxpoolOwner = _a;
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
            address baseToken,
            address baseOracle,
            uint256 protocolPercentFee,
            uint256 liquidity,
            uint256 alpha,
            uint256 beta,
            uint256 delta,
            uint256 epsilon,
            uint256 lambda
        )
    {
        FXPoolData memory fxpData = poolsData[_fxpoolAddr];
        _require(fxpData.exists, Errs.POOL_DOES_NOT_EXIST);

        // in current versions of the FXPool, the baseToken is the first derivative
        // this might change in the future and the code below cater for this possiblity
        address fxpT0 = IFXPool(_fxpoolAddr).derivatives(0);
        baseToken = fxpT0 != quoteToken ? fxpT0 : IFXPool(_fxpoolAddr).derivatives(1);
        address baseAssim = IFXPool(_fxpoolAddr).assimilator(baseToken);

        name = IERC20Detailed(_fxpoolAddr).name();
        baseOracle = IHasOracle(baseAssim).oracle();
        protocolPercentFee = IFXPool(_fxpoolAddr).protocolPercentFee();
        liquidity = IFXPool(_fxpoolAddr).liquidity();
        (alpha, beta, delta, epsilon, lambda) = IFXPool(_fxpoolAddr).viewParameters();
    }
}

interface IHasOracle {
    function oracle() external view returns (address);
}

interface IFXPool {
    function initialize(address[] memory assets, uint256[] memory weights) external;

    function assimilator(address _derivative) external view returns (address);

    function derivatives(uint256) external view returns (address);

    function protocolPercentFee() external view returns (uint256);

    function liquidity() external view returns (uint256);

    function viewParameters() external view returns (uint256, uint256, uint256, uint256, uint256);

    function setParams(uint256 _alpha, uint256 _beta, uint256 _max, uint256 _epsilon, uint256 _lambda) external;

    function viewDeposit(uint256 _depositNumeraire) external view returns (uint256, uint256[] memory);

    function getPoolId() external view returns (bytes32);

    function setCollectorAddress(address _collector) external;

    function transferOwnership(address _owner) external;
}
