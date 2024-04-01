// SPDX-License-Identifier: MIT
pragma solidity 0.7.6;

import {IAggregatorPricingOnly} from '../interfaces/IAggregatorPricingOnly.sol';

interface BakiVaultInterface {
    function getGlobalDebt() external view returns (uint256);

    function totalCollateral() external view returns (uint256);
}

contract BakiOracleAdaptor is IAggregatorPricingOnly {
    address public immutable VAULT_ADDRESS;
    int256 ONE = 100000000;

    constructor(address _aggregator) {
        VAULT_ADDRESS = _aggregator;
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        roundId = 1;
        startedAt = block.timestamp;
        updatedAt = block.timestamp;
        answeredInRound = 1;
        answer = collateralRatioPrice();
    }

    function latestAnswer() external view override returns (int256) {
        return collateralRatioPrice();
    }

    function getAnswer(uint256 /*roundId*/) external view override returns (int256) {
        return collateralRatioPrice();
    }

    // IAggregatorPricingOnly
    function getRoundData(
        uint80 /*_roundId*/
    )
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        roundId = 1;
        startedAt = block.timestamp;
        updatedAt = block.timestamp;
        answeredInRound = 1;
        answer = collateralRatioPrice();
    }

    function proposedGetRoundData(
        uint80 /*roundId*/
    )
        external
        view
        override
        returns (uint80 id, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        id = 1;
        startedAt = block.timestamp;
        updatedAt = block.timestamp;
        answeredInRound = 1;
        answer = collateralRatioPrice();
    }

    function proposedLatestRoundData()
        external
        view
        override
        returns (uint80 id, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        id = 1;
        startedAt = block.timestamp;
        updatedAt = block.timestamp;
        answeredInRound = 1;
        answer = collateralRatioPrice();
    }

    function collateralRatioPrice() internal view returns (int256) {
        uint256 ratio = ((BakiVaultInterface(VAULT_ADDRESS).totalCollateral() * 1000) /
            BakiVaultInterface(VAULT_ADDRESS).getGlobalDebt());

        // if collateral > 100% * debt -> price of zToken is 1e8 ($1)
        // if collateral < 100% * debt -> price of zToken is the ratio (add 1e5 to make it 1e8)
        return ratio > 1000 ? ONE : int256(ratio * 1e5);
    }
}
