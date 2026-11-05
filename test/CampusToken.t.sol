// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {AccessControl} from "../src/lib/AccessControl.sol";
import {CampusToken} from "../src/CampusToken.sol";
import {ECDSA} from "../src/lib/ECDSA.sol";
import {ERC20} from "../src/lib/ERC20.sol";
import {ERC20Permit} from "../src/lib/ERC20Permit.sol";

contract CampusTokenTest is Test {
    CampusToken internal token;

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal mallory = makeAddr("mallory");

    uint256 internal constant CAP = 1_000_000 ether;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Claimed(address indexed account, uint256 amount);

    function setUp() public {
        token = new CampusToken("Campus Token", "CMPS", CAP, admin, treasury);
        vm.prank(admin);
        token.mint(alice, 1000 ether);
    }

    // ===================================================================== //
    // Metadata and construction
    // ===================================================================== //

    function test_Metadata() public view {
        assertEq(token.name(), "Campus Token");
        assertEq(token.symbol(), "CMPS");
        assertEq(token.decimals(), 18);
        assertEq(token.cap(), CAP);
        assertEq(token.treasury(), treasury);
    }

    function test_DeployerIsNotAutomaticallyPrivileged() public view {
        // Authority was handed to `admin`, not to whoever ran the constructor.
        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), admin));
        assertFalse(token.hasRole(token.DEFAULT_ADMIN_ROLE(), address(this)));
    }

    function test_RevertWhen_CapIsZero() public {
        vm.expectRevert(CampusToken.ZeroCap.selector);
        new CampusToken("X", "X", 0, admin, treasury);
    }

    function test_RevertWhen_TreasuryIsZero() public {
        vm.expectRevert(CampusToken.ZeroAddress.selector);
        new CampusToken("X", "X", CAP, admin, address(0));
    }

    // ===================================================================== //
    // Transfers
    // ===================================================================== //

    function test_Transfer() public {
        vm.prank(alice);
        token.transfer(bob, 100 ether);
        assertEq(token.balanceOf(alice), 900 ether);
        assertEq(token.balanceOf(bob), 100 ether);
    }

    function test_TransferEmitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit Transfer(alice, bob, 100 ether);
        vm.prank(alice);
        token.transfer(bob, 100 ether);
    }

    function test_RevertWhen_TransferExceedsBalance() public {
        vm.expectRevert(
            abi.encodeWithSelector(ERC20.InsufficientBalance.selector, alice, 1000 ether, 2000 ether)
        );
        vm.prank(alice);
        token.transfer(bob, 2000 ether);
    }

    function test_RevertWhen_TransferToZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(ERC20.InvalidReceiver.selector, address(0)));
        vm.prank(alice);
        token.transfer(address(0), 1 ether);
    }

    function test_TransferFromSpendsAllowance() public {
        vm.prank(alice);
        token.approve(bob, 100 ether);

        vm.prank(bob);
        token.transferFrom(alice, mallory, 60 ether);

        assertEq(token.allowance(alice, bob), 40 ether);
        assertEq(token.balanceOf(mallory), 60 ether);
    }

    function test_InfiniteAllowanceIsNotDecremented() public {
        vm.prank(alice);
        token.approve(bob, type(uint256).max);

        vm.prank(bob);
        token.transferFrom(alice, mallory, 500 ether);

        assertEq(token.allowance(alice, bob), type(uint256).max);
    }

    /// @notice Demonstrates the approve race condition described in ERC20.approve.
    function test_ApproveRaceCondition() public {
        vm.prank(alice);
        token.approve(bob, 100 ether);

        // Alice decides to reduce the allowance to 50. Bob sees the pending
        // transaction and front-runs it, spending the full 100 first.
        vm.prank(bob);
        token.transferFrom(alice, bob, 100 ether);

        // Alice's reduction now lands, granting a FRESH 50 on top.
        vm.prank(alice);
        token.approve(bob, 50 ether);

        vm.prank(bob);
        token.transferFrom(alice, bob, 50 ether);

        // Bob obtained 150 although Alice never intended to permit more than 100.
        assertEq(token.balanceOf(bob), 150 ether);
    }

    // ===================================================================== //
    // Supply cap
    // ===================================================================== //

    function test_MintRespectsCap() public {
        vm.prank(admin);
        token.mint(bob, CAP - 1000 ether);
        assertEq(token.totalSupply(), CAP);
    }

    function test_RevertWhen_MintExceedsCap() public {
        vm.expectRevert(
            abi.encodeWithSelector(CampusToken.CapExceeded.selector, CAP + 1 ether, CAP)
        );
        vm.prank(admin);
        token.mint(bob, CAP - 1000 ether + 1 ether);
    }

    /// @notice Burning frees headroom, because the cap constrains supply, not issuance.
    function test_BurnFreesCapHeadroom() public {
        vm.prank(admin);
        token.mint(bob, CAP - 1000 ether);

        vm.prank(bob);
        token.burn(500 ether);

        vm.prank(admin);
        token.mint(bob, 500 ether); // must succeed
        assertEq(token.totalSupply(), CAP);
    }

    // ===================================================================== //
    // Access control
    // ===================================================================== //

    function test_RevertWhen_NonMinterMints() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                AccessControl.MissingRole.selector, token.MINTER_ROLE(), mallory
            )
        );
        vm.prank(mallory);
        token.mint(mallory, 1 ether);
    }

    /// @dev The role constant is read into a local BEFORE `vm.prank`. `vm.prank`
    ///      arms only the very next call frame; if an argument expression itself
    ///      makes an external call -- `token.MINTER_ROLE()` here -- THAT call
    ///      consumes the prank, and the intended call executes as the test
    ///      contract instead of the pranked account. This is a well-known
    ///      Foundry pitfall and worth internalising: always resolve any external
    ///      calls needed for arguments before arming a prank, never inline them
    ///      in the pranked call's own argument list.
    function test_RolesAreSeparable() public {
        bytes32 minterRole = token.MINTER_ROLE();

        vm.prank(admin);
        token.grantRole(minterRole, bob);

        // Bob can mint but must not be able to change configuration.
        vm.prank(bob);
        token.mint(bob, 1 ether);

        vm.expectRevert();
        vm.prank(bob);
        token.setFeeBps(100);
    }

    function test_RevertWhen_NonAdminGrantsRole() public {
        bytes32 minterRole = token.MINTER_ROLE();

        vm.expectRevert();
        vm.prank(mallory);
        token.grantRole(minterRole, mallory);
    }

    function test_RenounceOnlyAffectsSelf() public {
        bytes32 minterRole = token.MINTER_ROLE();

        vm.prank(admin);
        token.renounceRole(minterRole);
        assertFalse(token.hasRole(minterRole, admin));
    }

    // ===================================================================== //
    // Transfer fee
    // ===================================================================== //

    function test_FeeIsRoutedToTreasury() public {
        vm.prank(admin);
        token.setFeeBps(250); // 2.5%

        vm.prank(alice);
        token.transfer(bob, 100 ether);

        assertEq(token.balanceOf(bob), 97.5 ether);
        assertEq(token.balanceOf(treasury), 2.5 ether);
        assertEq(token.balanceOf(alice), 900 ether);
    }

    function test_FeeDoesNotChangeTotalSupply() public {
        vm.prank(admin);
        token.setFeeBps(250);

        uint256 before = token.totalSupply();
        vm.prank(alice);
        token.transfer(bob, 100 ether);
        assertEq(token.totalSupply(), before, "a fee redistributes, it does not burn");
    }

    function test_MintAndBurnAreExemptFromFee() public {
        vm.prank(admin);
        token.setFeeBps(500);

        vm.prank(admin);
        token.mint(bob, 100 ether);
        assertEq(token.balanceOf(bob), 100 ether, "minting must not be taxed");
        assertEq(token.balanceOf(treasury), 0);
    }

    function test_DustTransferPaysNoFee() public {
        vm.prank(admin);
        token.setFeeBps(250);

        // value * feeBps / 10_000 rounds to zero for very small transfers.
        vm.prank(alice);
        token.transfer(bob, 3);
        assertEq(token.balanceOf(bob), 3);
        assertEq(token.balanceOf(treasury), 0);
    }

    function test_RevertWhen_FeeAboveMaximum() public {
        vm.expectRevert(
            abi.encodeWithSelector(CampusToken.FeeTooHigh.selector, uint16(501), uint16(500))
        );
        vm.prank(admin);
        token.setFeeBps(501);
    }

    // ===================================================================== //
    // Pause
    // ===================================================================== //

    function test_PauseBlocksTransfers() public {
        vm.prank(admin);
        token.setPaused(true);

        vm.expectRevert(CampusToken.TransfersPaused.selector);
        vm.prank(alice);
        token.transfer(bob, 1 ether);
    }

    function test_UnpauseRestoresTransfers() public {
        vm.startPrank(admin);
        token.setPaused(true);
        token.setPaused(false);
        vm.stopPrank();

        vm.prank(alice);
        token.transfer(bob, 1 ether);
        assertEq(token.balanceOf(bob), 1 ether);
    }

    // ===================================================================== //
    // EIP-2612 permit
    // ===================================================================== //

    function _permitDigest(
        address owner,
        address spender,
        uint256 value,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(token.PERMIT_TYPEHASH(), owner, spender, value, nonce, deadline)
        );
        return keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
    }

    function test_Permit() public {
        (address owner, uint256 pk) = makeAddrAndKey("permitOwner");
        vm.prank(admin);
        token.mint(owner, 100 ether);

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _permitDigest(owner, bob, 50 ether, 0, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);

        // Anyone may submit it -- the owner spends no gas and needs no ETH.
        vm.prank(mallory);
        token.permit(owner, bob, 50 ether, deadline, v, r, s);

        assertEq(token.allowance(owner, bob), 50 ether);
        assertEq(token.nonces(owner), 1);
    }

    function test_RevertWhen_PermitReplayed() public {
        (address owner, uint256 pk) = makeAddrAndKey("permitOwner");
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _permitDigest(owner, bob, 50 ether, 0, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);

        token.permit(owner, bob, 50 ether, deadline, v, r, s);

        // The nonce has advanced, so the same signature no longer matches.
        vm.expectRevert();
        token.permit(owner, bob, 50 ether, deadline, v, r, s);
    }

    function test_RevertWhen_PermitExpired() public {
        (address owner, uint256 pk) = makeAddrAndKey("permitOwner");
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _permitDigest(owner, bob, 50 ether, 0, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);

        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.PermitExpired.selector, deadline));
        token.permit(owner, bob, 50 ether, deadline, v, r, s);
    }

    function test_RevertWhen_PermitSignedByAnotherKey() public {
        (address owner,) = makeAddrAndKey("permitOwner");
        (, uint256 attackerPk) = makeAddrAndKey("attacker");

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _permitDigest(owner, bob, 50 ether, 0, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attackerPk, digest);

        vm.expectRevert();
        token.permit(owner, bob, 50 ether, deadline, v, r, s);
    }

    /// @notice The malleable second encoding of a valid signature must be rejected.
    function test_RevertWhen_PermitUsesHighS() public {
        (address owner, uint256 pk) = makeAddrAndKey("permitOwner");
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _permitDigest(owner, bob, 50 ether, 0, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);

        // Flip to the upper half of the curve order: still a valid ECDSA
        // signature for the same message, but forbidden by EIP-2.
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 highS = bytes32(n - uint256(s));
        uint8 flippedV = v == 27 ? 28 : 27;

        vm.expectRevert(ECDSA.InvalidSignatureS.selector);
        token.permit(owner, bob, 50 ether, deadline, flippedV, r, highS);
    }

    /// @notice A signature for one chain must not be valid on another.
    function test_DomainSeparatorDependsOnChainId() public {
        bytes32 before = token.DOMAIN_SEPARATOR();
        vm.chainId(block.chainid + 1);
        assertTrue(token.DOMAIN_SEPARATOR() != before, "must not be cached across chains");
    }

    // ===================================================================== //
    // Merkle allowlist
    // ===================================================================== //

    /// @dev A four-leaf tree built by hand so that every hash is visible:
    ///
    ///                    root
    ///                  /      \
    ///               n01        n23
    ///              /   \      /   \
    ///            L0     L1  L2     L3
    function _buildTree()
        internal
        view
        returns (bytes32 root, bytes32[] memory leaves, bytes32 n01, bytes32 n23)
    {
        leaves = new bytes32[](4);
        leaves[0] = token.leafFor(alice, 100 ether);
        leaves[1] = token.leafFor(bob, 200 ether);
        leaves[2] = token.leafFor(mallory, 300 ether);
        leaves[3] = token.leafFor(treasury, 400 ether);

        n01 = _hashPair(leaves[0], leaves[1]);
        n23 = _hashPair(leaves[2], leaves[3]);
        root = _hashPair(n01, n23);
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function test_ClaimWithValidProof() public {
        (bytes32 root, bytes32[] memory leaves, , bytes32 n23) = _buildTree();

        vm.prank(admin);
        token.setClaimRoot(root);

        bytes32[] memory proof = new bytes32[](2);
        proof[0] = leaves[1];
        proof[1] = n23;

        vm.expectEmit(true, false, false, true);
        emit Claimed(alice, 100 ether);
        vm.prank(alice);
        token.claim(100 ether, proof);

        assertEq(token.balanceOf(alice), 1100 ether); // 1000 from setUp + 100 claimed
        assertTrue(token.hasClaimed(alice));
    }

    function test_RevertWhen_ClaimedTwice() public {
        (bytes32 root, bytes32[] memory leaves, , bytes32 n23) = _buildTree();
        vm.prank(admin);
        token.setClaimRoot(root);

        bytes32[] memory proof = new bytes32[](2);
        proof[0] = leaves[1];
        proof[1] = n23;

        vm.startPrank(alice);
        token.claim(100 ether, proof);
        vm.expectRevert(abi.encodeWithSelector(CampusToken.AlreadyClaimed.selector, alice));
        token.claim(100 ether, proof);
        vm.stopPrank();
    }

    function test_RevertWhen_ClaimingWrongAmount() public {
        (bytes32 root, bytes32[] memory leaves, , bytes32 n23) = _buildTree();
        vm.prank(admin);
        token.setClaimRoot(root);

        bytes32[] memory proof = new bytes32[](2);
        proof[0] = leaves[1];
        proof[1] = n23;

        // The amount is part of the leaf, so inflating it breaks the proof.
        vm.expectRevert(CampusToken.InvalidMerkleProof.selector);
        vm.prank(alice);
        token.claim(999 ether, proof);
    }

    function test_RevertWhen_ClaimingWithAnotherAccountsProof() public {
        (bytes32 root, bytes32[] memory leaves, , bytes32 n23) = _buildTree();
        vm.prank(admin);
        token.setClaimRoot(root);

        bytes32[] memory proof = new bytes32[](2);
        proof[0] = leaves[1];
        proof[1] = n23;

        // The leaf commits to msg.sender, so the proof is not transferable.
        vm.expectRevert(CampusToken.InvalidMerkleProof.selector);
        vm.prank(mallory);
        token.claim(100 ether, proof);
    }

    function test_RevertWhen_ClaimsNotOpen() public {
        bytes32[] memory proof = new bytes32[](0);
        vm.expectRevert(CampusToken.ClaimsNotOpen.selector);
        vm.prank(alice);
        token.claim(1 ether, proof);
    }

    /// @notice Leaves must not be confusable with internal nodes.
    /// @dev Without double hashing, an attacker could submit an internal node as
    ///      a leaf and prove membership of an entry that was never in the set.
    function test_InternalNodeCannotBePassedOffAsALeaf() public {
        (bytes32 root, , bytes32 n01, ) = _buildTree();
        vm.prank(admin);
        token.setClaimRoot(root);

        // Try to use n01 (an internal node) as if it were this account's leaf.
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = n01;

        vm.expectRevert(CampusToken.InvalidMerkleProof.selector);
        vm.prank(alice);
        token.claim(100 ether, proof);
    }

    function test_ClaimRespectsCap() public {
        // Fill the supply so that a claim would breach the cap.
        vm.prank(admin);
        token.mint(bob, CAP - 1000 ether);

        (bytes32 root, bytes32[] memory leaves, , bytes32 n23) = _buildTree();
        vm.prank(admin);
        token.setClaimRoot(root);

        bytes32[] memory proof = new bytes32[](2);
        proof[0] = leaves[1];
        proof[1] = n23;

        vm.expectRevert();
        vm.prank(alice);
        token.claim(100 ether, proof);
    }

    // ===================================================================== //
    // Fuzz
    // ===================================================================== //

    function testFuzz_TransferPreservesTotalSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != alice && to != treasury);
        amount = bound(amount, 0, token.balanceOf(alice));

        uint256 supplyBefore = token.totalSupply();
        vm.prank(alice);
        token.transfer(to, amount);
        assertEq(token.totalSupply(), supplyBefore);
    }

    function testFuzz_FeeNeverExceedsMaximum(uint16 feeBps, uint256 amount) public {
        feeBps = uint16(bound(feeBps, 0, token.MAX_FEE_BPS()));
        amount = bound(amount, 1, token.balanceOf(alice));

        vm.prank(admin);
        token.setFeeBps(feeBps);

        uint256 treasuryBefore = token.balanceOf(treasury);
        vm.prank(alice);
        token.transfer(bob, amount);

        uint256 fee = token.balanceOf(treasury) - treasuryBefore;
        assertLe(fee * 10_000, amount * token.MAX_FEE_BPS());
    }

    function testFuzz_MintNeverBreachesCap(uint256 amount) public {
        amount = bound(amount, 0, type(uint128).max);
        uint256 supply = token.totalSupply();

        if (supply + amount > CAP) {
            vm.expectRevert();
        }
        vm.prank(admin);
        token.mint(bob, amount);
        assertLe(token.totalSupply(), CAP);
    }
}
