// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {CampusToken} from "../src/CampusToken.sol";

/// @title CampusTokenHandler
/// @notice The action surface the invariant fuzzer is allowed to drive.
/// @dev A handler exists because unguided fuzzing wastes almost every call on
///      reverts -- random addresses with no balance, amounts beyond any
///      holding. Bounding the actors and the amounts means the fuzzer explores
///      *sequences that actually execute*, which is where interaction bugs live.
contract CampusTokenHandler is Test {
    CampusToken public token;
    address public admin;
    address public treasury;
    address[] public actors;

    /// @dev Ghost variable: an independent running total the contract does not
    ///      maintain. Comparing a ghost against contract state is what turns an
    ///      invariant test from "nothing reverted" into a real property check.
    uint256 public ghostMinted;
    uint256 public ghostBurned;

    constructor(CampusToken token_, address admin_, address treasury_, address[] memory actors_) {
        token = token_;
        admin = admin_;
        treasury = treasury_;
        actors = actors_;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, token.balanceOf(from));

        vm.prank(from);
        token.transfer(to, amount);
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        amount = bound(amount, 0, token.balanceOf(owner));

        vm.prank(owner);
        token.approve(spender, amount);

        vm.prank(spender);
        token.transferFrom(owner, spender, amount);
    }

    function mint(uint256 toSeed, uint256 amount) external {
        address to = _actor(toSeed);
        uint256 headroom = token.cap() - token.totalSupply();
        amount = bound(amount, 0, headroom);

        vm.prank(admin);
        token.mint(to, amount);
        ghostMinted += amount;
    }

    function burn(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        amount = bound(amount, 0, token.balanceOf(actor));

        vm.prank(actor);
        token.burn(amount);
        ghostBurned += amount;
    }

    function setFee(uint16 feeBps) external {
        feeBps = uint16(bound(feeBps, 0, token.MAX_FEE_BPS()));
        vm.prank(admin);
        token.setFeeBps(feeBps);
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }
}

/// @title CampusTokenInvariantTest
/// @notice Properties that must hold after ANY sequence of allowed calls.
/// @dev Unit tests check the cases a developer thought of. Invariant tests
///      generate call sequences nobody thought of and check that stated
///      properties survive them. For anything holding value this is the single
///      highest-value testing technique available.
contract CampusTokenInvariantTest is Test {
    CampusToken internal token;
    CampusTokenHandler internal handler;

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");

    uint256 internal constant CAP = 1_000_000 ether;

    function setUp() public {
        token = new CampusToken("Campus Token", "CMPS", CAP, admin, treasury);

        address[] memory actors = new address[](4);
        actors[0] = makeAddr("a0");
        actors[1] = makeAddr("a1");
        actors[2] = makeAddr("a2");
        actors[3] = treasury;

        vm.startPrank(admin);
        token.mint(actors[0], 10_000 ether);
        token.mint(actors[1], 5_000 ether);
        vm.stopPrank();

        handler = new CampusTokenHandler(token, admin, treasury, actors);

        // Restrict fuzzing to the handler; without this the fuzzer would call
        // the token directly with random senders and almost always revert.
        targetContract(address(handler));
    }

    /// @notice The fundamental token invariant: no value is created or destroyed.
    /// @dev If this ever fails, the accounting is broken somewhere -- typically
    ///      in a fee, rebase or rounding path. It is the first invariant to
    ///      write for any token and the one that catches the most.
    function invariant_SumOfBalancesEqualsTotalSupply() public view {
        uint256 sum = 0;
        uint256 n = handler.actorCount();
        for (uint256 i = 0; i < n; i++) {
            sum += token.balanceOf(handler.actorAt(i));
        }
        assertEq(sum, token.totalSupply(), "balances must sum to total supply");
    }

    /// @notice The cap is a hard bound, not a guideline.
    function invariant_TotalSupplyNeverExceedsCap() public view {
        assertLe(token.totalSupply(), token.cap());
    }

    /// @notice Total supply is reconstructible from mint and burn history alone.
    /// @dev A fee must REDISTRIBUTE, never create or destroy. If this fails, the
    ///      fee path is minting or burning by accident -- a classic bug in
    ///      fee-on-transfer tokens.
    function invariant_SupplyMatchesMintMinusBurn() public view {
        assertEq(
            token.totalSupply(),
            15_000 ether + handler.ghostMinted() - handler.ghostBurned(),
            "the fee must move value, not create it"
        );
    }

    /// @notice A configured fee can never exceed the immutable ceiling.
    function invariant_FeeStaysWithinTheHardLimit() public view {
        assertLe(token.feeBps(), token.MAX_FEE_BPS());
    }
}
