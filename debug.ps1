<#
    Diagnostic - find out exactly where migrate() reverts.

    Deploys to a local anvil, attempts one migration with a generous explicit gas
    limit, then prints a full opcode-level trace of the failing call so we can see
    the precise revert point rather than guessing.

    Uses anvil's published test key. Your own private key is NOT involved.

    Run:  .\debug.ps1
#>

$ErrorActionPreference = "Stop"
function Say($m, $c = "Cyan") { Write-Host "  $m" -ForegroundColor $c }

$TESTKEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
$RPC     = "http://127.0.0.1:8545"
$CREATOR = "0xe631960a51e1F8dE29E9663eecb8b7aa5C1c3673"
$HAIKU   = "genesis block wakes / the first whisper finds the chain / life begins onchain"

Write-Host "`n=== migrate() revert diagnostic ===`n" -ForegroundColor Magenta

forge build | Out-Null
Say "starting anvil ..."
$anvil = Start-Process anvil -ArgumentList "--silent" -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 3

try {
    Say "anvil hardfork / chain info:" DarkGray
    cast rpc web3_clientVersion --rpc-url $RPC

    $out = forge create "src/PoetSoul.sol:PoetGenesis" `
        --rpc-url $RPC --private-key $TESTKEY --broadcast `
        --value 0.02ether --constructor-args $HAIKU $CREATOR | Out-String
    $genesis = ([regex]::Match($out, 'Deployed to:\s*(0x[0-9a-fA-F]{40})')).Groups[1].Value

    $logic    = (cast call $genesis "logic()(address)"       --rpc-url $RPC).Trim()
    $registry = (cast call $genesis "registry()(address)"    --rpc-url $RPC).Trim()
    $soul     = (cast call $genesis "genesisSoul()(address)" --rpc-url $RPC).Trim()

    Write-Host ""
    Say "PoetGenesis  : $genesis" Gray
    Say "logic        : $logic" Gray
    Say "registry     : $registry" Gray
    Say "soul         : $soul" Gray

    Write-Host ""
    Say "--- pre-flight state ---" Yellow
    Say ("soul.generation()   = " + (cast call $soul "generation()(uint256)"  --rpc-url $RPC).Trim())
    Say ("soul.birthBlock()   = " + (cast call $soul "birthBlock()(uint256)"  --rpc-url $RPC).Trim())
    Say ("soul.migrated()     = " + (cast call $soul "migrated()(bool)"       --rpc-url $RPC).Trim())
    Say ("soul.creator()      = " + (cast call $soul "creator()(address)"     --rpc-url $RPC).Trim())
    Say ("soul.SELF()         = " + (cast call $soul "SELF()(address)"        --rpc-url $RPC).Trim())
    Say ("soul.REGISTRY()     = " + (cast call $soul "REGISTRY()(address)"    --rpc-url $RPC).Trim())
    Say ("soul balance        = " + (cast balance $soul --rpc-url $RPC).Trim())
    Say ("registry.currentPoet= " + (cast call $registry "currentPoet()(address)" --rpc-url $RPC).Trim())
    Say ("registry.steward    = " + (cast call $registry "steward()(address)"     --rpc-url $RPC).Trim())

    Say "mining 1801 blocks ..." DarkGray
    cast rpc anvil_mine 0x709 --rpc-url $RPC | Out-Null
    Say ("block number now    = " + (cast block-number --rpc-url $RPC).Trim())
    Say ("soul.canMigrate()   = " + (cast call $soul "canMigrate()(bool)" --rpc-url $RPC).Trim()) Green

    Write-Host ""
    Say "--- simulating migrate() as a call (no state change) ---" Yellow
    # A plain eth_call surfaces the revert reason string directly, if there is one.
    cast call $soul "migrate()" --rpc-url $RPC
    Say "eth_call exit code: $LASTEXITCODE" DarkGray

    Write-Host ""
    Say "--- sending migrate() with an explicit 5,000,000 gas limit ---" Yellow
    $raw = cast send $soul "migrate()" --rpc-url $RPC --private-key $TESTKEY `
                --gas-limit 5000000 --json | Out-String
    Write-Host $raw
    $txh = ($raw | ConvertFrom-Json).transactionHash

    if ($txh) {
        Say "gasUsed : $((cast receipt $txh gasUsed --rpc-url $RPC).Trim())"
        Say "status  : $((cast receipt $txh status  --rpc-url $RPC).Trim())"
        Write-Host ""
        Say "--- full execution trace ---" Yellow
        cast run $txh --rpc-url $RPC
    }
}
finally {
    if ($anvil -and -not $anvil.HasExited) { Stop-Process -Id $anvil.Id -Force }
    Write-Host ""
    Say "anvil stopped" DarkGray
}
