// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {CampusToken} from "../CampusToken.sol";

/// @title CampusTokenUpgradeable (V1)
/// @notice Bonus E4. CampusToken behind SafeProxy: an initializer instead of the
///         constructor, and the cap in storage, because an immutable lives in
///         the implementation's code and would be shared by every proxy.
/// @dev Storage after CampusToken (slots 0..10): `_cap` 11, `_initialized` 12,
///      `__gap` 13..60. A later version appends after slot 60.
///
///      The implementation contract runs CampusToken's constructor for its OWN
///      storage, giving every role to itself (an address that cannot call
///      anything), and marks itself initialised. Nothing of that is visible
///      through a proxy, which only sees its own storage. Behind a proxy
///      address(this) is the proxy, so DOMAIN_SEPARATOR() is always rebuilt
///      from the proxy's name and address.
contract CampusTokenUpgradeable is CampusToken {
    uint256 private _storedCap;
    bool private _initialized;
    uint256[48] private __gap;

    error AlreadyInitialized();

    constructor() CampusToken("", "", 1, address(this), address(this)) {
        _initialized = true;
    }

    function initialize(
        string calldata name_,
        string calldata symbol_,
        uint256 cap_,
        address admin,
        address treasury_
    ) external {
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;
        if (cap_ == 0) revert ZeroCap();
        _storedCap = cap_;
        _setUp(name_, symbol_, admin, treasury_);
    }

    function cap() public view override returns (uint256) {
        return _storedCap;
    }

    function version() external pure virtual returns (uint256) {
        return 1;
    }
}
