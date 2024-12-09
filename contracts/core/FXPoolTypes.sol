// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

struct FXAssets {
    address quoteToken;
    uint256 quoteWeight;
    address baseToken;
    uint256 baseWeight;
}

struct FXGreeks {
    uint256 alpha;
    uint256 beta;
    uint256 max;
    uint256 epsilon;
    uint256 lambda;
    uint256 kappa;
}

struct NewPoolParams {
    string name;
    string symbol;
    uint256 protocolPercentFee;
    address owner;
    FXAssets assets;
    FXGreeks greeks;
}

struct FXPoolData {
    address poolAddress;
    address baseAssimilatorTemplate;
    bool exists;
}

enum FXAssetType {
    Quote,
    Base
}

/// @notice Struct to represent the beta and halt boundaries of the pool
/// @dev This struct contains information about liquidity limits of beta and halts regions.
/// All values are in numeraire.
struct PoolBoundaries {
    uint256 upperBeta; // limit of the upper beta boundary
    uint256 lowerBeta; // limit of the lower beta boundary
    // limit of the upper halt boundary
    uint256 upperHalt;
    // limit of the lower halt boundary
    uint256 lowerHalt;
    uint256 balancedSwapAmt;
    // the lowest amount in numeraire that needs to be swapped to reach the beta
    // boundary (either upper of lower beta)
    // in case the pool is outside of beta boundaries
    // this is the amount that needs to be swapped to move the pool back in beta boundaries
    uint256 betaSwapAmtMin;
    // highest amount in numeraire that if swapped will reach the other edge
    // of the beta boundary; if the pool is outside of beta boundaries
    // this value will be the amount that needs to be swapped to move the pool towards the
    // opposite edge of the beta boundary
    uint256 betaSwapAmtMax;
    // lowest amount in numeraire that can be swapped before reaching the halt boundary
    uint256 haltSwapAmtMin;
    // highest amount in numeraire that can be swapped before reaching the halt boundary
    uint256 haltSwapAmtMax;
    // token to be used alongside betaSwapAmtMin amount to reach the nearest beta boundary
    // ie. with the least amount of liquidity swapped
    address betaSwapAmtMinToken;
    // token to be used alongside betaSwapAmtMax amount to reach the other edge of the beta boundary
    // ie. giving the user the most amount of liquidity swapped within the beta boundaries
    address betaSwapAmtMaxToken;
    // the token to swap to reach the nearest boundary of halt
    address haltSwapAmtMaxToken;
    // the token to swap to reach the furthest boundary of halt
    address haltSwapAmtMinToken;
    // the token to swap to towards the balanced state
    address balancedSwapToken;
    // if true then the pool is within the beta boundaries
    bool isWithinBeta;
    // if true then the pool is balanced (within a 1% tolerance)
    bool isBalanced;
}
