// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import {
    FixedPoint
} from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    IERC20Metadata
} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

// @dev This library contains helper functions for scaling amounts in FXPools.
// These functions used to be part of Balancer's ScalingHelpers library, but were removed.
library FXScalingHelpers {
    function toRawRoundDown(
        uint256 amount,
        uint256 scalingFactor
    ) internal pure returns (uint256) {
        return FixedPoint.divDown(amount, scalingFactor * 1e18);
    }

    function toScaled18RoundDown(
        uint256 amount,
        uint256 scalingFactor
    ) internal pure returns (uint256) {
        return FixedPoint.mulDown(amount, scalingFactor * 1e18);
    }

    function toScaled18RoundUp(
        uint256 amount,
        uint256 scalingFactor
    ) internal pure returns (uint256) {
        return FixedPoint.mulUp(amount, scalingFactor * 1e18);
    }
}
