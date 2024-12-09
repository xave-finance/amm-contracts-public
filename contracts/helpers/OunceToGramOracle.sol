// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAggregatorPricingOnly} from "../interfaces/IAggregatorPricingOnly.sol";
import {
    IAggregatorAggregatorOnly
} from "../interfaces/IAggregatorAggregatorOnly.sol";

contract OunceToGramOracle is IAggregatorPricingOnly {
    int256 public constant GRAM_PER_TROYOUNCE = int256(31.1034768 * 1e8);
    address public immutable AGGR_ADDR;

    constructor(address _aggregator) {
        AGGR_ADDR = _aggregator;
    }

    fallback() external payable {
        _passthrough(AGGR_ADDR);
    }

    receive() external payable {
        _passthrough(AGGR_ADDR);
    }

    function _passthrough(address implementation) internal {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            // Copy msg.data. We take full control of memory in this inline assembly
            // block because it will not return to Solidity code. We overwrite the
            // Solidity scratch pad at memory position 0.
            calldatacopy(0, 0, calldatasize())

            // Call the implementation.
            // out and outsize are 0 because we don't know the size yet.
            // call contract at address a with input mem[in…(in+insize)) providing
            // g gas and v wei and output area mem[out…(out+outsize))
            // returning 0 on error (eg. out of gas) and 1 on success
            let result := call(
                gas(), // gas
                implementation, // to
                0, // don't transfer any ether
                0, // pointer to start of input
                calldatasize(),
                0,
                0
            )

            // Copy the returned data.
            returndatacopy(0, 0, returndatasize())

            switch result
            // delegatecall returns 0 on error.
            case 0 {
                revert(0, returndatasize())
            }
            default {
                return(0, returndatasize())
            }
        }
    }

    function aggregator() external view returns (address) {
        return IAggregatorAggregatorOnly(AGGR_ADDR).aggregator();
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
        (
            roundId,
            answer,
            startedAt,
            updatedAt,
            answeredInRound
        ) = IAggregatorPricingOnly(AGGR_ADDR).latestRoundData();
        answer = (answer * 1e8) / GRAM_PER_TROYOUNCE;
    }

    function latestAnswer() external view override returns (int256) {
        return
            (IAggregatorPricingOnly(AGGR_ADDR).latestAnswer() * 1e8) /
            GRAM_PER_TROYOUNCE;
    }

    function getAnswer(
        uint256 roundId
    ) external view override returns (int256) {
        return
            (IAggregatorPricingOnly(AGGR_ADDR).getAnswer(roundId) * 1e8) /
            GRAM_PER_TROYOUNCE;
    }

    // IAggregatorPricingOnly
    function getRoundData(
        uint80 _roundId
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
        (
            roundId,
            answer,
            startedAt,
            updatedAt,
            answeredInRound
        ) = IAggregatorPricingOnly(AGGR_ADDR).getRoundData(_roundId);
        answer = (answer * 1e8) / GRAM_PER_TROYOUNCE;
    }

    function proposedGetRoundData(
        uint80 roundId
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
        (
            id,
            answer,
            startedAt,
            updatedAt,
            answeredInRound
        ) = IAggregatorPricingOnly(AGGR_ADDR).proposedGetRoundData(roundId);
        answer = (answer * 1e8) / GRAM_PER_TROYOUNCE;
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
        (
            id,
            answer,
            startedAt,
            updatedAt,
            answeredInRound
        ) = IAggregatorPricingOnly(AGGR_ADDR).proposedLatestRoundData();
        answer = (answer * 1e8) / GRAM_PER_TROYOUNCE;
    }
}
