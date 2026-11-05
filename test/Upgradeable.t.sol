// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {AccessControl} from "../src/lib/AccessControl.sol";
import {CampusToken} from "../src/CampusToken.sol";
import {SafeProxy, SafeProxyWithInit} from "../src/evm/Proxy.sol";
import {CampusTokenUpgradeable} from "../src/upgradeable/CampusTokenUpgradeable.sol";
import {CampusTokenV2} from "../src/upgradeable/CampusTokenV2.sol";

/// @dev The WRONG way to add a variable: in a contract that comes first in the
///      inheritance order, so it takes slot 0 and every old variable moves.
abstract contract PrependedVariable {
    uint256 public maxTransfer;
}

contract CampusTokenV2Wrong is PrependedVariable, CampusTokenUpgradeable {}

/// @notice Bonus E4: CampusToken behind my EIP-1967 proxy.
contract UpgradeableTokenTest is Test {
    CampusTokenUpgradeable internal implV1;
    CampusTokenV2 internal implV2;
    SafeProxy internal proxy;
    CampusTokenUpgradeable internal token; // the proxy, seen through V1's ABI

    address internal proxyAdmin = makeAddr("proxyAdmin");
    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal minter = makeAddr("minter");
    address internal owner;
    uint256 internal ownerKey;

    uint256 internal constant CAP = 1_000_000 ether;

    function setUp() public {
        (owner, ownerKey) = makeAddrAndKey("permitOwner");
        implV1 = new CampusTokenUpgradeable();
        implV2 = new CampusTokenV2();
        bytes memory init = abi.encodeCall(
            CampusTokenUpgradeable.initialize, ("Campus Token", "CMPS", CAP, admin, treasury)
        );
        proxy = new SafeProxyWithInit(address(implV1), proxyAdmin, init);
        token = CampusTokenUpgradeable(payable(address(proxy)));
    }

    /// @dev Some of everything: balances, an allowance, a permit (nonce), an
    ///      extra role, a fee, a claim.
    function _populate() internal {
        bytes32 minterRole = token.MINTER_ROLE();
        vm.startPrank(admin);
        token.mint(alice, 1000 ether);
        token.mint(owner, 500 ether);
        token.grantRole(minterRole, minter);
        token.setFeeBps(100);
        vm.stopPrank();

        vm.prank(alice);
        token.transfer(bob, 100 ether); // bob 99, treasury 1
        vm.prank(alice);
        token.approve(bob, 42 ether);

        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, _digest(owner, bob, 7 ether, 0, deadline));
        token.permit(owner, bob, 7 ether, deadline, v, r, s);

        bytes32 leafA = token.leafFor(alice, 5 ether);
        bytes32 leafB = token.leafFor(bob, 6 ether);
        vm.prank(admin);
        token.setClaimRoot(leafA < leafB ? keccak256(abi.encode(leafA, leafB)) : keccak256(abi.encode(leafB, leafA)));
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leafB;
        vm.prank(alice);
        token.claim(5 ether, proof);
    }

    function _digest(address o, address sp, uint256 value, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash =
            keccak256(abi.encode(token.PERMIT_TYPEHASH(), o, sp, value, nonce, deadline));
        return keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
    }

    // ------------------------------------------------------------ the proxy

    function test_ProxyIsInitialised() public view {
        assertEq(token.name(), "Campus Token");
        assertEq(token.symbol(), "CMPS");
        assertEq(token.cap(), CAP);
        assertEq(token.treasury(), treasury);
        assertEq(token.version(), 1);
        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), admin));
        assertFalse(token.hasRole(token.DEFAULT_ADMIN_ROLE(), address(this)));
        assertEq(proxy.implementation(), address(implV1));
        assertEq(proxy.admin(), proxyAdmin);
    }

    function test_RevertWhen_InitializedTwice() public {
        vm.expectRevert(CampusTokenUpgradeable.AlreadyInitialized.selector);
        token.initialize("Evil", "EVL", CAP, alice, alice);
    }

    function test_RevertWhen_ImplementationIsInitializedDirectly() public {
        vm.expectRevert(CampusTokenUpgradeable.AlreadyInitialized.selector);
        implV1.initialize("Evil", "EVL", CAP, alice, alice);
    }

    function test_RevertWhen_InitializedWithZeroCap() public {
        bytes memory init = abi.encodeCall(
            CampusTokenUpgradeable.initialize, ("X", "X", 0, admin, treasury)
        );
        vm.expectRevert(CampusToken.ZeroCap.selector);
        new SafeProxyWithInit(address(implV1), proxyAdmin, init);
    }

    function test_CapIsEnforcedThroughTheProxy() public {
        vm.expectRevert(abi.encodeWithSelector(CampusToken.CapExceeded.selector, CAP + 1, CAP));
        vm.prank(admin);
        token.mint(alice, CAP + 1);
    }

    /// @notice The domain separator belongs to the proxy (its address, its
    ///         name), not to the implementation.
    function test_DomainSeparatorUsesTheProxyAddress() public view {
        bytes32 expected = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256("Campus Token"),
                keccak256("1"),
                block.chainid,
                address(proxy)
            )
        );
        assertEq(token.DOMAIN_SEPARATOR(), expected);
    }

    // -------------------------------------------------------------- upgrade

    function test_UpgradeKeepsAllState() public {
        _populate();

        uint256[6] memory balancesBefore = [
            token.balanceOf(alice),
            token.balanceOf(bob),
            token.balanceOf(owner),
            token.balanceOf(treasury),
            token.totalSupply(),
            token.feeBps()
        ];
        bytes32 separatorBefore = token.DOMAIN_SEPARATOR();

        vm.prank(proxyAdmin);
        proxy.upgradeTo(address(implV2));
        CampusTokenV2 v2 = CampusTokenV2(payable(address(proxy)));

        assertEq(v2.version(), 2, "new code");
        assertEq(proxy.implementation(), address(implV2));
        // balances and supply
        assertEq(v2.balanceOf(alice), balancesBefore[0]);
        assertEq(v2.balanceOf(bob), balancesBefore[1]);
        assertEq(v2.balanceOf(owner), balancesBefore[2]);
        assertEq(v2.balanceOf(treasury), balancesBefore[3]);
        assertEq(v2.totalSupply(), balancesBefore[4]);
        assertEq(v2.totalSupply(), 1505 ether);
        // allowances: the approve and the permit
        assertEq(v2.allowance(alice, bob), 42 ether);
        assertEq(v2.allowance(owner, bob), 7 ether);
        // nonces
        assertEq(v2.nonces(owner), 1);
        // roles
        assertTrue(v2.hasRole(v2.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(v2.hasRole(v2.MINTER_ROLE(), minter));
        assertFalse(v2.hasRole(v2.MINTER_ROLE(), alice));
        // configuration and claims
        assertEq(v2.feeBps(), balancesBefore[5]);
        assertEq(v2.treasury(), treasury);
        assertEq(v2.cap(), CAP);
        assertTrue(v2.hasClaimed(alice));
        assertEq(v2.name(), "Campus Token");
        assertEq(v2.DOMAIN_SEPARATOR(), separatorBefore);
        assertEq(v2.maxTransfer(), 0, "the new variable starts empty");

        // the old nonce continues: a permit signed for nonce 1 works now
        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, _digest(owner, alice, 3 ether, 1, deadline));
        v2.permit(owner, alice, 3 ether, deadline, v, r, s);
        assertEq(v2.nonces(owner), 2);

        // and the second initialize is still refused after the upgrade
        vm.expectRevert(CampusTokenUpgradeable.AlreadyInitialized.selector);
        v2.initialize("Evil", "EVL", CAP, alice, alice);
    }

    function test_V2NewFunction() public {
        _populate();
        vm.prank(proxyAdmin);
        proxy.upgradeTo(address(implV2));
        CampusTokenV2 v2 = CampusTokenV2(payable(address(proxy)));

        vm.prank(admin);
        v2.setMaxTransfer(50 ether);
        assertEq(v2.maxTransfer(), 50 ether);

        vm.expectRevert(abi.encodeWithSelector(CampusTokenV2.TransferTooLarge.selector, 51 ether, 50 ether));
        vm.prank(alice);
        v2.transfer(bob, 51 ether);

        vm.prank(alice);
        v2.transfer(bob, 50 ether);

        // minting is not a transfer and is not limited
        vm.prank(admin);
        v2.mint(bob, 100 ether);

        // the new function is role-protected like the old configuration
        bytes32 configRole = v2.CONFIG_ROLE();
        vm.expectRevert(abi.encodeWithSelector(AccessControl.MissingRole.selector, configRole, alice));
        vm.prank(alice);
        v2.setMaxTransfer(0);
    }

    function test_RevertWhen_UpgradeByNonAdmin() public {
        vm.expectRevert(SafeProxy.NotAdmin.selector);
        vm.prank(admin); // even the token's admin is not the proxy's admin
        proxy.upgradeTo(address(implV2));
    }

    /// @notice ETH sent to the proxy is forwarded to the token, which has no
    ///         receive function, so it is refused instead of locked.
    function test_ProxyRefusesPlainEth() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(proxy).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(address(proxy).balance, 0);
    }

    function test_RevertWhen_UpgradeToNonContract() public {
        vm.expectRevert(SafeProxy.NotAContract.selector);
        vm.prank(proxyAdmin);
        proxy.upgradeTo(alice);
    }

    /// @notice The layout claim of E4, checked on the live proxy: the cap is in
    ///         slot 11 and V2's new variable lands in slot 61, after V1's gap.
    function test_V2AppendsItsVariable() public {
        assertEq(uint256(vm.load(address(proxy), bytes32(uint256(11)))), CAP, "V1 _storedCap");
        vm.prank(proxyAdmin);
        proxy.upgradeTo(address(implV2));
        vm.prank(admin);
        CampusTokenV2(payable(address(proxy))).setMaxTransfer(777);
        assertEq(uint256(vm.load(address(proxy), bytes32(uint256(61)))), 777, "V2 maxTransfer");
        assertEq(uint256(vm.load(address(proxy), bytes32(uint256(11)))), CAP, "unchanged");
    }

    /// @notice What happens if V2 puts its variable FIRST: every old slot is
    ///         read one position too far. The balances mapping is now looked up
    ///         at slot 1 (where the allowances were), so every balance reads as
    ///         zero, the role table is read from the wrong slot, and cap() reads
    ///         slot 12, which used to be the `_initialized` flag.
    function test_PrependingAVariableCorruptsEverything() public {
        _populate();
        uint256 supplyBefore = token.totalSupply();
        CampusTokenV2Wrong wrong = new CampusTokenV2Wrong();

        vm.prank(proxyAdmin);
        proxy.upgradeTo(address(wrong));
        CampusTokenV2Wrong w = CampusTokenV2Wrong(payable(address(proxy)));

        assertEq(w.balanceOf(alice), 0, "alice's balance is gone");
        assertTrue(w.totalSupply() != supplyBefore, "totalSupply now reads slot 3, the old _name");
        assertFalse(w.hasRole(w.DEFAULT_ADMIN_ROLE(), admin), "the admin lost the role");
        assertEq(w.cap(), 1, "the cap now reads the old _initialized flag: a cap of 1 wei");
        vm.expectRevert(); // CapExceeded: no minting is possible any more
        vm.prank(admin);
        w.mint(alice, 1);
    }
}
