// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title ECDSA
/// @notice `ecrecover` with the two checks the precompile does not make.
library ECDSA {
    /// @dev n / 2 for secp256k1. For every valid signature (r, s) the pair
    ///      (r, n - s) is valid too. EIP-2 allows only the lower s, so that
    ///      a third party cannot rewrite the bytes of a signature.
    uint256 internal constant HALF_ORDER =
        0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    error InvalidSignatureS();
    error InvalidSignature();

    function recover(bytes32 digest, uint8 v, bytes32 r, bytes32 s)
        internal
        pure
        returns (address signer)
    {
        if (uint256(s) > HALF_ORDER) revert InvalidSignatureS();

        signer = ecrecover(digest, v, r, s);
        // ecrecover does not revert on garbage input, it returns address(0).
        // Without this line a garbage signature would "prove" that the zero
        // address signed, e.g. a permit with owner = address(0).
        if (signer == address(0)) revert InvalidSignature();
    }
}
