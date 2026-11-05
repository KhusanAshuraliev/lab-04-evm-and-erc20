// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {AccessControl} from "../src/lib/AccessControl.sol";
import {CampusToken} from "../src/CampusToken.sol";
import {ECDSA} from "../src/lib/ECDSA.sol";
import {ERC20} from "../src/lib/ERC20.sol";
import {ERC20Permit} from "../src/lib/ERC20Permit.sol";

/// @notice My own tests, on top of the course's suite in CampusToken.t.sol.
///         Together the two files trigger every custom error of my contracts.
contract CampusTokenExtraTest is Test {
    CampusToken internal token;

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint256 internal constant CAP = 1_000_000 ether;
    uint256 internal constant N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        token = new CampusToken("Campus Token", "CMPS", CAP, admin, treasury);
        vm.prank(admin);
        token.mint(alice, 1000 ether);
    }

    // ================================================================ ledger

    function test_MintEmitsTransferFromZero() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(0), bob, 5 ether);
        vm.prank(admin);
        token.mint(bob, 5 ether);
    }

    function test_BurnEmitsTransferToZero() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, address(0), 5 ether);
        vm.prank(alice);
        token.burn(5 ether);
        assertEq(token.totalSupply(), 995 ether);
    }

    function test_ApproveEmitsApproval() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(alice, bob, 7 ether);
        vm.prank(alice);
        token.approve(bob, 7 ether);
    }

    function test_RevertWhen_ApproveZeroSpender() public {
        vm.expectRevert(abi.encodeWithSelector(ERC20.InvalidSpender.selector, address(0)));
        vm.prank(alice);
        token.approve(address(0), 1);
    }

    function test_RevertWhen_MintToZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(ERC20.InvalidReceiver.selector, address(0)));
        vm.prank(admin);
        token.mint(address(0), 1);
    }

    function test_RevertWhen_TransferFromExceedsAllowance() public {
        vm.prank(alice);
        token.approve(bob, 10 ether);
        vm.expectRevert(
            abi.encodeWithSelector(ERC20.InsufficientAllowance.selector, bob, 10 ether, 11 ether)
        );
        vm.prank(bob);
        token.transferFrom(alice, bob, 11 ether);
    }

    function test_RevertWhen_BurnExceedsBalance() public {
        vm.expectRevert(
            abi.encodeWithSelector(ERC20.InsufficientBalance.selector, bob, 0, 1 ether)
        );
        vm.prank(bob);
        token.burn(1 ether);
    }

    /// @notice Deliverable 1: Alice's balance read straight from storage.
    ///         `_balances` is the first variable of my ERC20, so it is slot 0.
    function test_BalanceSlotArithmetic() public view {
        bytes32 slot = keccak256(abi.encode(alice, uint256(0)));
        assertEq(uint256(vm.load(address(token), slot)), token.balanceOf(alice));
        assertEq(uint256(vm.load(address(token), slot)), 1000 ether);
        // the declared slot of the mapping itself stays empty
        assertEq(vm.load(address(token), bytes32(0)), bytes32(0));
        // slot 2 is _totalSupply
        assertEq(uint256(vm.load(address(token), bytes32(uint256(2)))), token.totalSupply());
    }

    /// @notice Slot 8 packs treasury (offset 0), feeBps (20) and paused (22).
    function test_PackedConfigurationSlot() public {
        vm.startPrank(admin);
        token.setFeeBps(123);
        token.setPaused(true);
        vm.stopPrank();

        uint256 word = uint256(vm.load(address(token), bytes32(uint256(8))));
        assertEq(address(uint160(word)), treasury, "treasury, bytes 0..19");
        assertEq(uint16(word >> 160), 123, "feeBps, bytes 20..21");
        assertEq(uint8(word >> 176), 1, "paused, byte 22");
        assertEq(word >> 184, 0, "bytes 23..31 unused");
    }

    // ===================================================== cap and the roles

    function test_DeployerHoldsNoRoleAtAll() public view {
        bytes32[4] memory roles = [
            token.DEFAULT_ADMIN_ROLE(),
            token.MINTER_ROLE(),
            token.PAUSER_ROLE(),
            token.CONFIG_ROLE()
        ];
        for (uint256 i = 0; i < 4; i++) {
            assertFalse(token.hasRole(roles[i], address(this)), "deployer");
            assertTrue(token.hasRole(roles[i], admin), "admin");
        }
    }

    function test_RevertWhen_AdminIsZero() public {
        vm.expectRevert(CampusToken.ZeroAddress.selector);
        new CampusToken("X", "X", CAP, address(0), treasury);
    }

    /// @notice Each role on a different account; each account can do its own
    ///         job only.
    function test_EachRoleOnADifferentAccount() public {
        address minter = makeAddr("minter");
        address pauser = makeAddr("pauser");
        address config = makeAddr("config");
        bytes32 minterRole = token.MINTER_ROLE();
        bytes32 pauserRole = token.PAUSER_ROLE();
        bytes32 configRole = token.CONFIG_ROLE();

        vm.startPrank(admin);
        token.grantRole(minterRole, minter);
        token.grantRole(pauserRole, pauser);
        token.grantRole(configRole, config);
        vm.stopPrank();

        vm.prank(minter);
        token.mint(bob, 1 ether);
        vm.prank(config);
        token.setFeeBps(10);
        vm.prank(pauser);
        token.setPaused(true);

        vm.expectRevert(abi.encodeWithSelector(AccessControl.MissingRole.selector, pauserRole, minter));
        vm.prank(minter);
        token.setPaused(false);

        vm.expectRevert(abi.encodeWithSelector(AccessControl.MissingRole.selector, minterRole, pauser));
        vm.prank(pauser);
        token.mint(pauser, 1);

        vm.expectRevert(abi.encodeWithSelector(AccessControl.MissingRole.selector, configRole, pauser));
        vm.prank(pauser);
        token.setTreasury(pauser);
    }

    function test_EveryRoleIsAdministeredByTheDefaultAdmin() public view {
        assertEq(token.getRoleAdmin(token.MINTER_ROLE()), token.DEFAULT_ADMIN_ROLE());
        assertEq(token.getRoleAdmin(token.PAUSER_ROLE()), token.DEFAULT_ADMIN_ROLE());
        assertEq(token.getRoleAdmin(token.CONFIG_ROLE()), token.DEFAULT_ADMIN_ROLE());
        assertEq(token.getRoleAdmin(token.DEFAULT_ADMIN_ROLE()), token.DEFAULT_ADMIN_ROLE());
    }

    function test_RevokedMinterCannotMint() public {
        bytes32 minterRole = token.MINTER_ROLE();
        vm.prank(admin);
        token.revokeRole(minterRole, admin);

        vm.expectRevert(abi.encodeWithSelector(AccessControl.MissingRole.selector, minterRole, admin));
        vm.prank(admin);
        token.mint(bob, 1);
    }

    function test_PauseAlsoBlocksMintAndBurn() public {
        vm.prank(admin);
        token.setPaused(true);

        vm.expectRevert(CampusToken.TransfersPaused.selector);
        vm.prank(admin);
        token.mint(bob, 1);

        vm.expectRevert(CampusToken.TransfersPaused.selector);
        vm.prank(alice);
        token.burn(1);
    }

    // ====================================================================== fee

    /// @notice The example of requirement 3: 1,000 tokens at 1 %.
    function test_OnePercentOfAThousand() public {
        vm.prank(admin);
        token.setFeeBps(100);

        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, bob, 990 ether);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, treasury, 10 ether);
        vm.prank(alice);
        token.transfer(bob, 1000 ether);

        assertEq(token.balanceOf(bob), 990 ether);
        assertEq(token.balanceOf(treasury), 10 ether);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), 1000 ether);
    }

    function test_TransfersFromAndToTreasuryPayNoFee() public {
        vm.prank(admin);
        token.setFeeBps(500);

        vm.prank(alice);
        token.transfer(treasury, 100 ether);
        assertEq(token.balanceOf(treasury), 100 ether, "to the treasury: no fee");

        vm.prank(treasury);
        token.transfer(bob, 40 ether);
        assertEq(token.balanceOf(bob), 40 ether, "from the treasury: no fee");
    }

    function test_FeeAlsoAppliesToTransferFrom() public {
        vm.prank(admin);
        token.setFeeBps(200);
        vm.prank(alice);
        token.approve(bob, 100 ether);

        vm.prank(bob);
        token.transferFrom(alice, carol, 100 ether);

        assertEq(token.balanceOf(carol), 98 ether);
        assertEq(token.balanceOf(treasury), 2 ether);
        assertEq(token.allowance(alice, bob), 0, "the allowance covers the gross amount");
    }

    /// @notice With a fee, an overdraft reports the full amount, not the
    ///         smaller first leg of the split.
    function test_RevertWhen_FeeTransferExceedsBalance() public {
        vm.prank(admin);
        token.setFeeBps(100);
        vm.expectRevert(
            abi.encodeWithSelector(ERC20.InsufficientBalance.selector, alice, 1000 ether, 1001 ether)
        );
        vm.prank(alice);
        token.transfer(bob, 1001 ether);
    }

    function test_SetTreasury() public {
        address newTreasury = makeAddr("newTreasury");
        vm.prank(admin);
        token.setTreasury(newTreasury);
        assertEq(token.treasury(), newTreasury);

        vm.prank(admin);
        token.setFeeBps(100);
        vm.prank(alice);
        token.transfer(bob, 100 ether);
        assertEq(token.balanceOf(newTreasury), 1 ether);
        assertEq(token.balanceOf(treasury), 0);
    }

    function test_RevertWhen_TreasurySetToZero() public {
        vm.expectRevert(CampusToken.ZeroAddress.selector);
        vm.prank(admin);
        token.setTreasury(address(0));
    }

    // ================================================================== permit

    function _digest(address owner, address spender, uint256 value, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash =
            keccak256(abi.encode(token.PERMIT_TYPEHASH(), owner, spender, value, nonce, deadline));
        return keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
    }

    function test_PermitEmitsApproval() public {
        (address owner, uint256 pk) = makeAddrAndKey("owner");
        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, _digest(owner, bob, 9 ether, 0, deadline));

        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(owner, bob, 9 ether);
        token.permit(owner, bob, 9 ether, deadline, v, r, s);
    }

    function test_PermitAtTheDeadlineIsStillValid() public {
        (address owner, uint256 pk) = makeAddrAndKey("owner");
        uint256 deadline = block.timestamp + 100;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, _digest(owner, bob, 1, 0, deadline));
        vm.warp(deadline);
        token.permit(owner, bob, 1, deadline, v, r, s);
        assertEq(token.allowance(owner, bob), 1);
    }

    /// @notice The exact error for a wrong signer: the recovered address and the
    ///         claimed owner.
    function test_RevertWhen_PermitSignerIsNotTheOwner() public {
        (address owner,) = makeAddrAndKey("owner");
        (address attacker, uint256 attackerPk) = makeAddrAndKey("attacker");
        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(attackerPk, _digest(owner, bob, 1 ether, 0, deadline));

        vm.expectRevert(
            abi.encodeWithSelector(ERC20Permit.InvalidPermitSigner.selector, attacker, owner)
        );
        token.permit(owner, bob, 1 ether, deadline, v, r, s);
    }

    /// @notice A replayed permit fails because the nonce moved on: the digest is
    ///         now built with nonce 1 and recovers to some unrelated address.
    function test_RevertWhen_PermitReplayedExactError() public {
        (address owner, uint256 pk) = makeAddrAndKey("owner");
        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, _digest(owner, bob, 1 ether, 0, deadline));
        token.permit(owner, bob, 1 ether, deadline, v, r, s);

        address recovered = ecrecover(_digest(owner, bob, 1 ether, 1, deadline), v, r, s);
        vm.expectRevert(
            abi.encodeWithSelector(ERC20Permit.InvalidPermitSigner.selector, recovered, owner)
        );
        token.permit(owner, bob, 1 ether, deadline, v, r, s);
        assertEq(token.nonces(owner), 1);
    }

    /// @notice A malformed signature makes ecrecover return address(0). That
    ///         must not count as a signature of the zero address.
    function test_RevertWhen_SignatureIsGarbage() public {
        uint256 deadline = block.timestamp + 1 days;
        vm.expectRevert(ECDSA.InvalidSignature.selector);
        token.permit(address(0), bob, 1 ether, deadline, 27, bytes32(0), bytes32(0));

        vm.expectRevert(ECDSA.InvalidSignature.selector);
        token.permit(address(0), bob, 1 ether, deadline, 29, bytes32(uint256(1)), bytes32(uint256(1)));
    }

    function test_RevertWhen_PermitSpenderIsZero() public {
        (address owner, uint256 pk) = makeAddrAndKey("owner");
        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(pk, _digest(owner, address(0), 1 ether, 0, deadline));
        vm.expectRevert(abi.encodeWithSelector(ERC20.InvalidSpender.selector, address(0)));
        token.permit(owner, address(0), 1 ether, deadline, v, r, s);
    }

    /// @notice My separator equals the EIP-712 formula, and after a chain-id
    ///         change it equals the formula with the NEW chain id.
    function test_DomainSeparatorMatchesEip712() public {
        bytes32 typeHash = keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );
        bytes32 expected = keccak256(
            abi.encode(typeHash, keccak256("Campus Token"), keccak256("1"), block.chainid, address(token))
        );
        assertEq(token.DOMAIN_SEPARATOR(), expected);

        vm.chainId(999);
        expected = keccak256(
            abi.encode(typeHash, keccak256("Campus Token"), keccak256("1"), 999, address(token))
        );
        assertEq(token.DOMAIN_SEPARATOR(), expected);
    }

    /// @notice A permit signed on the old chain is useless after the split.
    function test_RevertWhen_PermitReplayedOnAnotherChain() public {
        (address owner, uint256 pk) = makeAddrAndKey("owner");
        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, _digest(owner, bob, 1 ether, 0, deadline));

        vm.chainId(block.chainid + 1);
        vm.expectRevert(); // InvalidPermitSigner with an unrelated recovered address
        token.permit(owner, bob, 1 ether, deadline, v, r, s);
    }

    // ============================================================ Merkle claim

    function _pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function test_RevertWhen_ClaimIsPaused() public {
        bytes32 leafA = token.leafFor(alice, 1 ether);
        bytes32 leafB = token.leafFor(bob, 2 ether);
        vm.startPrank(admin);
        token.setClaimRoot(_pair(leafA, leafB));
        token.setPaused(true);
        vm.stopPrank();

        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leafB;
        vm.expectRevert(CampusToken.TransfersPaused.selector);
        vm.prank(alice);
        token.claim(1 ether, proof);
        assertFalse(token.hasClaimed(alice), "a failed claim is not recorded");
    }

    /// @notice The claim goes through the same cap check as mint, with the same
    ///         error.
    function test_ClaimHitsTheCapWithCapExceeded() public {
        vm.prank(admin);
        token.mint(bob, CAP - 1000 ether);

        bytes32 leafA = token.leafFor(alice, 1);
        bytes32 leafB = token.leafFor(bob, 1);
        vm.prank(admin);
        token.setClaimRoot(_pair(leafA, leafB));

        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leafB;
        vm.expectRevert(abi.encodeWithSelector(CampusToken.CapExceeded.selector, CAP + 1, CAP));
        vm.prank(alice);
        token.claim(1, proof);
    }

    /// @notice What the second hash prevents. With single-hashed leaves the
    ///         internal node n01 = H(L0, L1) would be a leaf of the 64-byte
    ///         preimage (L0, L1) -- i.e. account = low 20 bytes of L0, amount =
    ///         L1. With double hashing this "account" has no valid proof.
    function test_SecondPreimageAccountCannotClaim() public {
        bytes32 l0 = token.leafFor(alice, 1 ether);
        bytes32 l1 = token.leafFor(bob, 2 ether);
        bytes32 l2 = token.leafFor(carol, 3 ether);
        bytes32 l3 = token.leafFor(treasury, 4 ether);
        (bytes32 lo, bytes32 hi) = l0 < l1 ? (l0, l1) : (l1, l0);
        bytes32 n01 = _pair(l0, l1);
        bytes32 n23 = _pair(l2, l3);
        vm.prank(admin);
        token.setClaimRoot(_pair(n01, n23));

        // A single-hash leaf of (lo, hi) would equal n01 exactly.
        assertEq(keccak256(abi.encodePacked(lo, hi)), n01);

        address fake = address(uint160(uint256(lo)));
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = n23;
        vm.expectRevert(CampusToken.InvalidMerkleProof.selector);
        vm.prank(fake);
        token.claim(uint256(hi), proof);
    }

    function test_ClosingClaimsWithZeroRoot() public {
        vm.startPrank(admin);
        token.setClaimRoot(keccak256("something"));
        token.setClaimRoot(bytes32(0));
        vm.stopPrank();

        vm.expectRevert(CampusToken.ClaimsNotOpen.selector);
        vm.prank(alice);
        token.claim(1, new bytes32[](0));
    }

    // ==================================================================== fuzz

    /// @notice The split of every transfer: net + fee = amount, fee is the
    ///         rounded-down share, and the supply does not move.
    function testFuzz_FeeSplit(uint16 feeBps, uint256 amount) public {
        feeBps = uint16(bound(feeBps, 0, token.MAX_FEE_BPS()));
        amount = bound(amount, 0, 1000 ether);
        vm.prank(admin);
        token.setFeeBps(feeBps);

        vm.prank(alice);
        token.transfer(bob, amount);

        uint256 fee = amount * feeBps / 10_000;
        assertEq(token.balanceOf(treasury), fee);
        assertEq(token.balanceOf(bob), amount - fee);
        assertEq(token.balanceOf(bob) + token.balanceOf(treasury), amount);
        assertEq(token.totalSupply(), 1000 ether);
    }

    /// @notice transferFrom never takes more allowance than the amount moved,
    ///         and an unlimited allowance stays unlimited.
    function testFuzz_TransferFromAllowance(uint256 allowance_, uint256 amount) public {
        allowance_ = bound(allowance_, 0, type(uint256).max);
        amount = bound(amount, 0, 1000 ether);
        vm.prank(alice);
        token.approve(bob, allowance_);

        if (amount > allowance_) {
            vm.expectRevert(
                abi.encodeWithSelector(ERC20.InsufficientAllowance.selector, bob, allowance_, amount)
            );
            vm.prank(bob);
            token.transferFrom(alice, carol, amount);
            return;
        }

        vm.prank(bob);
        token.transferFrom(alice, carol, amount);
        if (allowance_ == type(uint256).max) {
            assertEq(token.allowance(alice, bob), type(uint256).max);
        } else {
            assertEq(token.allowance(alice, bob), allowance_ - amount);
        }
        assertEq(token.balanceOf(carol), amount);
    }

    /// @notice Permits from many different keys. Every honest signature works
    ///         (vm.sign always returns the low-s form), and its high-s twin is
    ///         always refused. This also checks the constant n/2 in ECDSA.sol:
    ///         a wrong constant would reject honest signatures with a large s.
    function testFuzz_PermitFromAnyKey(uint256 pk, uint256 value) public {
        pk = bound(pk, 1, N - 1);
        address owner = vm.addr(pk);
        vm.assume(owner != address(0));
        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, _digest(owner, bob, value, 0, deadline));

        vm.expectRevert(ECDSA.InvalidSignatureS.selector);
        token.permit(owner, bob, value, deadline, v == 27 ? 28 : 27, r, bytes32(N - uint256(s)));

        token.permit(owner, bob, value, deadline, v, r, s);
        assertEq(token.allowance(owner, bob), value);
        assertEq(token.nonces(owner), 1);
    }

    /// @notice Among 512 honest signatures, most have s above n/32. This is the
    ///         case a constant with one hex digit missing (n/32 instead of n/2)
    ///         would reject.
    function test_HonestSignaturesUseTheWholeLowerHalf() public pure {
        uint256 above;
        for (uint256 i = 1; i <= 64; i++) {
            (,, bytes32 s) = vm.sign(i, keccak256(abi.encode(i)));
            if (uint256(s) > ECDSA.HALF_ORDER / 16) above++;
        }
        console2.log("signatures with s > n/32 (of 64):", above);
        assertGt(above, 48);
    }
}
