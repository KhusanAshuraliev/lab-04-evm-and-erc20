# lab-04-evm-and-erc20 — my Lab 04 implementation

This is my implementation for **OE Blockchain, Lab 04 (EVM internals, Merkle proofs and a production-grade ERC-20)**: a storage-layout specimen, Solidity-versus-Yul functions with differential fuzz tests, a proxy storage collision and its EIP-1967 fix, and `CampusToken`, a capped ERC-20 with roles, a transfer fee, EIP-2612 permit and a Merkle allowlist.

I wrote every contract myself. The only dependency is `forge-std` for the tests; I did not use OpenZeppelin, Solady or any other token library.

## Report

- [My Lab 04 report (PDF)](report/Lab04_Report_Khusanjon_Ashuraliev.pdf)
- [`evidence/`](evidence/) — the saved output of every test run, trace, gas report, `forge inspect`, coverage and Slither run quoted in the report

## Usage

```bash
git clone --recursive https://github.com/KhusanAshuraliev/lab-04-evm-and-erc20
cd lab-04-evm-and-erc20
forge build
forge test                                    # 131 passed
forge test --gas-report
forge coverage --no-match-coverage "test|script"
forge inspect CampusToken storageLayout
slither . --exclude-dependencies

uv run airdrop/merkle.py build airdrop/recipients.csv airdrop/proofs.json   # bonus E2
bash script/e3_permit.sh                                                     # bonus E3 (needs anvil, cast, jq)
```

If you cloned without `--recursive`, run `forge install` once to fetch `lib/forge-std`.

## How I covered the requirements

| # | Requirement | Where I implemented it | How I tested it |
|---|---|---|---|
| 1 | ERC-20 from scratch, one state-change funnel | `src/lib/ERC20.sol` → `_update` | `grep` finds every write to `_balances` / `_totalSupply` inside `_update` only ([evidence](evidence/single_funnel_grep.txt)); `Transfer` for mint, burn and transfers; `Approval` for `approve` and `permit`; zero receiver and overdraft revert with custom errors |
| 2 | Supply cap and three separable roles, explicit admin | `src/CampusToken.sol` → `_update`, `MINTER_ROLE`, `PAUSER_ROLE`, `CONFIG_ROLE`; `src/lib/AccessControl.sol` | the cap holds for `mint` and `claim`, both with `CapExceeded`; burning frees headroom; the deployer holds none of the four roles; each role on a different account can do its own job only |
| 3 | Transfer fee to a treasury | `src/CampusToken.sol` → `_update` | 1,000 tokens at 1 % → 990 to the recipient, 10 to the treasury; mint, burn and treasury transfers are exempt; supply never changes; 501 bps is rejected; dust pays no fee; fuzz test of the split |
| 4 | EIP-712 + EIP-2612 permit | `src/lib/ERC20Permit.sol`, `src/lib/ECDSA.sol` | valid permit, expired, replayed, wrong signer, high-s and garbage signature each with its own error; `DOMAIN_SEPARATOR()` follows `vm.chainId`; fuzz test with random keys |
| 5 | Merkle allowlist | `src/CampusToken.sol` → `claim`, `src/lib/MerkleProof.sol` | one valid claim; double claim, another account's proof, wrong amount and an internal node as a leaf all revert; real 14-element proofs from bonus E2 |
| 6 | Yul with a differential fuzz test and gas | `src/evm/MerkleYul.sol` → `verifyYul`, `src/evm/YulCounter.sol` → `sumCheckedYul` | `test/YulDifferential.t.sol`: same return data **and the same revert bytes** (`Panic(0x11)`) over 512 runs; gas of both versions |
| 7 | Proxy storage collision and the EIP-1967 fix | `src/evm/Proxy.sol` → `BrokenProxy`, `SafeProxy` | the broken proxy returns success with empty data after the collision; the safe proxy keeps its pointer, keeps state across the upgrade and refuses a non-contract |
| 8 | Tests | `test/` | every custom error is triggered; `forge coverage`: **100 % of lines, statements, branches and functions** of `src/`; 10 invariants in two suites, **0 reverts** |

`test/CampusToken.t.sol`, `test/CampusTokenInvariant.t.sol` and `test/EvmInternals.t.sol` are the course's reference suites (65 tests). I copied them **unchanged** and my implementation passes all of them. The other test files are mine (66 more tests).

## Layout

| Path | What I put there |
|---|---|
| `src/lib/ERC20.sol` | the token ledger and the single `_update` funnel |
| `src/lib/ERC20Permit.sol`, `src/lib/ECDSA.sol` | EIP-712 domain, EIP-2612 `permit`, signature recovery with the zero and low-s checks |
| `src/lib/AccessControl.sol` | roles with an admin role each |
| `src/lib/MerkleProof.sol` | double-hashed leaves, sorted-pair verification |
| `src/CampusToken.sol` | cap, roles, fee, pause, permit and claim together |
| `src/evm/StorageLayout.sol` | the layout specimen and the two packing-order contracts |
| `src/evm/YulCounter.sol`, `src/evm/MerkleYul.sol` | the Solidity / Yul pairs |
| `src/evm/Proxy.sol` | the broken proxy, the EIP-1967 proxy, a proxy that initialises in its constructor, the storage-gap example |
| `src/upgradeable/` | bonus E4: the token behind the proxy, V1 and V2 |
| `airdrop/merkle.py` | bonus E2: root and proofs for a CSV of recipients |
| `script/Deploy.s.sol`, `script/e3_permit.sh` | deployment, and bonus E3 on a local anvil node |

## My design decisions

- **Balances in slot 0.** I declare `_balances` first, so a balance is at `keccak256(abi.encode(account, uint256(0)))`. `treasury`, `feeBps` and `paused` share slot 8, because `_update` reads all three on every transfer, and one cold `SLOAD` covers them.
- **The funnel checks the full amount before the fee split.** A fee transfer is two balance moves. I check the sender's balance against the whole amount first, so an overdraft reports what the sender actually tried to send.
- **The pause covers everything.** `_update` checks it, so a pause stops mint, burn and claim as well as transfers.
- **The domain separator is cached only for its own chain and address.** It is rebuilt when `block.chainid` changes (a chain split) and when `address(this)` is not the deployed address (behind a proxy).
- **The proofs have a fixed length.** When a tree level has an odd number of nodes, I pair the last node with `bytes32(0)`, so all 10,000 proofs have exactly 14 elements, and the padding can never be claimed.
- **No dead code.** I left out what nothing would call (a role-admin setter, a reentrancy guard on `claim`, which makes no external call), so that 100 % coverage means every line I ship is tested.
- **The proxy forwards plain ETH too.** An empty `receive()` would trap ETH in the proxy; forwarding lets the logic refuse it.

## Something I found in the reference code

The reference `ECDSA.sol` writes n/2 with one hex digit missing (63 digits, so the constant is n/32). It therefore rejects about 15 of every 16 honest signatures as "high s". The course tests pass by luck because they always sign with the same key. My constant is correct; `testFuzz_PermitFromAnyKey` signs with random keys. Running the same kind of test against the reference fails on its first run ([evidence](evidence/reference_ecdsa_constant.txt)).

## Bonus challenges

I attempted **E2** (a real-sized airdrop), **E3** (permit from a real signature) and **E4** (an upgradeable token). Each has its own section in the report. I did not attempt E1 or E5.
