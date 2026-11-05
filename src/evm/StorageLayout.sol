// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title StorageLayout
/// @notice One variable of each kind, so that the slot rules can be checked with
///         `vm.load` (tests) and `forge inspect StorageLayout storageLayout`.
contract StorageLayout {
    // slot 0: 16 + 8 + 1 = 25 bytes, packed from the low-order end of the word
    uint128 public packedA; // offset 0
    uint64 public packedB; //  offset 16
    uint8 public packedC; //   offset 24

    // slot 1: a full word never shares
    uint256 public wide;

    // slot 2: 20 + 1 bytes
    address public owner; // offset 0
    bool public flag; //     offset 20

    // slot 3: stays zero; entry k is at keccak256(abi.encode(k, 3))
    mapping(address account => uint256) public balances;

    // slot 4: holds the length; element i is at keccak256(abi.encode(4)) + i
    uint256[] public values;

    // slot 5: entry [o][s] is at keccak256(abi.encode(s, keccak256(abi.encode(o, 5))))
    mapping(address owner => mapping(address spender => uint256)) public allowances;

    // slot 6: no getter, but anybody can read it with eth_getStorageAt
    uint256 private _notReallySecret;

    // no slot: a constant is copied into the code at every use, an immutable is
    // written into the runtime code by the constructor
    uint256 public constant CONSTANT_VALUE = 42;
    uint256 public immutable IMMUTABLE_VALUE;

    constructor(uint256 immutableValue) {
        IMMUTABLE_VALUE = immutableValue;
    }

    // ---------------------------------------------- slot arithmetic, in code

    function mappingSlot(address key) public pure returns (bytes32) {
        return keccak256(abi.encode(key, uint256(3)));
    }

    function arrayDataSlot(uint256 index) public pure returns (bytes32) {
        return bytes32(uint256(keccak256(abi.encode(uint256(4)))) + index);
    }

    function nestedMappingSlot(address outer, address inner) public pure returns (bytes32) {
        return keccak256(abi.encode(inner, keccak256(abi.encode(outer, uint256(5)))));
    }

    /// @notice Reads any slot of this contract, `private` ones included.
    function readSlot(uint256 slot) public view returns (bytes32 word) {
        assembly ("memory-safe") {
            word := sload(slot)
        }
    }

    // ------------------------------------------------------------- setters

    function setPacked(uint128 a, uint64 b, uint8 c) external {
        packedA = a;
        packedB = b;
        packedC = c;
    }

    function setWide(uint256 v) external {
        wide = v;
    }

    function setOwnerAndFlag(address o, bool f) external {
        owner = o;
        flag = f;
    }

    function setBalance(address account, uint256 amount) external {
        balances[account] = amount;
    }

    function pushValue(uint256 v) external {
        values.push(v);
    }

    function setAllowance(address o, address s, uint256 amount) external {
        allowances[o][s] = amount;
    }

    function stashSecret(uint256 v) external {
        _notReallySecret = v;
    }
}

/// @notice Same four values, two declaration orders.
/// @dev uint192 + uint64 = 32 bytes exactly. Interleaved (a, b, c, d) they fill
///      two slots with nothing left over. Grouped by type (a, c, b, d) the two
///      uint192 cannot share a slot, so the two uint64 need a third one.
contract PackingGoodOrder {
    uint192 public a; // slot 0
    uint64 public b; //  slot 0
    uint192 public c; // slot 1
    uint64 public d; //  slot 1

    function setAll(uint192 a_, uint64 b_, uint192 c_, uint64 d_) external {
        (a, b, c, d) = (a_, b_, c_, d_);
    }
}

contract PackingBadOrder {
    uint192 public a; // slot 0
    uint192 public c; // slot 1
    uint64 public b; //  slot 2
    uint64 public d; //  slot 2

    function setAll(uint192 a_, uint192 c_, uint64 b_, uint64 d_) external {
        (a, c, b, d) = (a_, c_, b_, d_);
    }
}
