// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessControl} from "./lib/AccessControl.sol";
import {ERC20} from "./lib/ERC20.sol";
import {ERC20Permit} from "./lib/ERC20Permit.sol";
import {MerkleProof} from "./lib/MerkleProof.sol";

/// @title CampusToken
/// @notice A capped ERC-20 with separate roles, a transfer fee to a treasury,
///         EIP-2612 permit and a Merkle allowlist, written without any library.
/// @dev Bonus E4 puts the same code behind a proxy: CampusTokenUpgradeable
///      inherits from this contract and replaces the immutable cap by a storage
///      variable and the constructor by an initializer.
contract CampusToken is ERC20, ERC20Permit, AccessControl {
    // ------------------------------------------------------------------ roles

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant CONFIG_ROLE = keccak256("CONFIG_ROLE");

    // ------------------------------------------------------------------ fee

    uint16 public constant BPS_DENOMINATOR = 10_000;
    /// @notice Hard ceiling of the fee (5 %). A compromised CONFIG_ROLE can
    ///         therefore take at most 5 % of a transfer, never all of it.
    uint16 public constant MAX_FEE_BPS = 500;

    // ------------------------------------------------------------------ state

    // One slot (slot 8): 20 + 2 + 1 = 23 bytes. All three are read on every
    // transfer, so one cold SLOAD serves the whole check.
    address public treasury;
    uint16 public feeBps;
    bool public paused;

    bytes32 public claimRoot;
    mapping(address account => bool) public hasClaimed;

    // ------------------------------------------------------- events, errors

    event FeeUpdated(uint16 previousBps, uint16 newBps);
    event TreasuryUpdated(address indexed previous, address indexed current);
    event ClaimRootUpdated(bytes32 indexed previous, bytes32 indexed current);
    event PausedSet(bool paused);
    event Claimed(address indexed account, uint256 amount);

    error ZeroCap();
    error ZeroAddress();
    error CapExceeded(uint256 attempted, uint256 cap);
    error FeeTooHigh(uint16 requested, uint16 maximum);
    error TransfersPaused();
    error ClaimsNotOpen();
    error AlreadyClaimed(address account);
    error InvalidMerkleProof();

    // ------------------------------------------------------------------ setup

    /// @dev Immutable: stored in the code, not in a storage slot.
    uint256 private immutable _cap;

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 cap_,
        address admin,
        address treasury_
    ) ERC20Permit(name_, "1") {
        if (cap_ == 0) revert ZeroCap();
        _cap = cap_;
        _setUp(name_, symbol_, admin, treasury_);
    }

    /// @notice Hard maximum of the total supply.
    function cap() public view virtual returns (uint256) {
        return _cap;
    }

    /// @dev Called once, by the constructor here or by the initializer of
    ///      CampusTokenUpgradeable. The admin is a parameter: whoever sends
    ///      the deployment transaction receives no role at all.
    function _setUp(string memory name_, string memory symbol_, address admin, address treasury_)
        internal
    {
        if (admin == address(0) || treasury_ == address(0)) revert ZeroAddress();
        _setMetadata(name_, symbol_);
        treasury = treasury_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MINTER_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(CONFIG_ROLE, admin);
    }

    // ------------------------------------------------------------ mint, burn

    function mint(address to, uint256 value) external onlyRole(MINTER_ROLE) {
        _mint(to, value);
    }

    /// @notice Burns the caller's own tokens. Nobody can burn someone else's.
    function burn(uint256 value) external {
        _burn(msg.sender, value);
    }

    // ------------------------------------------------------------- the funnel

    /// @dev Every mint, burn, transfer, transferFrom and claim arrives here, so
    ///      the pause, the cap and the fee are checked in one place only.
    function _update(address from, address to, uint256 value) internal virtual override {
        // One SLOAD for treasury, feeBps and paused (they share slot 8).
        address treasury_ = treasury;
        uint16 feeBps_ = feeBps;
        if (paused) revert TransfersPaused();

        if (from == address(0)) {
            uint256 newSupply = totalSupply() + value;
            uint256 cap_ = cap();
            if (newSupply > cap_) revert CapExceeded(newSupply, cap_);
        }

        // No fee on mint and burn (the supply arithmetic would break) and none
        // on transfers from or to the treasury.
        uint256 fee = 0;
        if (
            feeBps_ != 0 && from != address(0) && to != address(0) && from != treasury_
                && to != treasury_
        ) {
            // Rounds down: a dust transfer whose fee would be < 1 wei pays none.
            fee = value * feeBps_ / BPS_DENOMINATOR;
        }

        if (fee == 0) {
            super._update(from, to, value);
            return;
        }

        // Check the full amount first, so that the error reports what the
        // sender actually tried to send instead of the second, smaller leg.
        uint256 fromBalance = balanceOf(from);
        if (fromBalance < value) revert InsufficientBalance(from, fromBalance, value);

        unchecked {
            // fee <= value * 500 / 10_000 < value
            super._update(from, to, value - fee);
        }
        super._update(from, treasury_, fee);
    }

    // ------------------------------------------------------------- the claim

    /// @notice Claim `amount` by proving that (msg.sender, amount) is a leaf of
    ///         the tree whose root is `claimRoot`.
    function claim(uint256 amount, bytes32[] calldata proof) external {
        bytes32 root = claimRoot;
        if (root == bytes32(0)) revert ClaimsNotOpen();
        if (hasClaimed[msg.sender]) revert AlreadyClaimed(msg.sender);
        if (!MerkleProof.verify(proof, root, leafFor(msg.sender, amount))) {
            revert InvalidMerkleProof();
        }

        // Effect before the mint. The mint goes through _update, so the cap and
        // the pause apply to claims exactly as to `mint`.
        hasClaimed[msg.sender] = true;
        _mint(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    /// @notice The leaf of (account, amount). The off-chain tool must produce
    ///         the same bytes: keccak256(keccak256(abi.encode(account, amount))).
    function leafFor(address account, uint256 amount) public pure returns (bytes32) {
        return MerkleProof.hashLeaf(abi.encode(account, amount));
    }

    // ---------------------------------------------------------- configuration

    function setFeeBps(uint16 newFeeBps) external onlyRole(CONFIG_ROLE) {
        if (newFeeBps > MAX_FEE_BPS) revert FeeTooHigh(newFeeBps, MAX_FEE_BPS);
        emit FeeUpdated(feeBps, newFeeBps);
        feeBps = newFeeBps;
    }

    function setTreasury(address newTreasury) external onlyRole(CONFIG_ROLE) {
        if (newTreasury == address(0)) revert ZeroAddress();
        emit TreasuryUpdated(treasury, newTreasury);
        treasury = newTreasury;
    }

    function setClaimRoot(bytes32 newRoot) external onlyRole(CONFIG_ROLE) {
        emit ClaimRootUpdated(claimRoot, newRoot);
        claimRoot = newRoot;
    }

    function setPaused(bool value) external onlyRole(PAUSER_ROLE) {
        paused = value;
        emit PausedSet(value);
    }
}
