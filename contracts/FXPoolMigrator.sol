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

import {IAssimilator} from './core/interfaces/IAssimilator.sol';
import {Errs, _require} from './core/lib/FXPoolErrors.sol';
import {IVault} from '@balancer-labs/v2-vault/contracts/interfaces/IVault.sol';
import '@openzeppelin/contracts-upgradeable/proxy/Initializable.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IAsset} from '@balancer-labs/v2-vault/contracts/interfaces/IAsset.sol';
import './core/lib/ABDKMath64x64.sol';
import './core/lib/OZSafeMath.sol';

struct PoolMigrationInfo {
    address oldFxPoolAddress;
    address newFxPoolAddress;
    address oldBaseToken;
    address oldQuoteToken;
    address newBaseToken;
    address newQuoteToken;
}

/**
 * @title FXPoolMigrator
 * @notice Migrates liquidity from one FXPool to another
 */
contract FXPoolMigrator is Initializable {
    using ABDKMath64x64 for int128;
    using OZSafeMath for uint256;

    string public constant VERSION = '0.1';

    /// @dev Event emitted after migration
    /// @param caller user who migrated liquidity
    /// @param oldfxpool fxpool the user migrated from
    /// @param newfxpool fxpool the user migrated to
    event LPMigrated(address indexed caller, address indexed oldfxpool, address indexed newfxpool);

    uint256 public constant BASIS_DIV = 10_000;
    // in basis points
    uint256 public constant LP_SLIPPAGE_THRESHOLOD_BASIS_POINTS = 9900; // 99%

    /// @dev cannot have default values on non-constant variables. these need to be
    /// set in the `initialize` function see
    /// https://docs.openzeppelin.com/upgrades-plugins/1.x/writing-upgradeable#avoid-initial-values-in-field-declarations

    /// Balancer Vault address
    address public vault;

    function initialize(address _vault) public initializer {
        vault = _vault;
    }

    function _buildPoolMigrationInfo(
        bytes32 oldFXPoolId,
        bytes32 newFXPoolId
    ) internal view returns (PoolMigrationInfo memory) {
        (address oldFxPoolAddress, ) = IVault(vault).getPool(oldFXPoolId);
        (address newFxPoolAddress, ) = IVault(vault).getPool(newFXPoolId);
        address oldBaseToken = IFXPool(oldFxPoolAddress).derivatives(0);
        address oldQuoteToken = IFXPool(oldFxPoolAddress).derivatives(1);
        address newBaseToken = IFXPool(newFxPoolAddress).derivatives(0);
        address newQuoteToken = IFXPool(newFxPoolAddress).derivatives(1);

        _require(oldBaseToken == newBaseToken, Errs.BASE_TOKEN_MISMATCH);
        _require(oldQuoteToken == newQuoteToken, Errs.QUOTE_TOKEN_MISMATCH);

        return
            PoolMigrationInfo({
                oldFxPoolAddress: oldFxPoolAddress,
                newFxPoolAddress: newFxPoolAddress,
                oldBaseToken: oldBaseToken,
                oldQuoteToken: oldQuoteToken,
                newBaseToken: newBaseToken,
                newQuoteToken: newQuoteToken
            });
    }

    function migrateToFxPool(
        bytes32 oldFXPoolId,
        bytes32 newFXPoolId,
        uint256 expectedNewLp,
        uint256 expectedBaseDelta,
        uint256 expectedQuoteDelta
    ) public {
        PoolMigrationInfo memory pmi = _buildPoolMigrationInfo(oldFXPoolId, newFXPoolId);

        uint256 userOldFXPoolLPBalance = IFXPool(pmi.oldFxPoolAddress).balanceOf(msg.sender);
        _require(userOldFXPoolLPBalance > 0, Errs.LP_USER_BALANCE_VIOLATION);

        IERC20(pmi.oldFxPoolAddress).transferFrom(msg.sender, address(this), userOldFXPoolLPBalance);

        uint256[] memory oldFXPoolExitBalances = IFXPool(pmi.oldFxPoolAddress).viewWithdraw(userOldFXPoolLPBalance);

        uint256 depositNumeraire = _convertToDepositNumeraire(
            IFXPool(pmi.oldFxPoolAddress).assimilator(pmi.oldBaseToken),
            IFXPool(pmi.oldFxPoolAddress).assimilator(pmi.oldQuoteToken),
            oldFXPoolExitBalances[0],
            oldFXPoolExitBalances[1]
        ).mul(LP_SLIPPAGE_THRESHOLOD_BASIS_POINTS).div(BASIS_DIV);

        // withdraw fx pool assets
        address[] memory sortedExit = _sortAssetsList(pmi.oldBaseToken, pmi.oldQuoteToken);

        _removeLiquidity(oldFXPoolId, userOldFXPoolLPBalance, sortedExit);

        // deposit new balance to new pool
        address[] memory sortedDeposit = _sortAssetsList(pmi.newBaseToken, pmi.newQuoteToken);

        (uint256 lpTokens, uint256[] memory bals) = IFXPool(pmi.newFxPoolAddress).viewDeposit(depositNumeraire);

        _addLiquidity(pmi.newFxPoolAddress, depositNumeraire, sortedDeposit);

        uint256 lpBal = IERC20(pmi.newFxPoolAddress).balanceOf(address(this));
        _require(lpBal >= expectedNewLp, Errs.LP_BALANCE_VIOLATION);

        uint256 quoteBal = IERC20(pmi.newQuoteToken).balanceOf(address(this));
        uint256 baseBal = IERC20(pmi.newBaseToken).balanceOf(address(this));

        _require(quoteBal >= expectedQuoteDelta, Errs.TOKEN_BALANCE_VIOLATION);
        _require(baseBal >= expectedBaseDelta, Errs.TOKEN_BALANCE_VIOLATION);

        IERC20(pmi.newQuoteToken).transfer(msg.sender, quoteBal);
        IERC20(pmi.newBaseToken).transfer(msg.sender, baseBal);
        IERC20(pmi.newFxPoolAddress).transfer(msg.sender, lpBal);

        // emit event upon migration
        emit LPMigrated(msg.sender, pmi.oldFxPoolAddress, pmi.newFxPoolAddress);
    }

    function migrateToFxPoolView(
        uint256 userOldFXPoolLPBalance,
        bytes32 oldFXPoolId,
        bytes32 newFXPoolId
    ) public view returns (uint256 lpTokens, uint256 baseTokenDelta, uint256 quoteTokenDelta) {
        PoolMigrationInfo memory pmi = _buildPoolMigrationInfo(oldFXPoolId, newFXPoolId);

        uint256[] memory oldFXPoolExitBalances = IFXPool(pmi.oldFxPoolAddress).viewWithdraw(userOldFXPoolLPBalance);

        uint256 depositNumeraire = _convertToDepositNumeraire(
            IFXPool(pmi.oldFxPoolAddress).assimilator(pmi.oldBaseToken),
            IFXPool(pmi.oldFxPoolAddress).assimilator(pmi.oldQuoteToken),
            oldFXPoolExitBalances[0],
            oldFXPoolExitBalances[1]
        ).mul(LP_SLIPPAGE_THRESHOLOD_BASIS_POINTS).div(BASIS_DIV);

        uint256[] memory bals;
        (lpTokens, bals) = IFXPool(pmi.newFxPoolAddress).viewDeposit(depositNumeraire);

        baseTokenDelta = oldFXPoolExitBalances[0].sub(bals[0]);
        quoteTokenDelta = oldFXPoolExitBalances[1].sub(bals[1]);
    }

    function _addLiquidity(address fxpool, uint256 depositNumeraire, address[] memory sortedTokens) private {
        // the viewDeposit will return values based on the Chainlink oracles
        (, uint256[] memory deposits) = IFXPool(fxpool).viewDeposit(depositNumeraire);

        // the tokens in the sortedTokens array are ordered based on the Vault logic
        // so we need to check if the order in the FXPool is the same
        (uint256 deposit0, uint256 deposit1) = sortedTokens[0] == IFXPool(fxpool).derivatives(0)
            ? (deposits[0], deposits[1])
            : (deposits[1], deposits[0]);

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
    }

    function _removeLiquidity(bytes32 fxPoolId, uint256 tokensToBurn, address[] memory sortedTokens) private {
        bytes memory userData = abi.encode(tokensToBurn, sortedTokens);

        IVault.ExitPoolRequest memory reqExit = IVault.ExitPoolRequest({
            assets: _asIAsset(sortedTokens),
            minAmountsOut: _uint256ArrVal(2, 0),
            userData: userData,
            toInternalBalance: false
        });

        IVault(vault).exitPool(fxPoolId, address(this), payable(address(this)), reqExit);
    }

    function _convertToDepositNumeraire(
        address baseAssimilator,
        address quoteAssimilator,
        uint256 baseAmount,
        uint256 quoteAmount
    ) internal view returns (uint256 depositNumeraire_) {
        // calculate numeraire value of base token
        int128 baseNumeraireValue = IAssimilator(baseAssimilator).viewNumeraireAmount(baseAmount);
        // calculate numeraire value of usdc
        int128 usdcNumeraireValue = IAssimilator(quoteAssimilator).viewNumeraireAmount(quoteAmount);
        // find the smallest numeraire value and use that as half
        // of the total deposit numeraire for the new pool
        if (usdcNumeraireValue < baseNumeraireValue) {
            depositNumeraire_ = usdcNumeraireValue.mulu(2e18);
        } else {
            depositNumeraire_ = baseNumeraireValue.mulu(2e18);
        }
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

    function _uint256ArrVal(uint256 arrSize, uint256 _val) internal pure returns (uint256[] memory) {
        uint256[] memory arr = new uint256[](arrSize);
        for (uint256 i = 0; i < arrSize; i++) {
            arr[i] = _val;
        }
        return arr;
    }
}

interface IFXPool {
    function assimilator(address _derivative) external view returns (address);

    function derivatives(uint256) external view returns (address);

    function liquidity() external view returns (uint256);

    function viewDeposit(uint256 _depositNumeraire) external view returns (uint256, uint256[] memory);

    function viewWithdraw(uint256 _curvesToBurn) external view returns (uint256[] memory);

    function getPoolId() external view returns (bytes32);

    function balanceOf(address account) external view returns (uint256);
}
