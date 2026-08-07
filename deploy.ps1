<#
    Step 3 - Deploy the Nomad Poet to Base mainnet. Real money.

    Run:  .\deploy.ps1                 # every check + a dry run, sends nothing
          .\deploy.ps1 -Broadcast      # the real thing

    Your private key is never typed as part of a command, never placed in an
    environment variable, and never written to disk in plaintext. It is entered
    once at a hidden prompt and kept as an encrypted keystore file.
#>

[CmdletBinding()]
param(
    [switch]$Broadcast,
    [string]$Account  = "poet-deployer",
    [string]$RpcUrl   = "https://mainnet.base.org",
    [string]$Creator  = "0xe631960a51e1F8dE29E9663eecb8b7aa5C1c3673",
    [decimal]$SeedEth = 0.005
)

$ErrorActionPreference = "Stop"
function Say($m, $c = "Cyan") { Write-Host "  $m" -ForegroundColor $c }
function Die($m) { Write-Host "`n  ERROR: $m`n" -ForegroundColor Red; exit 1 }

$HAIKU = "genesis block wakes / the first whisper finds the chain / life begins onchain"

Write-Host "`n=== The Nomad Poet -> Base mainnet ===`n" -ForegroundColor Magenta

foreach ($t in @("forge","cast")) {
    if (-not (Get-Command $t -ErrorAction SilentlyContinue)) { Die "'$t' not on PATH. Run .\install.ps1 first." }
}

# ------------------------------------------------- history-leak self-audit ---
# PSReadLine appends every command you type to a plaintext file. Its secret
# filter only skips lines containing words like 'password' or 'token' - a bare
# 64-hex-digit key matches none of those and WOULD be saved permanently.
$histPath = (Get-PSReadLineOption).HistorySavePath
if ($histPath -and (Test-Path $histPath)) {
    $leak = Select-String -Path $histPath -Pattern '0x[0-9a-fA-F]{64}' -ErrorAction SilentlyContinue
    if ($leak) {
        Write-Host ""
        Say "WARNING: your PowerShell history contains a 64-hex-digit string." Yellow
        Say "         That is the shape of a private key." Yellow
        Say "         File : $histPath" Yellow
        Say "         Lines: $($leak.LineNumber -join ', ')" Yellow
        Say "         Assume it is compromised: move the funds, then clear the file." Yellow
        Write-Host ""
        if ((Read-Host "  Continue anyway? (yes/no)") -ne "yes") { exit 1 }
    } else {
        Say "history clean - no key-shaped strings" DarkGray
    }
}

# ------------------------------------------------------- keystore handling ---
$keystore = Join-Path $HOME ".foundry\keystores\$Account"
if (-not (Test-Path $keystore)) {
    Write-Host ""
    Say "No keystore '$Account' yet - creating one."
    Say "Two hidden prompts follow: your private key, then a password to encrypt it." DarkGray
    Say "PASTE the key at the prompt. Never type it into a command." Yellow
    Write-Host ""
    cast wallet import $Account --interactive
    if ($LASTEXITCODE -ne 0) { Die "keystore import failed" }
    Say "encrypted keystore written to $keystore" Green
} else {
    Say "using keystore '$Account'" DarkGray
}

$sender = (cast wallet address --account $Account).Trim()
if ($LASTEXITCODE -ne 0 -or -not $sender) { Die "could not unlock keystore" }
Say "deployer    : $sender" Green

# ------------------------------------------------------------ chain checks ---
$chainId = (cast chain-id --rpc-url $RpcUrl).Trim()
if ($chainId -ne "8453") { Die "expected Base mainnet (8453), got '$chainId'" }
Say "chain       : $chainId (Base mainnet)" Green

$balEth = [decimal](cast from-wei (cast balance $sender --rpc-url $RpcUrl).Trim())
Say "balance     : $balEth ETH"
# Deployment measured at ~1,575,700 gas; at 0.006 gwei that is ~0.0000095 ETH.
# 0.0005 ETH of headroom covers a 50x gas spike plus the L1 data fee.
$needed = $SeedEth + 0.0005
if ($balEth -lt $needed) { Die "need about $needed ETH (seed $SeedEth + gas), have $balEth. Lower the seed with -SeedEth <amount>." }

$gasPrice = (cast gas-price --rpc-url $RpcUrl).Trim()
Say "gas price   : $(cast from-wei $gasPrice gwei) gwei" DarkGray

Say "compiling ..."
forge build | Out-Null
if ($LASTEXITCODE -ne 0) { Die "compile failed" }
Say "compiled" Green

if (-not $Broadcast) {
    Write-Host ""
    Say "All checks passed. Nothing was sent." Green
    Say "Re-run with -Broadcast to deploy for real." Yellow
    Write-Host ""
    exit 0
}

# --------------------------------------------------------------- broadcast ---
Write-Host ""
Say "About to spend $SeedEth ETH of real money on Base mainnet." Yellow
Say "creator will be permanently set to $Creator" Yellow
Say "at 0.00001 ETH/migration and one hop per 6 hours ($([math]::Round($SeedEth/0.00001,0)) migrations)," Yellow
Say "$SeedEth ETH lasts about $([math]::Round($SeedEth/0.00004,0)) days before donations." Yellow
Write-Host ""
if ((Read-Host "  Type DEPLOY to confirm") -ne "DEPLOY") { Say "aborted" Red; exit 1 }

$verify = @()
if ($env:BASESCAN_KEY) { $verify = @("--verify","--etherscan-api-key",$env:BASESCAN_KEY) }
else { Say "BASESCAN_KEY not set - skipping source verification" DarkGray }

# Explicit gas limit rather than estimation. Genesis deployment measured at
# ~1,575,700 gas locally; 2,500,000 is a comfortable cap. A gas limit is a
# ceiling, not a charge - you only pay for gas actually consumed. Estimation was
# observed under-shooting this contract because of its nested CREATE2 calls.
# Also: no 2>&1 anywhere - redirecting native stderr turns forge's harmless lint
# notes into terminating PowerShell errors.
$out = forge create "src/PoetSoul.sol:PoetGenesis" `
    --rpc-url $RpcUrl --account $Account --broadcast `
    --gas-limit 2500000 `
    --value "$($SeedEth)ether" `
    --constructor-args $HAIKU $Creator @verify | Out-String
Write-Host $out
if ($LASTEXITCODE -ne 0) { Die "deployment failed" }

$genesis = ([regex]::Match($out, 'Deployed to:\s*(0x[0-9a-fA-F]{40})')).Groups[1].Value
$txHash  = ([regex]::Match($out, 'Transaction hash:\s*(0x[0-9a-fA-F]{64})')).Groups[1].Value
if (-not $genesis) { Die "deployed, but could not parse the address from output above" }

$logic    = (cast call $genesis "logic()(address)"       --rpc-url $RpcUrl).Trim()
$registry = (cast call $genesis "registry()(address)"    --rpc-url $RpcUrl).Trim()
$soul     = (cast call $genesis "genesisSoul()(address)" --rpc-url $RpcUrl).Trim()

$summary = @"
The Nomad Poet - deployed $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

PoetGenesis   $genesis
deploy tx     $txHash          <- your real proof of origin
logic         $logic
REGISTRY      $registry        <- publish THIS as the donation address
genesis soul  $soul            <- moves every ~6 hours; do not publish it
creator tag   $Creator

Basescan: https://basescan.org/address/$registry
"@
$summary | Tee-Object -FilePath "deployment.txt"

Write-Host ""
Say "Saved to deployment.txt" Green
Say "Publish the REGISTRY address for donations - the soul moves, the registry doesn't." Green
Say "Publish the deploy tx hash as proof of origin - the creator field alone proves nothing." Green
Write-Host ""
