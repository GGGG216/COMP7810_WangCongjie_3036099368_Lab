# Install a pinned, project-local toolchain; no admin or global PATH change needed.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$labRoot = Split-Path $PSScriptRoot -Parent
$toolDir = Join-Path $labRoot '.tools'
New-Item -ItemType Directory -Path $toolDir -Force | Out-Null

$foundryVersion = 'v1.8.4'
$foundryHash = '7927f41b36fbe815f858ebb3e9fb7ca07a9b53fed67ccca6471acd7efd203aa1'
$archive = Join-Path $toolDir "foundry_$foundryVersion.zip"
$foundryDir = Join-Path $toolDir 'foundry'
if (-not (Test-Path (Join-Path $foundryDir 'forge.exe'))) {
    $uri = "https://github.com/foundry-rs/foundry/releases/download/$foundryVersion/foundry_${foundryVersion}_win32_amd64.zip"
    Write-Host "Downloading official Foundry $foundryVersion for Windows..."
    if (-not (Test-Path $archive)) {
        Invoke-WebRequest -Uri $uri -OutFile $archive
    }
    if ((Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $foundryHash) {
        throw "Foundry checksum mismatch; remove $archive and retry."
    }
    Expand-Archive -LiteralPath $archive -DestinationPath $foundryDir -Force
}

$solcPath = Join-Path $toolDir 'solc-0.8.24.exe'
if (-not (Test-Path $solcPath)) {
    $base = 'https://raw.githubusercontent.com/ethereum/solc-bin/gh-pages/windows-amd64'
    $manifest = Invoke-RestMethod -Uri "$base/list.json"
    $fileName = $manifest.releases.'0.8.24'
    $build = $manifest.builds | Where-Object { $_.path -eq $fileName }
    if (-not $build -or -not $build.sha256) { throw 'Solidity 0.8.24 checksum is missing.' }
    $downloadPath = "$solcPath.download"
    Write-Host 'Downloading official Solidity 0.8.24...'
    Invoke-WebRequest -Uri "$base/$fileName" -OutFile $downloadPath
    $actual = (Get-FileHash $downloadPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $build.sha256.Replace('0x', '').ToLowerInvariant()) {
        throw 'Solidity checksum mismatch.'
    }
    Move-Item -LiteralPath $downloadPath -Destination $solcPath
}
& (Join-Path $foundryDir 'forge.exe') --version
if ($LASTEXITCODE -ne 0) { throw 'Forge did not start.' }
& $solcPath --version
if ($LASTEXITCODE -ne 0) { throw 'Solidity did not start.' }
Write-Host 'Ready. Run: .\scripts\lab.ps1 test'
