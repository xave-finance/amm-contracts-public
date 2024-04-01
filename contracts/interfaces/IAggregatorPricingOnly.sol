// SPDX-License-Identifier: MIT
pragma solidity 0.7.6;

interface IAggregatorPricingOnly {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    function latestAnswer() external view returns (int256);

    function getAnswer(uint256 roundId) external view returns (int256);

    // IAggregatorPricingOnly
    function getRoundData(
        uint80 _roundId
    )
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    function proposedGetRoundData(
        uint80 roundId
    ) external view returns (uint80 id, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    function proposedLatestRoundData()
        external
        view
        returns (uint80 id, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
