// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    IERC20Permit
} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {
    IERC20Metadata
} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC5267} from "@openzeppelin/contracts/interfaces/IERC5267.sol";
import {IERC165} from "@openzeppelin/contracts/interfaces/IERC165.sol";
import {IVault} from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import {PoolBoundaries} from "../FXPoolTypes.sol";
import {Storage} from "../Storage.sol";

interface IFXPool is IERC20, IERC20Metadata, IERC20Permit, IERC5267, IERC165 {
    struct FXAssets {
        address quoteToken;
        address quoteAssimilator;
        uint256 quoteWeight;
        address baseToken;
        address baseAssimilator;
        uint256 baseWeight;
    }

    // Pool Configuration
    function setParams(
        uint256 _alpha,
        uint256 _beta,
        uint256 _feeAtHalt,
        uint256 _epsilon,
        uint256 _lambda
    ) external;
    function viewParameters()
        external
        view
        returns (
            uint256 alpha_,
            uint256 beta_,
            uint256 delta_,
            uint256 epsilon_,
            uint256 lambda_,
            uint256 kappa_
        );
    function setCollectorAddress(address _collectorAddress) external;
    function setProtocolPercentFee(uint256 _protocolPercentFee) external;
    function unclaimedProtocolFeesNumeraire() external view returns (int256);

    // Pool Information
    function baseToken() external view returns (address);
    function quoteToken() external view returns (address);
    function tokens(uint256 _index) external view returns (address);
    function isQuoteIndexZero() external view returns (bool);
    function getVault() external view returns (IVault);
    function getCurve() external view returns (Storage.Curve memory);
    function protocolPercentFee() external view returns (uint256);
    function getAssetIndex(
        address token
    ) external view returns (uint8 assetIndex);

    // Liquidity Management
    function liquidity()
        external
        view
        returns (uint256 total_, uint256[] memory individual_);
    function viewDeposit(
        uint256 totalDepositNumeraire
    ) external view returns (uint256, uint256[] memory);
    function viewWithdraw(
        uint256 _curvesToBurn
    ) external view returns (uint256[] memory);

    // Pool State and Boundaries
    function getPoolBoundaries()
        external
        view
        returns (PoolBoundaries memory boundaries);
    function isSwapWithinBeta(
        address tokenIn,
        uint256 amount
    ) external view returns (bool);
    function isInBeta() external view returns (bool, uint256, address);
    function isBalanced() external view returns (bool);
    function viewSwapToBalancePool()
        external
        view
        returns (
            address fromToken,
            address toToken,
            uint256 rawAmount,
            uint256 numeraireAmount
        );

    // Utility Functions
    function assimilator(
        address _derivative
    ) external view returns (address assimilator_);
    function getRate() external view returns (uint256);
    function convertNumeraireToRaw(
        address token,
        uint256 numeraireAmount
    ) external view returns (uint256 rawAmount);
    function convertRawToNumeraire(
        address token,
        uint256 rawAmount
    ) external view returns (uint256 numeraireAmount);
}
