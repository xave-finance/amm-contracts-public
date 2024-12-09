pragma solidity ^0.8.24;

interface IERC20Detailed {
    function decimals() external view returns (uint8);

    function symbol() external view returns (string memory);

    function name() external view returns (string memory);
}
