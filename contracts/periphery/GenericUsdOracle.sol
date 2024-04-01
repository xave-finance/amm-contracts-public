// SPDX-License-Identifier: MIT
pragma solidity 0.7.6;

import {IAggregatorPricingOnly} from '../interfaces/IAggregatorPricingOnly.sol';

/**
* @title GenericUsdOracle
* Used for stablecoins that are fully backed by USD and are not subject to pool ratio consistently within the FX Pool beta region.
* This contract is used to provide a consistent interface for the Chainlink AggregatorV3Interface
*/
contract GenericUsdOracle is IAggregatorPricingOnly {

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
        answer = 1e8;
    }

    function latestAnswer() external view override returns (int256) {
        return 1e8;
    }

    function getAnswer(uint256 /*roundId*/) external view override returns (int256) {
        return 1e8;
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
        answer = 1e8;
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
        answer = 1e8;
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
        answer = 1e8;
    }
}
