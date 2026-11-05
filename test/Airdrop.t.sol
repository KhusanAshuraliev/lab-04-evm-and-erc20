// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {CampusToken} from "../src/CampusToken.sol";

/// @notice The mapping alternative to the Merkle root, for the gas comparison of
///         deliverable 5: the deployer writes one allocation per recipient.
contract MappingAllowlist {
    mapping(address account => uint256) public allocation;
    CampusToken public immutable token;

    constructor(CampusToken token_) {
        token = token_;
    }

    function setMany(address[] calldata accounts, uint256[] calldata amounts) external {
        for (uint256 i = 0; i < accounts.length; i++) {
            allocation[accounts[i]] = amounts[i];
        }
    }

    /// @dev For the claimant's side: read the allocation, clear it, mint.
    function claim() external {
        uint256 amount = allocation[msg.sender];
        require(amount != 0, "nothing to claim");
        allocation[msg.sender] = 0;
        token.mint(msg.sender, amount);
    }
}

/// @notice Bonus E2 and deliverable 5. The proofs come from airdrop/merkle.py.
contract AirdropTest is Test {
    CampusToken internal token;
    address internal admin = makeAddr("admin");
    // The 11.5 MB JSON is read into memory in each test, never into storage.
    bytes32 internal root;
    uint256 internal count;

    function setUp() public {
        string memory json = vm.readFile("airdrop/proofs.json");
        root = vm.parseJsonBytes32(json, ".root");
        count = vm.parseJsonUint(json, ".count");
        token = new CampusToken("Campus Token", "CMPS", 10_000_000 ether, admin, makeAddr("treasury"));
        vm.prank(admin);
        token.setClaimRoot(root);
    }

    function _entry(string memory json, uint256 i)
        internal
        pure
        returns (address account, uint256 amount, bytes32 leaf, bytes32[] memory proof)
    {
        string memory p = string.concat(".claims[", vm.toString(i), "]");
        account = vm.parseJsonAddress(json, string.concat(p, ".account"));
        amount = vm.parseJsonUint(json, string.concat(p, ".amount"));
        leaf = vm.parseJsonBytes32(json, string.concat(p, ".leaf"));
        proof = vm.parseJsonBytes32Array(json, string.concat(p, ".proof"));
    }

    function _claim(string memory json, uint256 i) internal returns (uint256 gasUsed) {
        (address account, uint256 amount, bytes32 leaf, bytes32[] memory proof) = _entry(json, i);
        assertEq(proof.length, 14, "ceil(log2 10000) = 14");
        assertEq(token.leafFor(account, amount), leaf, "python and solidity agree on the leaf");

        vm.prank(account);
        uint256 g = gasleft();
        token.claim(amount, proof);
        gasUsed = g - gasleft();

        assertEq(token.balanceOf(account), amount);
        assertTrue(token.hasClaimed(account));
        console2.log("claim index", i, "gas", gasUsed);
    }

    function test_ClaimFirstLastAndRandom() public {
        string memory json = vm.readFile("airdrop/proofs.json");
        assertEq(count, 10_000);
        uint256 random = uint256(keccak256("lab04-random-pick")) % count;
        console2.log("random index:", random);

        _claim(json, 0);
        _claim(json, count - 1);
        _claim(json, random);
        assertEq(
            token.totalSupply(), _amount(json, 0) + _amount(json, count - 1) + _amount(json, random)
        );
    }

    function _amount(string memory json, uint256 i) internal pure returns (uint256) {
        return vm.parseJsonUint(json, string.concat(".claims[", vm.toString(i), "].amount"));
    }

    /// @notice A real proof cannot be reused, nor used by another account, nor
    ///         with a different amount.
    function test_RealProofGuards() public {
        string memory json = vm.readFile("airdrop/proofs.json");
        (address account, uint256 amount,, bytes32[] memory proof) = _entry(json, 1234);

        vm.expectRevert(CampusToken.InvalidMerkleProof.selector);
        vm.prank(account);
        token.claim(amount + 1, proof);

        vm.expectRevert(CampusToken.InvalidMerkleProof.selector);
        vm.prank(makeAddr("thief"));
        token.claim(amount, proof);

        vm.prank(account);
        token.claim(amount, proof);
        vm.expectRevert(abi.encodeWithSelector(CampusToken.AlreadyClaimed.selector, account));
        vm.prank(account);
        token.claim(amount, proof);
    }

    /// @notice The deployer's side of the Merkle approach, measured in a test
    ///         of its own so that no large memory of the test inflates it.
    function test_GasMerkleRoot() public {
        CampusToken fresh =
            new CampusToken("Campus Token", "CMPS", 10_000_000 ether, admin, makeAddr("treasury"));
        bytes32 r = root;
        vm.prank(admin);
        uint256 g = gasleft();
        fresh.setClaimRoot(r);
        uint256 rootGas = g - gasleft();
        // Foundry 1.9 runs each external call of a test as its own transaction
        // (isolate = true), so the figure includes the 21,000 base cost.
        console2.log("merkle root, deployer gas (whole tx):", rootGas);
        console2.log("  without the 21,000 base cost:      ", rootGas - 21_000);
        assertLt(rootGas - 21_000, 30_000);
    }

    /// @notice Deliverable 5, measured. The mapping needs one zero-to-nonzero
    ///         SSTORE per recipient, paid by the deployer; the Merkle root needs
    ///         one SSTORE in total.
    function test_GasMappingVersusMerkle() public {
        address[] memory accounts = new address[](count);
        uint256[] memory amounts = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            accounts[i] = address(uint160(uint256(keccak256(abi.encode("recipient", i)))));
            amounts[i] = 1 ether + i;
        }

        MappingAllowlist list = new MappingAllowlist(token);
        uint256 g = gasleft();
        list.setMany(accounts, amounts);
        uint256 mappingGas = g - gasleft();

        console2.log("mapping, 10,000 entries, deployer gas:", mappingGas);
        console2.log("  per entry:                          ", mappingGas / count);
        console2.log("  blocks of 30M gas needed:           ", mappingGas / 30_000_000 + 1);
        assertGt(mappingGas, 7 * 30_000_000, "more than seven full blocks");

        // the claimant's side of the mapping approach
        bytes32 minterRole = token.MINTER_ROLE();
        vm.prank(admin);
        token.grantRole(minterRole, address(list));
        vm.prank(accounts[0]);
        g = gasleft();
        list.claim();
        console2.log("mapping claim, claimant gas:          ", g - gasleft());
    }
}
