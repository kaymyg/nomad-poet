<#
    Step 1 - Install Foundry on Windows, entirely in PowerShell. (v2)

    Changes from v1: retries transient network failures, reuses an already
    downloaded zip instead of fetching it again, and if the checksum file cannot
    be retrieved it stops and asks rather than quietly skipping verification.

    Run:  .\install.ps1
#>

[CmdletBinding()]
param(
    [string]$Version = "v1.7.1",
    [string]$InstallDir = "$HOME\.foundry\bin"
)

$ErrorActionPreference = "Stop"
function Say($m, $c = "Cyan") { Write-Host "  $m" -ForegroundColor $c }
function Die($m) { Write-Host "`n  ERROR: $m`n" -ForegroundColor Red; exit 1 }

function Get-WithRetry {
    param([string]$Uri, [string]$OutFile, [int]$Attempts = 4)
    for ($i = 1; $i -le $Attempts; $i++) {
        try {
            Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -TimeoutSec 300
            return $true
        } catch {
            $msg = $_.Exception.Message
            if ($i -lt $Attempts) {
                $wait = [math]::Pow(2, $i)
                Say "attempt $i/$Attempts failed ($msg) - retrying in ${wait}s" DarkYellow
                Start-Sleep -Seconds $wait
            } else {
                Say "attempt $i/$Attempts failed: $msg" Red
            }
        }
    }
    return $false
}

Write-Host "`n=== Installing Foundry $Version ===`n" -ForegroundColor Magenta

if (-not [Environment]::Is64BitOperatingSystem) { Die "64-bit Windows required." }
if ($PSVersionTable.PSVersion.Major -lt 5) { Die "PowerShell 5+ required." }

$asset = "foundry_${Version}_win32_amd64.zip"
$base  = "https://github.com/foundry-rs/foundry/releases/download/$Version"
$tmp   = Join-Path $env:TEMP "foundry-$Version"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$zip   = Join-Path $tmp $asset
$sums  = Join-Path $tmp "$asset.sha256"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ------------------------------------------------------------ archive ------
if ((Test-Path $zip) -and (Get-Item $zip).Length -gt 1MB) {
    Say "reusing already-downloaded $asset ($([math]::Round((Get-Item $zip).Length/1MB,1)) MB)" DarkGray
} else {
    Say "downloading $asset ..."
    if (-not (Get-WithRetry "$base/$asset" $zip)) { Die "could not download the archive" }
    Say "downloaded ($([math]::Round((Get-Item $zip).Length/1MB,1)) MB)" Green
}

$actual = (Get-FileHash $zip -Algorithm SHA256).Hash

# ----------------------------------------------------------- checksum ------
Say "fetching checksum ..."
$haveSums = Get-WithRetry "$base/$asset.sha256" $sums 3

if ($haveSums) {
    $expected = ([regex]::Match((Get-Content $sums -Raw), '[0-9a-fA-F]{64}')).Value
    if (-not $expected) { Die "checksum file downloaded but could not be parsed" }
    if ($actual -ne $expected.ToUpper()) {
        Say "expected : $($expected.ToUpper())" Red
        Say "actual   : $actual" Red
        Die "CHECKSUM MISMATCH - do not use this download. Delete $tmp and retry."
    }
    Say "checksum verified: $actual" Green
} else {
    Write-Host ""
    Say "Could not retrieve the published checksum after 3 attempts." Yellow
    Say "The archive itself downloaded fine, so this is very likely a network blip," Yellow
    Say "but that means it has NOT been verified. Check it by hand:" Yellow
    Write-Host ""
    Say "  computed SHA256 : $actual" White
    Say "  compare against : $base/$asset.sha256" White
    Say "  (open that URL in a browser - it is a one-line text file)" DarkGray
    Write-Host ""
    $ans = Read-Host "  Do they match? Type the word MATCH to continue, anything else to stop"
    if ($ans -ne "MATCH") { Die "stopped without verifying. Nothing was installed." }
    Say "proceeding on your confirmation" Yellow
}

# ------------------------------------------------------------ extract ------
if (Test-Path $InstallDir) { Remove-Item $InstallDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
try { Expand-Archive -Path $zip -DestinationPath $InstallDir -Force }
catch { Die "archive would not extract - it is probably a truncated download. Delete $tmp and re-run." }

Say "extracted to $InstallDir" Green
Get-ChildItem $InstallDir -Filter *.exe | ForEach-Object { Say "  $($_.Name)" DarkGray }

# --------------------------------------------------------------- PATH ------
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($userPath -notlike "*$InstallDir*") {
    [Environment]::SetEnvironmentVariable("Path", "$userPath;$InstallDir", "User")
    Say "added to your user PATH (permanent)" Green
} else {
    Say "already on PATH" DarkGray
}
$env:Path = "$env:Path;$InstallDir"

# ------------------------------------------------------------- verify ------
Write-Host ""
try {
    Say "forge : $((& "$InstallDir\forge.exe" --version) -join ' ')" Green
    Say "cast  : $((& "$InstallDir\cast.exe"  --version) -join ' ')" Green
    Say "anvil : $((& "$InstallDir\anvil.exe" --version) -join ' ')" Green
} catch {
    Die "binaries extracted but would not run: $_"
}

Write-Host ""
Say "Done. Next: .\test-local.ps1" Green
Say "(the downloaded archive is kept at $tmp - delete it whenever you like)" DarkGray
Write-Host ""
