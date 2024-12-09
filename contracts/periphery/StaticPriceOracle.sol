// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAggregatorPricingOnly} from "../interfaces/IAggregatorPricingOnly.sol";

contract StaticPriceOracle is IAggregatorPricingOnly {
    int256 public price;
    // used by external contracts
    uint8 public decimals;
    // used by external contracts
    string public description;

    event AnswerUpdated(
        int256 indexed current,
        uint256 indexed roundId,
        uint256 updatedAt
    );

    constructor(int256 _price, uint8 _decimals, string memory _description) {
        price = _price;
        decimals = _decimals;
        description = _description;
    }

    function aggregator() external view returns (address) {
        return address(this);
    }

    function latestRoundData()
        external
        view
        override
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        roundId = 1;
        startedAt = block.timestamp;
        updatedAt = block.timestamp;
        answeredInRound = 1;
        answer = price;
    }

    function latestAnswer() external view override returns (int256) {
        return price;
    }

    function getAnswer(
        uint256 
    ) external view override returns (int256) {
        return price;
    }

    // IAggregatorPricingOnly
    function getRoundData(
        uint80 
    )
        external
        view
        override
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        roundId = 1;
        startedAt = block.timestamp;
        updatedAt = block.timestamp;
        answeredInRound = 1;
        answer = price;
    }

    function proposedGetRoundData(
        uint80 
    )
        external
        view
        override
        returns (
            uint80 id,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        id = 1;
        startedAt = block.timestamp;
        updatedAt = block.timestamp;
        answeredInRound = 1;
        answer = price;
    }

    function proposedLatestRoundData()
        external
        view
        override
        returns (
            uint80 id,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        id = 1;
        startedAt = block.timestamp;
        updatedAt = block.timestamp;
        answeredInRound = 1;
        answer = price;
    }

    function updateAnswer() external {
        emit AnswerUpdated(price, 1, block.timestamp);
    }
}
