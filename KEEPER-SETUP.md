# Making the poet autonomous

The contract cannot trigger itself — no EVM contract can. This sets up GitHub
Actions to call `migrate()` on a schedule, for free, forever.

## What it does

Every 2 hours a GitHub runner wakes up, asks the registry who the current poet is,
checks `canMigrate()`, and if the heartbeat has elapsed it sends the transaction.
Then it appends the new verse to `POEMS.md` and commits it — so your repo slowly
becomes the poet's collected works.

Polling every 2 hours against a 6-hour heartbeat is deliberate. `HEARTBEAT_BLOCKS`
is a **minimum**, not a schedule: early calls are a free no-op, late calls cost
nothing. That makes GitHub's famously imprecise cron perfectly adequate here.

## Setup

### 1. Create a repository

Public or private both work. Public gets unlimited Actions minutes; private gets
2,000/month, and this uses roughly 360.

**If public, do not commit `deployment.txt` if you'd rather keep the deployer
address low-profile.** The registry and soul addresses are public on-chain anyway.

### 2. Add the files

```
your-repo/
  .github/workflows/keeper.yml    <- the workflow
  POEMS.md                        <- create it empty, or with a title line
  src/PoetSoul.sol                <- optional, but good for provenance
  README.md                       <- optional
```

### 3. Add the private key as a secret

In your repo: **Settings → Secrets and variables → Actions → New repository secret**

- Name: `KEEPER_KEY`
- Value: the private key for `0xe631960a51e1F8dE29E9663eecb8b7aa5C1c3673`

**Paste it directly into the browser field.** Do not echo it in PowerShell first —
PSReadLine would write it to your history file in plaintext. Export it from
MetaMask (Account details → Show private key) and paste straight into GitHub.

GitHub encrypts secrets at rest and masks them in logs. The workflow passes the key
via an environment variable, never as a command-line argument.

### 4. Enable and test

Push, then go to **Actions**. Run **Nomad Poet keeper** manually via
*Run workflow* to check it works before trusting the schedule.

The first run will almost certainly log `canMigrate : false` and exit cleanly —
that is correct if less than ~6 hours have passed since the last migration.

## What the logs tell you

```
current poet : 0xa0FeE1...
generation   : 0
treasury     : 0.005000000000000000 ETH
canMigrate   : true
keeper       : 0xe63196...
::notice::generation 1 - silent code awakes / the mempool carries my breath / cold moon over glass
```

## Things that will eventually go wrong

**The treasury empties.** ~500 migrations ≈ 125 days. Then `canMigrate()` returns
false forever and the workflow logs "nothing to do" every 2 hours. The poet is not
broken — it is paused. Any donation to the registry
(`0x62dfaFd357bc82532D24dff6AaaD6e8314a9ea10`) revives it on the next run.

**GitHub disables the schedule after 60 days of repository inactivity.** The
workflow commits to `POEMS.md` on every migration, which counts as activity, so
this should never fire while the poet is alive. If the poet pauses for 60+ days
there are no commits, and GitHub will email you and disable the cron. Re-enabling
is one click in the Actions tab.

**The keeper runs out of gas money.** Unlikely — each migration costs ~0.000002 ETH
in gas and pays a 0.00001 ETH fee, so the keeper wallet *earns* about 5x what it
spends. It should grow steadily as long as the poet has treasury. The workflow warns
if the balance drops below 0.0001 ETH.

**Base gas spikes past ~0.03 gwei.** Migration stops being profitable for the
keeper. It still works — you're just subsidising it slightly. Nothing breaks.

## Turning it off

Disable the workflow in the Actions tab. The poet simply stops moving and keeps its
treasury indefinitely. Nothing is lost; re-enable whenever.

## Removing your key later

If you decide you'd rather not have the creator wallet's key on GitHub:

1. Create a new wallet, send it ~0.0005 ETH
2. Replace the `KEEPER_KEY` secret with the new key
3. Done — the keeper address is not recorded anywhere in the contract

The `creator` field stays `0xe631...` regardless. Any address may call `migrate()`.
