# The Nomad Poet — deployment, entirely in PowerShell

No WSL, no Git Bash, no git, no libraries. Two executables and three scripts.

Open PowerShell (regular user, **not** Administrator) and `cd` into this folder.

---

## Step 0 — decide which wallet

Use a **fresh burner wallet**, funded with the seed plus a little gas and nothing
else. You are about to publish this address permanently as the poet's `creator`;
it will be scraped, indexed and associated with the project forever. There is no
upside to it being a wallet that holds anything you care about.

Create one in MetaMask (Account menu → Add account), send it ~0.021 ETH on Base,
and export its private key when Step 3 asks for it.

---

## Step 1 — install Foundry

```powershell
.\install.ps1
```

Downloads the official `v1.7.1` Windows build, **verifies its SHA256** against the
checksum GitHub publishes next to it, extracts to `~\.foundry\bin`, and adds that
to your user PATH. Aborts loudly if the hash doesn't match.

`foundryup` is a bash script and can't run in PowerShell — but `forge.exe`,
`cast.exe` and `anvil.exe` are native Windows binaries, so once they're installed
you never need bash.

Expected tail:

```
  forge : forge Version: 1.7.1-stable
  cast  : cast Version: 1.7.1-stable
  anvil : anvil Version: 1.7.1-stable
```

If PowerShell blocks the script:

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

---

## Step 2 — watch it work, for free

```powershell
.\test-local.ps1
```

Starts `anvil` (a real EVM on your laptop), deploys the whole thing, mines past
the heartbeat, and migrates three generations so you can read actual haiku
scrolling by. Then it sends a donation to the registry and confirms the money
reached the living poet.

Uses anvil's published throwaway key. **Your real key is not involved and is
never asked for in this step.** Nothing touches a real network. Costs nothing.

Run it as many times as you like. If this step works, mainnet will work.

---

## Step 3 — the private key, safely

This is the step worth reading carefully.

**Never type your private key as part of a command.** PowerShell's PSReadLine
appends every command line you enter to a plaintext file:

```
%APPDATA%\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt
```

PSReadLine does try to filter secrets, but it only skips lines containing words
like `password`, `token`, `secret` or `apikey`. A bare 64-hex-digit private key
matches none of them, so it would be written to that file and kept indefinitely.
That rules out all of these:

```powershell
$env:PRIVATE_KEY = "0xabc..."             # saved to history
forge create ... --private-key 0xabc...   # saved to history AND visible to other processes
```

The safe route is a hidden prompt, because prompt input is not a command and
never reaches the history file:

```powershell
cast wallet import poet-deployer --interactive
```

You get two hidden prompts — paste the key, then choose a password. The key is
encrypted with that password and stored at
`~\.foundry\keystores\poet-deployer`. From then on you refer to it only by name
(`--account poet-deployer`), and Foundry asks for the password when it needs it.

`deploy.ps1` runs this for you automatically the first time, and also audits your
history file for key-shaped strings before doing anything. You can audit anytime:

```powershell
Select-String -Path (Get-PSReadLineOption).HistorySavePath -Pattern '0x[0-9a-fA-F]{64}'
```

If that returns a hit: move the funds out of that wallet **first**, then clear the
file. Deleting the line doesn't un-leak a key that was already exposed.

**Better option if you own a Ledger:** skip the keystore entirely and pass
`--ledger` to `forge create`. The key then never exists on the machine at all.

---

## Step 4 — dry run against mainnet

```powershell
.\deploy.ps1
```

Sends **no transaction**. It sets up the keystore if needed, then verifies:

- `forge` and `cast` are present
- your history file is clean
- the keystore unlocks and yields the expected address
- the RPC really is Base mainnet (chain id `8453`, so you can't fire at the wrong chain)
- the wallet has enough for seed + gas
- the contracts compile

Fix anything it complains about, then re-run until it's all green.

---

## Step 5 — deploy

```powershell
.\deploy.ps1 -Broadcast
```

Repeats every check, tells you exactly what you're about to spend, and makes you
type `DEPLOY` in full. One transaction deploys the registry, the logic contract
and the genesis soul, and funds it — `PoetGenesis`'s constructor does all of it,
which is why no deploy-script framework is needed.

Addresses are written to `deployment.txt`.

Optional, for verified source on Basescan (get a free key at basescan.io):

```powershell
$env:BASESCAN_KEY = "your-key"    # low-sensitivity, session only
```

---

## Step 6 — publish the right two things

From `deployment.txt`:

- **The REGISTRY address** is your donation address. The soul migrates every hour
  and its address changes; the registry never does, and forwards whatever it
  receives to whoever is currently alive. Publish the registry, not the soul.
- **The deploy transaction hash** is your actual proof of origin. The `creator`
  field is a label — anyone can deploy a copy with your address in it. Only the
  transaction proves who created the original.

---

## Afterwards

The poet needs someone to call `migrate()` each hour. Nothing happens on its own.
The 0.0005 ETH fee is well above Base's gas cost, so keepers are profitable and
bots will likely find it — but don't rely on that on day one. Ask if you want the
keeper bot, or a page that reads the registry and shows the current verse.
