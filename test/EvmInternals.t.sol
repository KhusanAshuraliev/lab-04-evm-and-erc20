// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {
    BrokenProxy,
    DerivedV1,
    LogicV1,
    LogicV2,
    SafeProxy
} from "../src/evm/Proxy.sol";
import {PackingBadOrder, PackingGoodOrder, StorageLayout} from "../src/evm/StorageLayout.sol";
import {YulCounter} from "../src/evm/YulCounter.sol";

// ========================================================================= //
// Part A -- storage layout
// ========================================================================= //

contract StorageLayoutTest is Test {
    StorageLayout internal s;

    function setUp() public {
        s = new StorageLayout(777);
    }

    /// @notice Three small variables share one 32-byte word.
    /// @dev The compiler fills a slot from the RIGHT (least significant byte
    ///      first), so packedA occupies bytes 0..15, packedB 16..23 and
    ///      packedC byte 24, all within slot 0.
    function test_VariablesArePackedIntoOneSlot() public {
        s.setPacked(type(uint128).max, 0xAABBCCDDEEFF0011, 0x42);

        uint256 slot0 = uint256(vm.load(address(s), bytes32(uint256(0))));

        assertEq(uint128(slot0), type(uint128).max, "packedA at offset 0");
        assertEq(uint64(slot0 >> 128), 0xAABBCCDDEEFF0011, "packedB at offset 16");
        assertEq(uint8(slot0 >> 192), 0x42, "packedC at offset 24");
    }

    function test_FullWordTakesItsOwnSlot() public {
        s.setWide(12345);
        assertEq(uint256(vm.load(address(s), bytes32(uint256(1)))), 12345);
    }

    function test_AddressAndBoolShareASlot() public {
        s.setOwnerAndFlag(address(0xBEEF), true);
        uint256 slot2 = uint256(vm.load(address(s), bytes32(uint256(2))));
        assertEq(address(uint160(slot2)), address(0xBEEF));
        assertEq(uint8(slot2 >> 160), 1, "bool packed directly after the address");
    }

    /// @notice A mapping's declared slot holds nothing; entries are hashed.
    function test_MappingSlotArithmetic() public {
        address key = address(0xCAFE);
        s.setBalance(key, 999);

        assertEq(
            uint256(vm.load(address(s), bytes32(uint256(3)))),
            0,
            "the declared slot of a mapping stays empty"
        );

        bytes32 expected = keccak256(abi.encode(key, uint256(3)));
        assertEq(expected, s.mappingSlot(key));
        assertEq(uint256(vm.load(address(s), expected)), 999);
    }

    /// @notice This is why a mapping cannot be enumerated.
    /// @dev Slots are reachable only by computing keccak256(key, slot). Without
    ///      the key there is nothing to compute, and the EVM offers no way to
    ///      iterate storage. An enumerable mapping needs a parallel array.
    function test_MappingIsNotEnumerable() public {
        s.setBalance(address(0x1111), 1);
        s.setBalance(address(0x2222), 2);
        // Nothing in slot 3 records that two keys exist.
        assertEq(uint256(vm.load(address(s), bytes32(uint256(3)))), 0);
    }

    /// @notice A dynamic array stores its length in place and data at keccak(slot).
    function test_DynamicArrayLayout() public {
        s.pushValue(11);
        s.pushValue(22);

        assertEq(uint256(vm.load(address(s), bytes32(uint256(4)))), 2, "length in the declared slot");

        bytes32 dataSlot = keccak256(abi.encode(uint256(4)));
        assertEq(uint256(vm.load(address(s), dataSlot)), 11);
        assertEq(uint256(vm.load(address(s), bytes32(uint256(dataSlot) + 1))), 22);
        assertEq(s.arrayDataSlot(1), bytes32(uint256(dataSlot) + 1));
    }

    function test_NestedMappingAppliesTheRuleRecursively() public {
        address owner = address(0xA);
        address spender = address(0xB);
        s.setAllowance(owner, spender, 4242);

        bytes32 expected =
            keccak256(abi.encode(spender, keccak256(abi.encode(owner, uint256(5)))));
        assertEq(expected, s.nestedMappingSlot(owner, spender));
        assertEq(uint256(vm.load(address(s), expected)), 4242);
    }

    /// @notice `private` is a compile-time visibility rule, not confidentiality.
    /// @dev There is no getter for `_notReallySecret`, yet the value is trivially
    ///      readable -- here with `vm.load`, and in production with a single
    ///      `eth_getStorageAt` RPC call against any public node. Anyone who puts
    ///      a password, a seed or an unrevealed commitment in a private variable
    ///      has published it.
    function test_PrivateStorageIsPubliclyReadable() public {
        s.stashSecret(0xC0FFEE);
        assertEq(uint256(vm.load(address(s), bytes32(uint256(6)))), 0xC0FFEE);
        assertEq(uint256(s.readSlot(6)), 0xC0FFEE);
    }

    /// @notice `constant` and `immutable` occupy no storage at all.
    /// @dev A constant is inlined into the bytecode at each use; an immutable is
    ///      written into the deployed code at construction. Reading either costs
    ///      3 gas rather than the 2,100 of a cold SLOAD.
    function test_ConstantAndImmutableUseNoSlots() public view {
        assertEq(s.CONSTANT_VALUE(), 42);
        assertEq(s.IMMUTABLE_VALUE(), 777);
        // Slot 7 onwards was never allocated: the two values live in code.
        assertEq(uint256(vm.load(address(s), bytes32(uint256(7)))), 0);
    }

    /// @notice Declaration order changes the number of slots, and therefore gas.
    /// @dev Both sides make exactly ONE external call writing all four fields,
    ///      so the only variable that differs is slot count: two for the
    ///      interleaved order, three for the grouped-by-type order. See the
    ///      contract-level comment on `PackingGoodOrder`/`PackingBadOrder` for
    ///      why these specific sizes (24 and 8 bytes) are what make the
    ///      difference provable rather than merely plausible.
    function test_PackingOrderAffectsGasCost() public {
        PackingGoodOrder good = new PackingGoodOrder();
        PackingBadOrder bad = new PackingBadOrder();

        uint256 g0 = gasleft();
        bad.setAll(1, 2, 3, 4);
        uint256 badGas = g0 - gasleft();

        g0 = gasleft();
        good.setAll(1, 2, 3, 4);
        uint256 goodGas = g0 - gasleft();

        console2.log("bad order gas  (3 slots):", badGas);
        console2.log("good order gas (2 slots):", goodGas);
        assertLt(goodGas, badGas, "interleaving by size is free optimisation");
        // The gap should be close to one full zero-to-nonzero SSTORE (22,100
        // gas): exactly one extra slot is genuinely, unavoidably touched.
        assertApproxEqAbs(badGas - goodGas, 22_100, 3_000);
    }
}

// ========================================================================= //
// Part B -- Yul
// ========================================================================= //

contract YulCounterTest is Test {
    YulCounter internal c;

    function setUp() public {
        c = new YulCounter();
    }

    function test_BothIncrementsAgree() public {
        c.incrementSolidity();
        assertEq(c.counter(), 1);
        c.incrementYul();
        assertEq(c.counter(), 2);
    }

    function test_YulIncrementIsCheaper() public {
        c.incrementSolidity(); // warm the slot so the comparison is fair

        uint256 g0 = gasleft();
        c.incrementSolidity();
        uint256 solidityGas = g0 - gasleft();

        g0 = gasleft();
        c.incrementYul();
        uint256 yulGas = g0 - gasleft();

        console2.log("solidity increment gas:", solidityGas);
        console2.log("yul increment gas:     ", yulGas);
        console2.log("saved:                 ", solidityGas - yulGas);
        assertLt(yulGas, solidityGas);
    }

    /// @notice Differential fuzzing: the assembly must equal the high-level version.
    /// @dev This is the discipline that makes assembly acceptable at all. Never
    ///      ship a hand-written implementation without proving equivalence to a
    ///      readable one across randomised inputs.
    function testFuzz_SumImplementationsAgree(uint128[] calldata raw) public view {
        uint256[] memory widened = new uint256[](raw.length);
        for (uint256 i = 0; i < raw.length; i++) {
            widened[i] = raw[i];
        }
        // uint128 inputs keep the total below 2^256 for any plausible length,
        // so the checked Solidity version cannot revert on overflow.
        assertEq(c.sumSolidity(widened), c.sumYul(widened));
    }

    function testFuzz_GuardImplementationsAgree(uint256 value) public {
        if (value > 1000) {
            vm.expectRevert(abi.encodeWithSelector(YulCounter.TooLarge.selector, value));
            c.guardSolidity(value);

            vm.expectRevert(abi.encodeWithSelector(YulCounter.TooLarge.selector, value));
            c.guardYul(value);
        } else {
            assertEq(c.guardSolidity(value), c.guardYul(value));
        }
    }

    /// @notice The hand-encoded revert must be decodable as the declared error.
    function test_YulRevertEncodesTheCustomError() public {
        vm.expectRevert(abi.encodeWithSelector(YulCounter.TooLarge.selector, uint256(5000)));
        c.guardYul(5000);
    }
}

// ========================================================================= //
// Part C -- proxies and storage collisions
// ========================================================================= //

contract ProxyTest is Test {
    LogicV1 internal logicV1;
    LogicV2 internal logicV2;
    address internal admin = makeAddr("proxyAdmin");

    function setUp() public {
        logicV1 = new LogicV1();
        logicV2 = new LogicV2();
    }

    /// @notice The Parity failure, reproduced.
    /// @dev BrokenProxy keeps `implementation` in slot 0 and LogicV1 keeps
    ///      `value` in slot 0. Because delegatecall runs the logic against the
    ///      PROXY's storage, setting the value overwrites the implementation
    ///      pointer.
    function test_BrokenProxyStorageCollision() public {
        BrokenProxy proxy = new BrokenProxy(address(logicV1));
        assertEq(proxy.implementation(), address(logicV1));

        // A perfectly ordinary call.
        LogicV1(address(proxy)).setValue(0xDEAD);

        // The implementation pointer is now the value that was written.
        assertEq(
            uint256(uint160(proxy.implementation())),
            0xDEAD,
            "setValue overwrote the implementation address"
        );
    }

    /// @notice And the failure is silent, which is what makes it lethal.
    /// @dev delegatecall to an address with NO CODE succeeds and returns empty
    ///      data. The proxy therefore does not revert; subsequent calls simply
    ///      do nothing, and the function that could repair the pointer is gone.
    function test_BrokenProxyFailsSilentlyAfterCollision() public {
        BrokenProxy proxy = new BrokenProxy(address(logicV1));
        LogicV1(address(proxy)).setValue(0xDEAD);

        // Slot 0 now holds 0xDEAD, an address with no code.
        assertEq(address(uint160(0xDEAD)).code.length, 0);

        // The call does not revert; the return data is empty, so decoding a
        // uint256 from nothing is what actually fails.
        (bool ok,) = address(proxy).call(abi.encodeWithSignature("value()"));
        assertTrue(ok, "delegatecall to a codeless address returns success");
    }

    function test_Eip1967SlotHasTheCanonicalValue() public pure {
        assertEq(
            bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1),
            0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc
        );
    }

    function test_SafeProxyAvoidsCollision() public {
        SafeProxy proxy = new SafeProxy(address(logicV1), admin);

        LogicV1(address(proxy)).setValue(0xDEAD);

        assertEq(proxy.implementation(), address(logicV1), "pointer survives writes to slot 0");
        assertEq(LogicV1(address(proxy)).value(), 0xDEAD, "and the value was stored");
    }

    /// @notice State lives in the proxy, so it survives an upgrade.
    function test_UpgradePreservesState() public {
        SafeProxy proxy = new SafeProxy(address(logicV1), admin);
        LogicV1(address(proxy)).setValue(21);
        assertEq(LogicV1(address(proxy)).version(), 1);

        vm.prank(admin);
        proxy.upgradeTo(address(logicV2));

        assertEq(LogicV2(address(proxy)).version(), 2, "new code");
        assertEq(LogicV2(address(proxy)).value(), 21, "old state");

        LogicV2(address(proxy)).setMultiplier(2);
        LogicV2(address(proxy)).applyMultiplier();
        assertEq(LogicV2(address(proxy)).value(), 42);
    }

    function test_RevertWhen_NonAdminUpgrades() public {
        SafeProxy proxy = new SafeProxy(address(logicV1), admin);
        vm.expectRevert(SafeProxy.NotAdmin.selector);
        proxy.upgradeTo(address(logicV2));
    }

    /// @notice Upgrading to an address with no code must revert, not brick.
    function test_RevertWhen_UpgradingToNonContract() public {
        SafeProxy proxy = new SafeProxy(address(logicV1), admin);
        vm.expectRevert(SafeProxy.NotAContract.selector);
        vm.prank(admin);
        proxy.upgradeTo(address(0xBEEF));
    }

    /// @notice A storage gap reserves room for the base contract to grow.
    function test_StorageGapReservesSlots() public {
        DerivedV1 d = new DerivedV1();
        d.setDerived(5);
        // baseValue is slot 0; __gap occupies slots 1..49; derivedValue is 50.
        assertEq(uint256(vm.load(address(d), bytes32(uint256(50)))), 5);
    }
}
