// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BrokenProxy, LogicV1, LogicV2, SafeProxy} from "../src/evm/Proxy.sol";

/// @notice My additions to the course's ProxyTest.
contract ProxyExtraTest is Test {
    LogicV1 internal v1 = new LogicV1();
    LogicV2 internal v2 = new LogicV2();
    address internal admin = makeAddr("proxyAdmin");

    /// @notice The silent failure in numbers: after the collision a call to
    ///         value() succeeds and returns ZERO bytes, and a write "succeeds"
    ///         without writing anything.
    function test_BrokenProxyReturnsNothingAfterCollision() public {
        BrokenProxy proxy = new BrokenProxy(address(v1));
        LogicV1(address(proxy)).setValue(0xDEAD);

        (bool ok, bytes memory ret) = address(proxy).call(abi.encodeWithSignature("value()"));
        assertTrue(ok, "no revert");
        assertEq(ret.length, 0, "and no return data");

        (ok,) = address(proxy).call(abi.encodeCall(LogicV1.setValue, (1)));
        assertTrue(ok, "a write also 'succeeds'");
        assertEq(uint256(vm.load(address(proxy), 0)), 0xDEAD, "but nothing was written");
    }

    function test_RevertWhen_SafeProxyDeployedWithoutCode() public {
        vm.expectRevert(SafeProxy.NotAContract.selector);
        new SafeProxy(address(0xBEEF), admin);
    }

    function test_EIP1967AdminSlot() public {
        SafeProxy proxy = new SafeProxy(address(v1), admin);
        bytes32 adminSlot = bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);
        assertEq(adminSlot, 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103);
        assertEq(address(uint160(uint256(vm.load(address(proxy), adminSlot)))), admin);
        assertEq(proxy.admin(), admin);
    }

    function test_V2SetValueAfterUpgrade() public {
        SafeProxy proxy = new SafeProxy(address(v1), admin);
        vm.prank(admin);
        proxy.upgradeTo(address(v2));
        LogicV2(address(proxy)).setValue(5);
        assertEq(LogicV2(address(proxy)).value(), 5);
        assertEq(uint256(vm.load(address(proxy), 0)), 5, "slot 0 of the proxy");
    }
}
