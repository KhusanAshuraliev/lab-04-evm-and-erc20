// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title AccessControl
/// @notice Roles as bytes32 ids. Every role has an admin role that may grant and
///         revoke it; DEFAULT_ADMIN_ROLE (0x00) is the admin of every role whose
///         admin was never changed, including itself.
/// @dev Nothing is granted automatically. The inheriting contract decides who
///      the first admin is. CampusToken keeps every role under
///      DEFAULT_ADMIN_ROLE, so I left out a setter for role admins: code that is
///      never called is code nobody tests.
abstract contract AccessControl {
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

    mapping(bytes32 role => mapping(address account => bool)) private _members;
    mapping(bytes32 role => bytes32 adminRole) private _admins;

    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);

    error MissingRole(bytes32 role, address account);

    modifier onlyRole(bytes32 role) {
        if (!_members[role][msg.sender]) revert MissingRole(role, msg.sender);
        _;
    }

    function hasRole(bytes32 role, address account) public view returns (bool) {
        return _members[role][account];
    }

    function getRoleAdmin(bytes32 role) public view returns (bytes32) {
        return _admins[role];
    }

    function grantRole(bytes32 role, address account) external onlyRole(_admins[role]) {
        _grantRole(role, account);
    }

    function revokeRole(bytes32 role, address account) external onlyRole(_admins[role]) {
        _revokeRole(role, account);
    }

    /// @notice An account can only give up its own role.
    function renounceRole(bytes32 role) external {
        _revokeRole(role, msg.sender);
    }

    function _grantRole(bytes32 role, address account) internal {
        if (_members[role][account]) return;
        _members[role][account] = true;
        emit RoleGranted(role, account, msg.sender);
    }

    function _revokeRole(bytes32 role, address account) internal {
        if (!_members[role][account]) return;
        _members[role][account] = false;
        emit RoleRevoked(role, account, msg.sender);
    }
}
