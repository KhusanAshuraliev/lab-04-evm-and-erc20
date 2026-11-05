// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title YulCounter
/// @notice Each operation twice, in Solidity and in Yul, so that the cost of
///         the compiler's safety checks can be measured and the two versions can
///         be compared by differential fuzzing (test/EvmInternals.t.sol and
///         test/YulDifferential.t.sol).
contract YulCounter {
    /// @dev Slot 0. The Yul below writes slot 0 directly, so a new variable
    ///      declared above this one would silently break it.
    uint256 public counter;

    error TooLarge(uint256 value);

    // ------------------------------------------------------------ increment

    function incrementSolidity() external {
        counter += 1;
    }

    /// @dev No overflow check. 2^256 increments are impossible in practice, but
    ///      the reader now has to know that instead of the compiler.
    function incrementYul() external {
        assembly ("memory-safe") {
            sstore(0, add(sload(0), 1))
        }
    }

    // ------------------------------------------------- sum, unchecked in Yul

    function sumSolidity(uint256[] calldata xs) external pure returns (uint256 total) {
        for (uint256 i = 0; i < xs.length; i++) {
            total += xs[i];
        }
    }

    /// @dev Reads the elements straight from calldata. Bounds checks can be left
    ///      out only because the loop runs over xs.length itself. This version
    ///      WRAPS on overflow where Solidity reverts, so it agrees with
    ///      sumSolidity only while the sum fits in 256 bits.
    function sumYul(uint256[] calldata xs) external pure returns (uint256 total) {
        assembly ("memory-safe") {
            let p := xs.offset
            let end := add(p, shl(5, xs.length))
            for {} lt(p, end) { p := add(p, 0x20) } {
                total := add(total, calldataload(p))
            }
        }
    }

    // ------------------------------------------- sum, checked in Yul (mine)

    /// @notice Like sumYul, but reverts on overflow with exactly the bytes that
    ///         Solidity's checked arithmetic produces: Panic(uint256) with code
    ///         0x11. So it must agree with sumSolidity on EVERY input, including
    ///         the ones that revert.
    function sumCheckedYul(uint256[] calldata xs) external pure returns (uint256 total) {
        assembly ("memory-safe") {
            let p := xs.offset
            let end := add(p, shl(5, xs.length))
            for {} lt(p, end) { p := add(p, 0x20) } {
                let next := add(total, calldataload(p))
                // a + b wrapped around iff the result is smaller than a
                if lt(next, total) {
                    mstore(0x00, shl(224, 0x4e487b71)) // bytes4(keccak256("Panic(uint256)"))
                    mstore(0x04, 0x11) //                arithmetic overflow
                    revert(0x00, 0x24)
                }
                total := next
            }
        }
    }

    // ----------------------------------------------- custom error from Yul

    function guardSolidity(uint256 value) external pure returns (uint256) {
        if (value > 1000) revert TooLarge(value);
        return value;
    }

    /// @dev A custom error is encoded like a call: selector, then arguments.
    function guardYul(uint256 value) external pure returns (uint256) {
        bytes4 selector = TooLarge.selector;
        assembly ("memory-safe") {
            if gt(value, 1000) {
                mstore(0x00, selector) // bytes4 is left-aligned in the word
                mstore(0x04, value)
                revert(0x00, 0x24)
            }
        }
        return value;
    }
}
