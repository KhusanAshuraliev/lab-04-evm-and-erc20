// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {stdError} from "forge-std/StdError.sol";
import {MerkleYul} from "../src/evm/MerkleYul.sol";
import {YulCounter} from "../src/evm/YulCounter.sol";

/// @notice Requirement 6: my Yul functions against their Solidity versions.
contract YulDifferentialTest is Test {
    YulCounter internal c;
    MerkleYul internal m;

    function setUp() public {
        c = new YulCounter();
        m = new MerkleYul();
    }

    // ------------------------------------------- checked sum, with reverts

    /// @notice Full uint256 inputs, so overflow is common. Both versions must
    ///         return the same sum or revert with the same bytes.
    function testFuzz_CheckedSumAgreesIncludingReverts(uint256[] calldata xs) public view {
        (bool okSol, bytes memory retSol) =
            address(c).staticcall(abi.encodeCall(YulCounter.sumSolidity, (xs)));
        (bool okYul, bytes memory retYul) =
            address(c).staticcall(abi.encodeCall(YulCounter.sumCheckedYul, (xs)));
        assertEq(okSol, okYul, "same outcome");
        assertEq(retSol, retYul, "same return data or same revert data");
        if (!okSol) assertEq(retSol, stdError.arithmeticError, "Panic(0x11)");
    }

    function test_CheckedSumOverflowReverts() public {
        uint256[] memory xs = new uint256[](2);
        xs[0] = type(uint256).max;
        xs[1] = 1;
        vm.expectRevert(stdError.arithmeticError);
        c.sumSolidity(xs);
        vm.expectRevert(stdError.arithmeticError);
        c.sumCheckedYul(xs);
    }

    // --------------------------------------------------- Merkle verification

    function _pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    /// @notice A real tree of 2^depth random leaves: both versions accept the
    ///         right proof, and both reject it after one word is changed.
    function testFuzz_MerkleAgreesOnRealTrees(uint256 seed, uint8 depthRaw, uint256 index, uint256 flip)
        public
        view
    {
        uint256 depth = bound(depthRaw, 0, 8);
        uint256 n = 1 << depth;
        index = bound(index, 0, n - 1);

        bytes32[] memory level = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            level[i] = keccak256(abi.encode(seed, i));
        }
        bytes32 leaf = level[index];
        bytes32[] memory proof = new bytes32[](depth);
        uint256 idx = index;
        for (uint256 d = 0; d < depth; d++) {
            proof[d] = level[idx ^ 1];
            bytes32[] memory next = new bytes32[](level.length / 2);
            for (uint256 i = 0; i < next.length; i++) {
                next[i] = _pair(level[2 * i], level[2 * i + 1]);
            }
            level = next;
            idx >>= 1;
        }
        bytes32 root = level[0];

        assertTrue(m.verifySolidity(proof, root, leaf));
        assertTrue(m.verifyYul(proof, root, leaf));

        if (depth > 0) {
            proof[flip % depth] ^= bytes32(uint256(1));
            assertFalse(m.verifySolidity(proof, root, leaf));
            assertFalse(m.verifyYul(proof, root, leaf));
        }
    }

    /// @notice Arbitrary words, including equal neighbours (lo == hi) and
    ///         roots that happen to match.
    function testFuzz_MerkleAgreesOnGarbage(bytes32[] calldata proof, bytes32 root, bytes32 leaf)
        public
        view
    {
        assertEq(m.verifySolidity(proof, root, leaf), m.verifyYul(proof, root, leaf));
        // and on the root each of them computes, so the "true" branch is hit too
        bytes32 node = leaf;
        for (uint256 i = 0; i < proof.length; i++) {
            node = _pair(node, proof[i]);
        }
        assertTrue(m.verifySolidity(proof, node, leaf));
        assertTrue(m.verifyYul(proof, node, leaf));
    }

    function test_MerkleEqualSiblings() public view {
        bytes32 x = keccak256("x");
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = x;
        bytes32 root = keccak256(abi.encodePacked(x, x));
        assertTrue(m.verifySolidity(proof, root, x));
        assertTrue(m.verifyYul(proof, root, x));
    }

    // ------------------------------------------------------------------ gas

    /// @notice Gas of one external call for a 14-element proof, the depth of the
    ///         10,000-recipient airdrop.
    function test_GasMerkle14() public view {
        bytes32[] memory proof = new bytes32[](14);
        bytes32 node = keccak256("leaf");
        for (uint256 i = 0; i < 14; i++) {
            proof[i] = keccak256(abi.encode(i));
            node = _pair(node, proof[i]);
        }

        uint256 g = gasleft();
        bool okSol = m.verifySolidity(proof, node, keccak256("leaf"));
        uint256 gasSol = g - gasleft();
        g = gasleft();
        bool okYul = m.verifyYul(proof, node, keccak256("leaf"));
        uint256 gasYul = g - gasleft();

        assertTrue(okSol && okYul);
        console2.log("merkle verify, 14 levels, solidity gas:", gasSol);
        console2.log("merkle verify, 14 levels, yul gas:     ", gasYul);
        console2.log("saved:                                 ", gasSol - gasYul);
        assertLt(gasYul, gasSol);
    }

    function test_GasCheckedSum100() public view {
        uint256[] memory xs = new uint256[](100);
        for (uint256 i = 0; i < 100; i++) {
            xs[i] = i * 1e18;
        }
        uint256 g = gasleft();
        uint256 a = c.sumSolidity(xs);
        uint256 gasSol = g - gasleft();
        g = gasleft();
        uint256 b = c.sumCheckedYul(xs);
        uint256 gasYul = g - gasleft();

        assertEq(a, b);
        console2.log("checked sum of 100, solidity gas:", gasSol);
        console2.log("checked sum of 100, yul gas:     ", gasYul);
        console2.log("saved:                           ", gasSol - gasYul);
        assertLt(gasYul, gasSol);
    }
}
