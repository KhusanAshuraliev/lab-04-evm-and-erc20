// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {CampusToken} from "../src/CampusToken.sol";

/// @notice My invariant handler. Unlike the course's handler it also drives
///         permit, claim and setTreasury, and it keeps a MODEL of every balance:
///         its own copy, updated with my own fee arithmetic. The invariants then
///         compare the token with the model after every call sequence.
contract ModelHandler is Test {
    CampusToken public token;
    address public admin;

    address[] internal actors;
    uint256[] internal keys;

    mapping(address => uint256) public model;
    mapping(address => uint256) public permitsUsed;
    mapping(address => bool) public claimed;
    uint256 public minted;
    uint256 public burned;
    uint256 public calls;

    // a 4-leaf allowlist over actors 0..3
    bytes32 public root;
    bytes32[4] internal leaves;
    uint256[4] internal claimAmounts = [uint256(11 ether), 22 ether, 33 ether, 44 ether];

    constructor(CampusToken token_, address admin_) {
        token = token_;
        admin = admin_;
        for (uint256 i = 0; i < 5; i++) {
            (address a, uint256 k) = makeAddrAndKey(string(abi.encodePacked("actor", vm.toString(i))));
            actors.push(a);
            keys.push(k);
        }
        for (uint256 i = 0; i < 4; i++) {
            leaves[i] = token.leafFor(actors[i], claimAmounts[i]);
        }
        root = _pair(_pair(leaves[0], leaves[1]), _pair(leaves[2], leaves[3]));
    }

    function _pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }

    /// @dev my model of a transfer, independent of the token's code
    function _move(address from, address to, uint256 amount) internal {
        address t = token.treasury();
        uint256 fee = (from == t || to == t) ? 0 : amount * token.feeBps() / 10_000;
        model[from] -= amount;
        model[to] += amount - fee;
        model[t] += fee;
    }

    // ------------------------------------------------------------ actions

    function seedBalances() external {
        // called once by setUp through the handler, so the model starts equal
        for (uint256 i = 0; i < 4; i++) {
            vm.prank(admin);
            token.mint(actors[i], (i + 1) * 1000 ether);
            model[actors[i]] += (i + 1) * 1000 ether;
            minted += (i + 1) * 1000 ether;
        }
        vm.prank(admin);
        token.setClaimRoot(root);
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        calls++;
        address from = actors[fromSeed % 5];
        address to = actors[toSeed % 5];
        amount = bound(amount, 0, token.balanceOf(from));
        vm.prank(from);
        token.transfer(to, amount);
        _move(from, to, amount);
    }

    function transferFromPartial(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, uint256 extra)
        external
    {
        calls++;
        address owner = actors[ownerSeed % 5];
        address spender = actors[spenderSeed % 5];
        amount = bound(amount, 0, token.balanceOf(owner));
        extra = bound(extra, 0, 1000 ether);
        vm.prank(owner);
        token.approve(spender, amount + extra);
        vm.prank(spender);
        token.transferFrom(owner, spender, amount);
        _move(owner, spender, amount);
        assertEq(token.allowance(owner, spender), extra, "allowance left = approved - spent");
    }

    function permitAndSpend(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        calls++;
        uint256 i = ownerSeed % 5;
        address owner = actors[i];
        address spender = actors[spenderSeed % 5];
        if (spender == owner) spender = actors[(i + 1) % 5];
        amount = bound(amount, 0, token.balanceOf(owner));
        uint256 nonce = token.nonces(owner);
        uint256 deadline = block.timestamp + 1;
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                token.DOMAIN_SEPARATOR(),
                keccak256(abi.encode(token.PERMIT_TYPEHASH(), owner, spender, amount, nonce, deadline))
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(keys[i], digest);
        token.permit(owner, spender, amount, deadline, v, r, s);
        permitsUsed[owner]++;

        vm.prank(spender);
        token.transferFrom(owner, spender, amount);
        _move(owner, spender, amount);
    }

    function mint(uint256 toSeed, uint256 amount) external {
        calls++;
        address to = actors[toSeed % 5];
        amount = bound(amount, 0, token.cap() - token.totalSupply());
        vm.prank(admin);
        token.mint(to, amount);
        model[to] += amount;
        minted += amount;
    }

    function burn(uint256 seed, uint256 amount) external {
        calls++;
        address a = actors[seed % 5];
        amount = bound(amount, 0, token.balanceOf(a));
        vm.prank(a);
        token.burn(amount);
        model[a] -= amount;
        burned += amount;
    }

    function claim(uint256 seed) external {
        calls++;
        uint256 i = seed % 4;
        address a = actors[i];
        if (claimed[a] || token.totalSupply() + claimAmounts[i] > token.cap()) return;
        bytes32[] memory proof = new bytes32[](2);
        proof[0] = leaves[i ^ 1];
        proof[1] = i < 2 ? _pair(leaves[2], leaves[3]) : _pair(leaves[0], leaves[1]);
        vm.prank(a);
        token.claim(claimAmounts[i], proof);
        claimed[a] = true;
        model[a] += claimAmounts[i];
        minted += claimAmounts[i];
    }

    function setFee(uint16 bps) external {
        calls++;
        bps = uint16(bound(bps, 0, token.MAX_FEE_BPS()));
        vm.prank(admin);
        token.setFeeBps(bps);
    }

    function moveTreasury(uint256 seed) external {
        calls++;
        vm.prank(admin);
        token.setTreasury(actors[seed % 5]);
    }
}

contract CampusTokenModelTest is Test {
    CampusToken internal token;
    ModelHandler internal handler;
    address internal admin = makeAddr("admin");

    uint256 internal constant CAP = 100_000 ether;

    function setUp() public {
        token = new CampusToken("Campus Token", "CMPS", CAP, admin, makeAddr("initialTreasury"));
        handler = new ModelHandler(token, admin);
        handler.seedBalances();
        address treasury = handler.actorAt(4); // resolved before the prank
        vm.prank(admin);
        token.setTreasury(treasury);

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = ModelHandler.transfer.selector;
        selectors[1] = ModelHandler.transferFromPartial.selector;
        selectors[2] = ModelHandler.permitAndSpend.selector;
        selectors[3] = ModelHandler.mint.selector;
        selectors[4] = ModelHandler.burn.selector;
        selectors[5] = ModelHandler.claim.selector;
        selectors[6] = ModelHandler.setFee.selector;
        selectors[7] = ModelHandler.moveTreasury.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @notice Every balance equals my independent model of it.
    function invariant_BalancesMatchTheModel() public view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address a = handler.actorAt(i);
            assertEq(token.balanceOf(a), handler.model(a), "balance differs from the model");
        }
    }

    /// @notice Sum of the balances = total supply (all holders are actors).
    function invariant_SumOfBalancesIsSupply() public view {
        uint256 sum;
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            sum += token.balanceOf(handler.actorAt(i));
        }
        assertEq(sum, token.totalSupply());
    }

    /// @notice Total supply = everything minted (mint + claim) - everything burned.
    function invariant_SupplyIsMintedMinusBurned() public view {
        assertEq(token.totalSupply(), handler.minted() - handler.burned());
    }

    function invariant_SupplyWithinCap() public view {
        assertLe(token.totalSupply(), token.cap());
    }

    function invariant_FeeWithinLimit() public view {
        assertLe(token.feeBps(), token.MAX_FEE_BPS());
    }

    /// @notice A nonce counts exactly the permits that were used, and a claim
    ///         is recorded exactly for the accounts that claimed.
    function invariant_NoncesAndClaimsAreExact() public view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address a = handler.actorAt(i);
            assertEq(token.nonces(a), handler.permitsUsed(a));
            assertEq(token.hasClaimed(a), handler.claimed(a));
        }
    }
}
