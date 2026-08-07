# The Nomad Poet

A haiku that lives on Base and moves house. Each generation is an EIP-1167 clone
holding its own verse, lineage hash and treasury. Anyone can call `migrate()`
after the heartbeat elapses and collect a fee for midwifing the next generation.

## What was wrong with the earlier drafts

**Draft 1 (`new PoetSoul` inside `PoetSoul`) does not compile.**

```
TypeError: Circular reference to contract bytecode either via "new" or
"type(...).creationCode" / "type(...).runtimeCode".
```

A contract's creation code would have to contain its own creation code. Self-replication
in Solidity needs a factory, a clone, or raw `codecopy`.

**Draft 2 (the minimal-proxy version) compiles but is dead on arrival.** Three
independent faults, each verified on a local EVM:

| # | Fault | Observed |
|---|-------|----------|
| A | Word banks declared as **storage** arrays. Under `delegatecall` a clone reads *its own* storage, which is empty. | Every migration emitted `' /  / '` — a blank poem, forever. |
| B | Clones have no `receive()`, and the logic contract had none either, so the proxy's fallback delegatecalls into a function that doesn't exist. | Every ETH send to the poet reverted, at 23,300 *and* 200,000 gas. Balance stayed at 0 wei. Nobody could ever donate. |
| C | `_deployProxy()` embedded `address(this)` as the implementation. Under `delegatecall` that is the **clone**, not the logic contract. | Generation 1's clone pointed at generation 0's clone. Each hop adds a delegatecall layer; gas grows without bound until the lineage dies. |

Also: `tx.origin` instead of `msg.sender` for the keeper fee; no once-only guard, so
anyone could re-fund a spent parent and fork the lineage; `.transfer()`'s 2300-gas cap.

## What this version does differently

- Word banks are `pure` functions — the strings live in bytecode, not storage.
- `SELF` is an `immutable` set in the logic constructor. Immutables are baked into the
  *executing* code, so under `delegatecall` it correctly resolves to the logic contract.
- `receive()` on the logic contract, `call{value:}` everywhere. Clones accept ETH.
- `migrated` flag set before any external call. A soul migrates exactly once.
- `PoetRegistry` — **one permanent address donors can bookmark.** ETH sent there is
  forwarded to whoever is currently alive. Only the living poet may name its successor.
- The logic contract locks its own initializer in its constructor, so nobody can squat
  it and display a fake `creator`.

## Honest caveat about the "creator signature"

`creator` is a **label, not a proof**. Anyone can deploy an identical lineage with your
address burned in. What actually proves origin is the genesis deployment transaction and
the `PoetGenesis` address — publish those. The `lineageHash` chain proves a given soul
descends from that specific genesis; it proves nothing about who deployed the genesis.

## Parameters and lifespan

`HEARTBEAT_BLOCKS = 1800` (~1 hour on Base) and a flat `MIGRATION_FEE = 0.0005 ether`.

At one migration per hour the poet spends **0.012 ETH/day**. Its lifespan is therefore
`seed / 0.012` days, and donations extend it linearly:

| seed | migrations | lifespan |
|------|-----------|----------|
| 0.02 ETH | 40 | ~1.7 days |
| 0.10 ETH | 200 | ~8.3 days |
| 0.50 ETH | 1,000 | ~42 days |
| 1.00 ETH | 2,000 | ~83 days |

Note: an earlier estimate of "~$7/month, a single $10 donation keeps it alive for weeks"
assumed 0.00015 ETH per migration. The fee is 0.0005 ETH — 3.3x higher — so the real
figure is roughly 0.012 ETH/day, and 0.02 ETH buys under two days, not weeks. Seed
accordingly, or switch to a percentage-of-balance fee if you want it to be unkillable.

The 0.0005 ETH fee is far above Base's ~313k gas cost, so keepers are reliably profitable
and the poet will be migrated on schedule. That is by design — it also means the treasury
drains at exactly the rate above, with no slack.

## Verified locally

`python3 test_lifecycle.py` runs 6 generations (at 1,800-block heartbeats) on py-evm and asserts:

```
gas per migration  : min 313,517  max 313,571   (flat — no proxy chaining)
genesis deploy gas : 1,575,697
creator signature survived every generation     PASS
donations reach the living poet via one address PASS
double-migration rejected at every generation   PASS
clone implementation == logic at every hop      PASS
```

## Deploy

Windows / PowerShell: follow **STEPS.md**. Three scripts, no WSL, no git, no
libraries — `install.ps1`, then `test-local.ps1`, then `deploy.ps1`.

Everything else: `forge create src/PoetSoul.sol:PoetGenesis --constructor-args
"<haiku>" <creator> --value 0.02ether --rpc-url https://mainnet.base.org
--account <keystore> --broadcast`. The `PoetGenesis` constructor deploys the
registry, the logic contract and the genesis soul in a single transaction, so no
deploy-script framework is required.

Publish the **registry** address for donations, not the genesis soul — the soul
moves, the registry doesn't. And publish the deployment tx hash as proof of
origin; the `creator` field alone proves nothing.
