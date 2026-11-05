# /// script
# requires-python = ">=3.11"
# dependencies = ["pycryptodome==3.21.0"]
# ///
"""Bonus E2: Merkle root and proofs for an airdrop CSV.

    uv run airdrop/merkle.py generate airdrop/recipients.csv 10000   # test data
    uv run airdrop/merkle.py build airdrop/recipients.csv airdrop/proofs.json

The encoding is exactly the contract's (CampusToken.leafFor and
MerkleProof.hashPair):

    leaf = keccak256(keccak256(abi.encode(address account, uint256 amount)))
    node = keccak256(min(a, b) ++ max(a, b))

When a level has an odd number of nodes, I pair the last node with
bytes32(0). Zero can never be a real leaf or node (that would need a keccak256
preimage of zero), so the padding cannot be claimed, and every proof of a tree
with n leaves has exactly ceil(log2 n) elements: 14 for 10,000.
"""

import csv
import json
import math
import random
import sys
import time

from Crypto.Hash import keccak

ZERO = bytes(32)


def keccak256(data: bytes) -> bytes:
    return keccak.new(digest_bits=256, data=data).digest()


def checksum(addr20: bytes) -> str:
    """EIP-55 mixed-case address."""
    hex_addr = addr20.hex()
    h = keccak256(hex_addr.encode()).hex()
    return "0x" + "".join(c.upper() if int(h[i], 16) >= 8 else c for i, c in enumerate(hex_addr))


def leaf(account: str, amount: int) -> bytes:
    encoded = bytes(12) + bytes.fromhex(account[2:]) + amount.to_bytes(32, "big")
    return keccak256(keccak256(encoded))


def hash_pair(a: bytes, b: bytes) -> bytes:
    return keccak256(a + b) if a < b else keccak256(b + a)


def build_levels(leaves: list[bytes]) -> list[list[bytes]]:
    levels = [leaves]
    while len(levels[-1]) > 1:
        cur = levels[-1]
        if len(cur) % 2:
            cur = cur + [ZERO]
            levels[-1] = cur
        levels.append([hash_pair(cur[i], cur[i + 1]) for i in range(0, len(cur), 2)])
    return levels


def proof_for(levels: list[list[bytes]], index: int) -> list[bytes]:
    proof = []
    for level in levels[:-1]:
        proof.append(level[index ^ 1])
        index //= 2
    return proof


def verify(proof: list[bytes], root: bytes, node: bytes) -> bool:
    for sibling in proof:
        node = hash_pair(node, sibling)
    return node == root


def generate(path: str, n: int) -> None:
    rng = random.Random(20261105)
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["address", "amount"])
        seen = set()
        while len(seen) < n:
            addr = checksum(rng.randbytes(20))
            if addr in seen:
                continue
            seen.add(addr)
            # between 1 and 1,000 tokens, with 18 decimals
            w.writerow([addr, rng.randint(1, 1000) * 10**18 + rng.randint(0, 10**18 - 1)])
    print(f"wrote {n} recipients to {path}")


def build(csv_path: str, json_path: str) -> None:
    t0 = time.perf_counter()
    with open(csv_path, newline="") as f:
        rows = [(r["address"], int(r["amount"])) for r in csv.DictReader(f)]
    accounts = [a.lower() for a, _ in rows]
    if len(set(accounts)) != len(accounts):
        sys.exit("duplicate address in CSV: each account can claim only once")

    leaves = [leaf(a, amt) for a, amt in rows]
    levels = build_levels(list(leaves))
    root = levels[-1][0]
    depth = math.ceil(math.log2(len(rows)))

    claims = []
    for i, (account, amount) in enumerate(rows):
        proof = proof_for(levels, i)
        assert len(proof) == depth, (i, len(proof))
        assert verify(proof, root, leaves[i]), i
        claims.append(
            {
                "index": i,
                "account": account,
                "amount": str(amount),
                "leaf": "0x" + leaves[i].hex(),
                "proof": ["0x" + p.hex() for p in proof],
            }
        )

    out = {
        "root": "0x" + root.hex(),
        "count": len(rows),
        "depth": depth,
        "total": str(sum(a for _, a in rows)),
        "claims": claims,
    }
    with open(json_path, "w") as f:
        json.dump(out, f, separators=(",", ":"))
    print(f"recipients : {len(rows)}")
    print(f"root       : {out['root']}")
    print(f"proof size : {depth} elements for every recipient (ceil(log2 {len(rows)}))")
    print(f"total      : {int(out['total']) / 1e18:,.6f} tokens")
    print(f"checked    : all {len(rows)} proofs verify against the root in Python")
    print(f"time       : {time.perf_counter() - t0:.2f} s")


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "generate":
        generate(sys.argv[2], int(sys.argv[3]))
    elif len(sys.argv) == 4 and sys.argv[1] == "build":
        build(sys.argv[2], sys.argv[3])
    else:
        sys.exit(__doc__)
