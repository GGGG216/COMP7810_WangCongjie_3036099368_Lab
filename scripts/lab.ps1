[CmdletBinding()]
param(
    [ValidateSet('doctor', 'core', 'test', 'exercise', 'challenge', 'fmt', 'demo')]
    [string]$Task = 'test'
)
$ErrorActionPreference = 'Stop'
$labRoot = Split-Path $PSScriptRoot -Parent
$foundryDir = Join-Path $labRoot '.tools\foundry'
$solcPath = Join-Path $labRoot '.tools\solc-0.8.24.exe'
if (-not (Test-Path "$foundryDir\forge.exe") -or -not (Test-Path $solcPath)) {
    throw 'Run .\scripts\setup-windows.ps1 first.'
}
$savedPath = $env:PATH
$savedSolc = $env:FOUNDRY_SOLC
try {
    $env:PATH = "$foundryDir;$env:PATH"
    $env:FOUNDRY_SOLC = $solcPath
    Push-Location $labRoot
    switch ($Task) {
        'doctor' {
            foreach ($tool in @('forge', 'cast', 'anvil')) {
                & $tool --version
                if ($LASTEXITCODE -ne 0) { throw "$tool failed." }
            }
            foreach ($dependency in @('lib\forge-std\src\Test.sol', 'lib\openzeppelin-contracts\contracts\token\ERC20\ERC20.sol')) {
                if (-not (Test-Path $dependency)) { throw "Missing $dependency" }
            }
            forge test --no-match-path 'test/{challenges,exercises}/*' -vv
        }
        'core' { forge test --no-match-path 'test/{challenges,exercises}/*' -vv }
        'test' { forge test -vv }
        'exercise' { forge test --match-path 'test/exercises/*.t.sol' -vv }
        'challenge' { forge test --match-path 'test/challenges/Unstoppable.t.sol' -vv }
        'fmt' {
            forge fmt --check src/exercises/OverCollateralizedVault.sol test/exercises/01_LoopTasks.t.sol test/exercises/02_InvariantTasks.t.sol test/exercises/04_OverCollateralEdgeCases.t.sol test/challenges/Unstoppable.t.sol
        }
        'demo' { & (Join-Path $PSScriptRoot 'demo-local.ps1'); return }
    }
    if ($LASTEXITCODE -ne 0) { throw "Lab task '$Task' failed (exit $LASTEXITCODE)." }
} finally {
    Pop-Location
    $env:PATH = $savedPath
    $env:FOUNDRY_SOLC = $savedSolc
}
