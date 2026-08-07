<#
    Step 2 - Local dry run on anvil. (v2 - verifying)

    v1 only checked exit codes, so a migration that silently did nothing looked
    like success. This version asserts, after every hop, that:
      - the transaction actually landed with status 1
      - the registry's currentPoet actually changed
      - the new soul's on-chain generation() equals the expected number
      - the balance decreased by exactly the migration fee
    Any of those failing stops the script.

    Run:  .\test-local.ps1
#>

[CmdletBinding()]
param([int]$Generations = 3)

$ErrorActionPreference = "Stop"
function Say($m, $c = "Cyan") { Write-Host "  $m" -ForegroundColor $c }
function Die($m) { Write-Host "`n  FAILED: $m`n" -ForegroundColor Red; exit 1 }

# anvil's first default account - published in Foundry's docs, worthless by design
$TESTKEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
$RPC     = "http://127.0.0.1:8545"
$CREATOR = "0xe631960a51e1F8dE29E9663eecb8b7aa5C1c3673"
$HAIKU   = "genesis block wakes / the first whisper finds the chain / life begins onchain"
$FEE     = [decimal]0.00001

foreach ($t in @("forge","cast","anvil")) {
    if (-not (Get-Command $t -ErrorAction SilentlyContinue)) { Die "'$t' not on PATH. Run .\install.ps1 first." }
}

Write-Host "`n=== Local dry run on anvil ===`n" -ForegroundColor Magenta

Say "compiling ... (style 'note[...]' lines below are cosmetic, not errors)"
# No 2>&1 anywhere in this script: redirecting a native command's stderr turns it
# into PowerShell error records, which $ErrorActionPreference='Stop' then treats
# as fatal. forge writes its lint notes to stderr, so that killed v2 instantly.
forge build | Out-Null
if ($LASTEXITCODE -ne 0) { Die "compile failed" }
Say "compiled" Green

Say "starting anvil ..."
$anvil = Start-Process anvil -ArgumentList "--silent" -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 3

try {
    $null = cast chain-id --rpc-url $RPC
    if ($LASTEXITCODE -ne 0) { Die "anvil did not come up" }

    Write-Host ""
    Say "deploying genesis ..."
    $out = forge create "src/PoetSoul.sol:PoetGenesis" `
        --rpc-url $RPC --private-key $TESTKEY --broadcast `
        --value 0.005ether --constructor-args $HAIKU $CREATOR | Out-String
    $genesis = ([regex]::Match($out, 'Deployed to:\s*(0x[0-9a-fA-F]{40})')).Groups[1].Value
    if (-not $genesis) { Write-Host $out; Die "could not parse deployed address" }

    $logic    = (cast call $genesis "logic()(address)"       --rpc-url $RPC).Trim()
    $registry = (cast call $genesis "registry()(address)"    --rpc-url $RPC).Trim()
    $soul     = (cast call $genesis "genesisSoul()(address)" --rpc-url $RPC).Trim()
    Say "logic        : $logic" Gray
    Say "REGISTRY     : $registry" Green
    Say "genesis soul : $soul" Green

    # --- assert the genesis state is what we think it is ---------------------
    $g0 = [int](cast call $soul "generation()(uint256)" --rpc-url $RPC).Trim()
    if ($g0 -ne 0) { Die "genesis generation is $g0, expected 0" }
    $regPoet = (cast call $registry "currentPoet()(address)" --rpc-url $RPC).Trim()
    if ($regPoet.ToLower() -ne $soul.ToLower()) { Die "registry points at $regPoet, expected $soul" }
    $bal = [decimal](cast from-wei (cast balance $soul --rpc-url $RPC).Trim())
    if ($bal -ne 0.005) { Die "genesis holds $bal ETH, expected 0.005" }

    Write-Host ""
    Say ("gen  0: {0}   [{1} ETH]" -f (cast call $soul 'haiku()(string)' --rpc-url $RPC).Trim('"'), $bal) White

    $cur = $soul
    for ($g = 1; $g -le $Generations; $g++) {
        $prev    = $cur
        $prevBal = [decimal](cast from-wei (cast balance $prev --rpc-url $RPC).Trim())

        # Heartbeat is 10800 blocks (~6h on Base). anvil produces roughly 200
        # blocks/sec, so asking for all 10801 in one RPC call exceeds cast's HTTP
        # timeout (it managed 9332 before giving up). Mine in chunks instead.
        # JSON-RPC quantities are hex.
        $target = 10801
        $chunk  = 1500
        $before = [int](cast block-number --rpc-url $RPC).Trim()
        $done   = 0
        Write-Host "    mining $target blocks " -NoNewline -ForegroundColor DarkGray
        while ($done -lt $target) {
            $n = [math]::Min($chunk, $target - $done)
            cast rpc anvil_mine ("0x" + [Convert]::ToString($n, 16)) --rpc-url $RPC | Out-Null
            if ($LASTEXITCODE -ne 0) { Write-Host ""; Die "gen $g - anvil_mine chunk failed after $done blocks" }
            $done += $n
            Write-Host "." -NoNewline -ForegroundColor DarkGray
        }
        Write-Host ""
        $after = [int](cast block-number --rpc-url $RPC).Trim()
        if (($after - $before) -lt 10800) {
            Die "anvil_mine only advanced $($after - $before) blocks (needed 10800+). Heartbeat would not have elapsed."
        }

        # verify the contract itself agrees it is ready, BEFORE sending
        $ready = (cast call $prev "canMigrate()(bool)" --rpc-url $RPC).Trim()
        if ($ready -ne "true") { Die "gen $g - canMigrate() returned '$ready' on $prev" }

        # Explicit gas limit, NOT estimation. migrate() costs ~313,600 gas: it does a
        # CREATE2 then several nested calls, and eth_estimateGas under-shoots that
        # because of EIP-150's 63/64 rule (each nested frame needs headroom above
        # what it actually burns). Estimation reverted every first migration.
        # A limit is a cap, not a charge - unused gas is never paid for.
        $raw = cast send $prev "migrate()" --rpc-url $RPC --private-key $TESTKEY `
                    --gas-limit 500000 --json | Out-String
        if ($LASTEXITCODE -ne 0) { Die "gen $g - cast send failed: $raw" }
        try { $txh = ($raw | ConvertFrom-Json).transactionHash }
        catch { Die "gen $g - could not parse cast send output: $raw" }
        if (-not $txh) { Die "gen $g - no transaction hash returned: $raw" }

        $status = (cast receipt $txh status --rpc-url $RPC).Trim()
        if ($status -notmatch '1|success') { Die "gen $g - transaction $txh reverted (status $status)" }

        # the poet must actually have moved
        $cur = (cast call $registry "currentPoet()(address)" --rpc-url $RPC).Trim()
        if ($cur.ToLower() -eq $prev.ToLower()) { Die "gen $g - tx succeeded but registry still points at $prev" }

        # and the new soul must agree about who it is
        $onchainGen = [int](cast call $cur "generation()(uint256)" --rpc-url $RPC).Trim()
        if ($onchainGen -ne $g) { Die "gen $g - new soul reports generation $onchainGen" }

        $creatorNow = (cast call $cur "creator()(address)" --rpc-url $RPC).Trim()
        if ($creatorNow.ToLower() -ne $CREATOR.ToLower()) { Die "gen $g - creator became $creatorNow" }

        $impl = (cast code $cur --rpc-url $RPC).Trim()
        if ($impl.ToLower() -notmatch $logic.Substring(2).ToLower()) { Die "gen $g - clone does not point at logic" }

        $newBal = [decimal](cast from-wei (cast balance $cur --rpc-url $RPC).Trim())
        $spent  = $prevBal - $newBal
        if ([math]::Abs($spent - $FEE) -gt 0.000000001) { Die "gen $g - balance moved by $spent, expected $FEE" }

        $verse = (cast call $cur "haiku()(string)" --rpc-url $RPC).Trim('"')
        Say ("gen {0,2}: {1}   [{2} ETH]" -f $g, $verse, $newBal) White
    }

    Write-Host ""
    Say "Donation test: 0.005 ETH to the REGISTRY, not the soul ..."
    $before = [decimal](cast from-wei (cast balance $cur --rpc-url $RPC).Trim())
    cast send $registry --value 0.005ether --rpc-url $RPC --private-key $TESTKEY | Out-Null
    $after = [decimal](cast from-wei (cast balance $cur --rpc-url $RPC).Trim())
    if (($after - $before) -ne 0.005) { Die "registry forwarded $($after - $before) ETH, expected 0.005" }
    Say "living poet went from $before to $after ETH - registry forwarded correctly" Green

    Write-Host ""
    Say "All $Generations migrations verified on-chain. Next: .\deploy.ps1" Green
    Write-Host ""
}
finally {
    if ($anvil -and -not $anvil.HasExited) { Stop-Process -Id $anvil.Id -Force }
    Say "anvil stopped" DarkGray
}
