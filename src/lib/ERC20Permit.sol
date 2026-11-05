// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ECDSA} from "./ECDSA.sol";
import {ERC20} from "./ERC20.sol";

/// @title ERC20Permit
/// @notice EIP-2612: the owner signs an approval off-chain (EIP-712) and anyone
///         can submit it.
/// @dev The four checks: deadline (here), nonce (here), recovered != 0 and
///      low s (both in ECDSA.recover).
abstract contract ERC20Permit is ERC20 {
    bytes32 public constant PERMIT_TYPEHASH = keccak256(
        "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
    );

    bytes32 private constant DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );

    mapping(address owner => uint256) public nonces;

    bytes32 private immutable _versionHash;
    uint256 private immutable _deployChainId;
    address private immutable _deployAddress;
    bytes32 private immutable _deployDomainSeparator;

    error PermitExpired(uint256 deadline);
    error InvalidPermitSigner(address signer, address owner);

    /// @param name_ must equal the token name. It is passed in rather than read
    ///        from storage because the base constructors run before the token
    ///        has stored its name.
    constructor(string memory name_, string memory version_) {
        _versionHash = keccak256(bytes(version_));
        _deployChainId = block.chainid;
        _deployAddress = address(this);
        _deployDomainSeparator = _domainSeparator(keccak256(bytes(name_)));
    }

    /// @notice The cached separator is used only on the chain and at the address
    ///         it was built for. After a chain split (`block.chainid` changes) or
    ///         when the code runs behind a proxy (`address(this)` changes) it is
    ///         rebuilt, so a signature can never be replayed on the other fork.
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        if (block.chainid == _deployChainId && address(this) == _deployAddress) {
            return _deployDomainSeparator;
        }
        return _domainSeparator(keccak256(bytes(name())));
    }

    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        if (block.timestamp > deadline) revert PermitExpired(deadline);

        // The owner signed the CURRENT nonce; it is used up here, so the same
        // signature can never verify again.
        uint256 nonce = nonces[owner]++;

        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));

        address signer = ECDSA.recover(digest, v, r, s);
        if (signer != owner) revert InvalidPermitSigner(signer, owner);

        _approve(owner, spender, value);
    }

    function _domainSeparator(bytes32 nameHash) private view returns (bytes32) {
        return keccak256(
            abi.encode(DOMAIN_TYPEHASH, nameHash, _versionHash, block.chainid, address(this))
        );
    }
}
