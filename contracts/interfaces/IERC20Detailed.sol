pragma solidity 0.7.6;

interface IERC20Detailed {
    function decimals() external view returns (uint8);

    function symbol() external view returns (string memory);

    function name() external view returns (string memory);
}
