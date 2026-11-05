// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title MerkleProof
/// @notice Sorted-pair Merkle proofs with double-hashed leaves.
/// @dev Each pair is hashed in ascending order, so a proof needs no left/right
///      flags. The off-chain builder (airdrop/merkle.py) sorts the same way.
library MerkleProof {
    /// @notice leaf = keccak256(keccak256(preimage)).
    /// @dev An internal node is keccak256 of 64 bytes. If a leaf were keccak256
    ///      of the 64-byte abi.encode(account, amount), an attacker could pick
    ///      two sibling nodes, read them as (account, amount) and claim with a
    ///      shortened proof. With the second hash every leaf is the hash of 32
    ///      bytes, which no internal node is.
    function hashLeaf(bytes memory preimage) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(preimage)));
    }

    function verify(bytes32[] calldata proof, bytes32 root, bytes32 leaf)
        internal
        pure
        returns (bool)
    {
        bytes32 node = leaf;
        for (uint256 i = 0; i < proof.length; ++i) {
            node = hashPair(node, proof[i]);
        }
        return node == root;
    }

    function hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32 h) {
        (bytes32 lo, bytes32 hi) = a < b ? (a, b) : (b, a);
        // The two words go into the scratch space 0x00-0x3f, which Solidity
        // reserves for exactly this; no memory is allocated.
        assembly ("memory-safe") {
            mstore(0x00, lo)
            mstore(0x20, hi)
            h := keccak256(0x00, 0x40)
        }
    }
}
