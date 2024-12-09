pragma solidity ^0.8.24;

function _require(bool condition, uint256 errorCode) pure {
    if (!condition) _revert(errorCode);
}

function _require(bool condition, uint256 errorCode, bytes3 prefix) pure {
    if (!condition) _revert(errorCode, prefix);
}

function _revert(uint256 errorCode) pure {
    _revert(errorCode, 0x465850); // This is the raw byte representation of "FXP"
}

function _revert(uint256 errorCode, bytes3 prefix) pure {
    uint256 prefixUint = uint256(uint24(prefix));
    // We're going to dynamically create a revert string based on the error code, with the following format:
    // 'FXP#{errorCode}'
    // where the code is left-padded with zeroes to three digits (so they range from 000 to 999).
    //
    // We don't have revert strings embedded in the contract to save bytecode size: it takes much less space to store a
    // number (8 to 16 bits) than the individual string characters.
    //
    // The dynamic string creation algorithm that follows could be implemented in Solidity, but assembly allows for a
    // much denser implementation, again saving bytecode size. Given this function unconditionally reverts, this is a
    // safe place to rely on it without worrying about how its usage might affect e.g. memory contents.
    assembly {
        // First, we need to compute the ASCII representation of the error code. We assume that it is in the 0-999
        // range, so we only need to convert three digits. To convert the digits to ASCII, we add 0x30, the value for
        // the '0' character.

        let units := add(mod(errorCode, 10), 0x30)

        errorCode := div(errorCode, 10)
        let tenths := add(mod(errorCode, 10), 0x30)

        errorCode := div(errorCode, 10)
        let hundreds := add(mod(errorCode, 10), 0x30)

        // With the individual characters, we can now construct the full string.
        // We first append the '#' character (0x23) to the prefix. In the case of 'FXP', it results in 0x42414c23 ('FXP#')
        // Then, we shift this by 24 (to provide space for the 3 bytes of the error code), and add the
        // characters to it, each shifted by a multiple of 8.
        // The revert reason is then shifted left by 200 bits (256 minus the length of the string, 7 characters * 8 bits
        // per character = 56) to locate it in the most significant part of the 256 slot (the beginning of a byte
        // array).
        let formattedPrefix := shl(24, add(0x23, shl(8, prefixUint)))

        let revertReason := shl(
            200,
            add(
                formattedPrefix,
                add(add(units, shl(8, tenths)), shl(16, hundreds))
            )
        )

        // We can now encode the reason in memory, which can be safely overwritten as we're about to revert. The encoded
        // message will have the following layout:
        // [ revert reason identifier ] [ string location offset ] [ string length ] [ string contents ]

        // The Solidity revert reason identifier is 0x08c739a0, the function selector of the Error(string) function. We
        // also write zeroes to the next 28 bytes of memory, but those are about to be overwritten.
        mstore(
            0x0,
            0x08c379a000000000000000000000000000000000000000000000000000000000
        )
        // Next is the offset to the location of the string, which will be placed immediately after (20 bytes away).
        mstore(
            0x04,
            0x0000000000000000000000000000000000000000000000000000000000000020
        )
        // The string length is fixed: 7 characters.
        mstore(0x24, 7)
        // Finally, the string itself is stored.
        mstore(0x44, revertReason)

        // Even if the string is only 7 bytes long, we need to return a full 32 byte slot containing it. The length of
        // the encoded message is therefore 4 + 32 + 32 + 32 = 100.
        revert(0, 100)
    }
}

// Frontend Errors Reference: https://github.com/xave-finance/xave-interface/blob/master/src/constants/errors.ts
library Errs {
    // Math
    // Input

    // Lib
    // Deployment related
    uint256 internal constant ORACLE_NOT_WHITELISTED = 500;
    uint256 internal constant POOL_DOES_NOT_EXIST = 501;
    uint256 internal constant LP_BALANCE_VIOLATION = 504;
    uint256 internal constant BELOW_MIN_PROTOCOL_FEE = 505;
    uint256 internal constant NULL_ADDRESS = 506;
    // oracle related
    uint256 internal constant ORACLE_PRICE_ZERO = 507;
    uint256 internal constant ORACLE_ROUND_NOT_COMPLETE = 508;
    uint256 internal constant ORACLE_STALE_PRICE = 509;

    uint256 internal constant BASE_TOKEN_MISMATCH = 510;
    uint256 internal constant QUOTE_TOKEN_MISMATCH = 511;

    uint256 internal constant LP_USER_BALANCE_VIOLATION = 512;
    uint256 internal constant TOKEN_BALANCE_VIOLATION = 513;
    uint256 internal constant SENDER_NOT_VAULT = 514;

    // FXPool Related
    uint256 internal constant FP_TOKEN_ZERO_ADDRESS = 515;
    uint256 internal constant FP_ASSIMILATOR_ZERO_ADDRESS = 516;
    uint256 internal constant FP_WEIGHT_MUST_BE_LESS_THAN_ONE = 517;
    uint256 internal constant FP_INVALID_ALPHA = 518;
    uint256 internal constant FP_INVALID_BETA = 519;
    uint256 internal constant FP_INVALID_MAX = 520;
    uint256 internal constant FP_INVALID_EPSILON = 521;
    uint256 internal constant FP_INVALID_LAMBDA = 522;
    uint256 internal constant FP_PARAMETERS_INCREASE_FEE = 523; // @todo test
    uint256 internal constant FP_AMOUNT_BEYOND_SET_CAP = 524; // @todo test, cap setter not enabled
    uint256 internal constant FP_INVALID_KAPPA = 525;
    uint256 internal constant BASE_ASSIM_MISMATCH = 526;

    // CurveMath
    uint256 internal constant FP_SWAP_INVARIANT_VIOLATION = 527; // @todo test
    uint256 internal constant FP_SWAP_CONVERGENCE_VIOLATION = 528;
    uint256 internal constant FP_CURVE_LIQUIDITY_VIOLATION = 529; // @todo test
    uint256 internal constant FP_UPPER_HALT = 530;
    uint256 internal constant FP_LOWER_HALT = 531;

    uint256 internal constant FP_INVALID_ASSET = 532;
    uint256 internal constant FP_CAP_IS_NOT_GREATER_THAN_TOTAL_LIQUIDITY = 533;
    uint256 internal constant FP_QUOTE_TOKEN_NOT_IN_POOL = 534;
    uint256 internal constant FP_ORACLE_PRICE_ZERO = 535;
}
