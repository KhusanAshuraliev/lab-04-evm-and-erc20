// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Logic version 1. `value` is in slot 0 -- and under delegatecall,
///         slot 0 means slot 0 of the PROXY.
contract LogicV1 {
    uint256 public value; // slot 0

    event ValueSet(uint256 value);

    function setValue(uint256 v) external {
        value = v;
        emit ValueSet(v);
    }

    function version() external pure returns (uint256) {
        return 1;
    }
}

/// @notice Logic version 2. The old variable keeps its slot; the new one is
///         appended after it.
contract LogicV2 {
    uint256 public value; //      slot 0, unchanged
    uint256 public multiplier; // slot 1, new

    event ValueSet(uint256 value);

    function setValue(uint256 v) external {
        value = v;
        emit ValueSet(v);
    }

    function setMultiplier(uint256 m) external {
        multiplier = m;
    }

    function applyMultiplier() external {
        value = value * multiplier;
    }

    function version() external pure returns (uint256) {
        return 2;
    }
}

/// @notice Forwards every call with delegatecall to the code at `target`.
/// @dev Plain ETH transfers are forwarded too, so the logic decides whether it
///      accepts ETH. An empty receive() here would trap ETH in the proxy.
abstract contract Forwarder {
    function _target() internal view virtual returns (address);

    fallback() external payable {
        _forward();
    }

    receive() external payable {
        _forward();
    }

    function _forward() private {
        address target = _target();
        // Assembly is needed: the length of the return data is only known at
        // run time, and Solidity cannot return a byte string verbatim.
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), target, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if iszero(ok) { revert(0, returndatasize()) }
            return(0, returndatasize())
        }
    }
}

/// @title BrokenProxy
/// @notice The bug, on purpose: the implementation address is an ordinary state
///         variable in slot 0, where LogicV1 keeps `value`.
/// @dev After `setValue(0xDEAD)` the proxy delegates to 0xDEAD. That address has
///      no code, and a call to an address without code SUCCEEDS with empty
///      return data. The proxy never reverts again; it just does nothing.
contract BrokenProxy is Forwarder {
    address public implementation; // slot 0 -- collides with LogicV1.value

    constructor(address impl) {
        implementation = impl;
    }

    function _target() internal view override returns (address) {
        return implementation;
    }
}

/// @title SafeProxy
/// @notice EIP-1967 proxy. Its two addresses live in slots that the compiler
///         never assigns: keccak256(label) - 1.
/// @dev The "- 1" means the slot is not the hash of a known preimage, so no
///      mapping key or array index can ever compute it.
contract SafeProxy is Forwarder {
    /// 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc
    bytes32 internal constant IMPLEMENTATION_SLOT =
        bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
    /// 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103
    bytes32 internal constant ADMIN_SLOT = bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);

    event Upgraded(address indexed implementation);
    event AdminChanged(address previousAdmin, address newAdmin);

    error NotAdmin();
    error NotAContract();

    constructor(address impl, address admin_) {
        _setImplementation(impl);
        _store(ADMIN_SLOT, admin_);
        emit AdminChanged(address(0), admin_);
    }

    function implementation() external view returns (address) {
        return _load(IMPLEMENTATION_SLOT);
    }

    function admin() external view returns (address) {
        return _load(ADMIN_SLOT);
    }

    function upgradeTo(address newImplementation) external {
        if (msg.sender != _load(ADMIN_SLOT)) revert NotAdmin();
        _setImplementation(newImplementation);
    }

    /// @dev The code-size check turns the silent failure of BrokenProxy into a
    ///      revert: pointing the proxy at an address without code is refused.
    function _setImplementation(address impl) private {
        if (impl.code.length == 0) revert NotAContract();
        _store(IMPLEMENTATION_SLOT, impl);
        emit Upgraded(impl);
    }

    function _target() internal view override returns (address) {
        return _load(IMPLEMENTATION_SLOT);
    }

    function _load(bytes32 slot) private view returns (address a) {
        assembly ("memory-safe") {
            a := sload(slot)
        }
    }

    function _store(bytes32 slot, address a) private {
        assembly ("memory-safe") {
            sstore(slot, a)
        }
    }
}

/// @title SafeProxyWithInit
/// @notice SafeProxy that runs an initializer in its own constructor, so the
///         proxy can never exist in an uninitialised state that a front-runner
///         could initialise first (used for the upgradeable token, bonus E4).
contract SafeProxyWithInit is SafeProxy {
    constructor(address impl, address admin_, bytes memory initData) SafeProxy(impl, admin_) {
        (bool ok, bytes memory ret) = impl.delegatecall(initData);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }
}

/// @notice The storage-gap convention: a base contract reserves slots it may
///         need later, so that adding a variable to it does not move the
///         variables of the contracts that inherit from it.
abstract contract UpgradeableBase {
    uint256 public baseValue; // slot 0
    uint256[49] private __gap; // slots 1..49
}

contract DerivedV1 is UpgradeableBase {
    uint256 public derivedValue; // slot 50

    function setDerived(uint256 v) external {
        derivedValue = v;
    }
}
