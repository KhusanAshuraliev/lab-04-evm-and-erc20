// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {MerkleProof} from "../lib/MerkleProof.sol";

/// @title MerkleYul
/// @notice My non-trivial Yul function for requirement 6: Merkle-proof
///         verification written entirely in assembly, next to the Solidity
///         library version the token uses. test/YulDifferential.t.sol checks
///         that both give the same answer for random trees, random proofs and
///         random garbage, and measures the gas of both.
contract MerkleYul {
    function verifySolidity(bytes32[] calldata proof, bytes32 root, bytes32 leaf)
        external
        pure
        returns (bool)
    {
        return MerkleProof.verify(proof, root, leaf);
    }

    /// @dev Walks the proof in calldata. At each level the smaller of the two
    ///      words goes to 0x00 and the larger to 0x20 (scratch space), and the
    ///      64 bytes are hashed. The ordering is done without a branch:
    ///        lo = node xor ((node xor sib) * (sib < node))
    ///        hi = node xor sib xor lo
    function verifyYul(bytes32[] calldata proof, bytes32 root, bytes32 leaf)
        external
        pure
        returns (bool ok)
    {
        assembly ("memory-safe") {
            let node := leaf
            let p := proof.offset
            let end := add(p, shl(5, proof.length))
            for {} lt(p, end) { p := add(p, 0x20) } {
                let sib := calldataload(p)
                let x := xor(node, sib)
                let lo := xor(node, mul(x, lt(sib, node)))
                mstore(0x00, lo)
                mstore(0x20, xor(x, lo))
                node := keccak256(0x00, 0x40)
            }
            ok := eq(node, root)
        }
    }
}
