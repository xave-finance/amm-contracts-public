pragma solidity ^0.8.24;

import "./interfaces/IOracle.sol";
import "./Assimilators.sol";
import {IVault} from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";

contract Storage {
    struct Curve {
        // Curve parameters
        int128 alpha;
        int128 beta;
        int128 delta;
        int128 epsilon;
        int128 lambda;
        int128 kappa;
        int128[] weights;
        uint256 cap;
        // assimilators
        address[] assimilators;
        // Vault reference
        IVault vault;
        address fxPoolAddress;
    }

    // Curve parameters
    Curve public curve;

    address public immutable baseToken;
    address public immutable quoteToken;
    address[] public tokens;

    // Curve operational state
    bool public emergency;
}
