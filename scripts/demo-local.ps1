# Reproduce Ex1 and Ex3 on a fresh private Anvil instance. No external chain is used.
[CmdletBinding()]
param([int]$Port = 18545)
$ErrorActionPreference = 'Stop'
$labRoot = Split-Path $PSScriptRoot -Parent
$evidenceDir = Join-Path $labRoot 'evidence'
New-Item -ItemType Directory -Path $evidenceDir -Force | Out-Null
$rpc = "http://127.0.0.1:$Port"
$transcript = [System.Collections.Generic.List[string]]::new()
$receipts = [System.Collections.Generic.List[object]]::new()
$snapshots = [System.Collections.Generic.List[object]]::new()
$anvilProcess = $null
$savedPrivateKey = $env:PRIVATE_KEY
$savedColor = $env:NO_COLOR

function Write-Demo([string]$Message) {
    $transcript.Add($Message)
    Write-Host $Message
}

function Invoke-Cast([string[]]$CastArgs, [bool]$AllowFailure = $false) {
    if ($CastArgs[0] -eq 'call') { $CastArgs += @('--private-key', $env:PRIVATE_KEY) }
    $displayArgs = $CastArgs.Clone()
    for ($i = 0; $i -lt $displayArgs.Length - 1; $i++) {
        if ($displayArgs[$i] -eq '--private-key') { $displayArgs[$i + 1] = '<public-Anvil-fixture>' }
    }
    Write-Demo ('cast ' + ($displayArgs -join ' ') + " --rpc-url $rpc")
    $result = & cast @CastArgs --rpc-url $rpc 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($result | Out-String).Trim()
    if ($exitCode -ne 0 -and -not $AllowFailure) { throw "cast failed: $text" }
    return $text
}

function Send-Demo([string]$Label, [string]$From, [string]$To, [string]$Signature, [string[]]$Values, [bool]$ExpectSuccess = $true) {
    # Explicit public fixture keys avoid Cast 1.8.4's default-keystore lookup on
    # a fresh Windows installation. These accounts belong only to this local chain.
    $fixtureKey = if ($From -eq $admin) { $env:PRIVATE_KEY } elseif ($From -eq $attacker) {
        '0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d'
    } else { throw 'Unknown local fixture account.' }
    $argsForCast = @('send', $To, $Signature) + $Values + @('--private-key', $fixtureKey, '--gas-limit', '500000', '--json')
    $receipt = (Invoke-Cast -CastArgs $argsForCast -AllowFailure (-not $ExpectSuccess)) | ConvertFrom-Json
    if ($receipt.PSObject.Properties.Name -contains 'schema_version') { $receipt = $receipt.data }
    if (-not $receipt.status) { throw "Missing transaction receipt for $Label" }
    $ok = $receipt.status -eq '0x1'
    if ($ok -ne $ExpectSuccess) { throw "Unexpected transaction status for $Label : $($receipt.status)" }
    $receipts.Add([pscustomobject]@{step=$Label; receipt=$receipt})
    Write-Demo "$Label : status=$($receipt.status), transaction=$($receipt.transactionHash)"
}

function Read-Uint([string]$To, [string]$Signature, [string[]]$Values = @()) {
    $result = Invoke-Cast -CastArgs (@('call', $To, $Signature) + $Values)
    $units = ($result -split '\s+')[0]
    Write-Demo "  -> $units"
    return [decimal]$units
}

function Save-Snapshot([string]$Stage) {
    Write-Demo "`n=== $Stage (all amounts in 6-decimal base units) ==="
    $state = [pscustomobject]@{
        stage = $Stage
        supply = Read-Uint $stable 'totalSupply()(uint256)'
        collateral = Read-Uint $vault 'totalCollateral()(uint256)'
        userStable = Read-Uint $stable 'balanceOf(address)(uint256)' @($admin)
        userCollateral = Read-Uint $usdc 'balanceOf(address)(uint256)' @($admin)
        attackerStable = Read-Uint $stable 'balanceOf(address)(uint256)' @($attacker)
    }
    $snapshots.Add($state)
    return $state
}

try {
    # Refuse to reuse an existing node: the demonstration must start from a blank chain.
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
    try { $listener.Start() } finally { $listener.Stop() }
    $anvilExe = (Get-Command anvil -ErrorAction Stop).Source
    $anvilProcess = Start-Process -FilePath $anvilExe -ArgumentList @('--host', '127.0.0.1', '--port', "$Port", '--silent') -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $evidenceDir 'anvil.log') -RedirectStandardError (Join-Path $evidenceDir 'anvil-error.log')
    $ready = $false
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        if ($anvilProcess.HasExited) { throw 'Anvil exited before becoming ready.' }
        try {
            $null = Invoke-RestMethod -Uri $rpc -Method Post -ContentType 'application/json' -Body '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}'
            $ready = $true
            break
        } catch { Start-Sleep -Milliseconds 200 }
    }
    if (-not $ready) { throw 'Anvil did not become ready.' }
    $env:NO_COLOR = '1'
    # Public Anvil account 0 fixture, supplied by the upstream Makefile. Never funded externally.
    $env:PRIVATE_KEY = '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80'
    Write-Demo "Local lab run: $([DateTime]::UtcNow.ToString('o'))"
    Write-Demo "Fresh Anvil, RPC $rpc, chain ID 31337"
    Write-Demo 'forge script script/Deploy.s.sol:Deploy --rpc-url <local Anvil> --broadcast'
    $deployOutput = & forge script script/Deploy.s.sol:Deploy --rpc-url $rpc --broadcast 2>&1
    $deployExit = $LASTEXITCODE
    $deployText = ($deployOutput | Out-String)
    $deployText.TrimEnd() | Set-Content (Join-Path $evidenceDir 'deployment.txt') -Encoding utf8
    if ($deployExit -ne 0) { throw "Deployment failed: $deployText" }
    $admin = [regex]::Match($deployText, 'admin\s*:\s*(0x[0-9a-fA-F]{40})').Groups[1].Value
    $usdc = [regex]::Match($deployText, 'MockUSDC\s*:\s*(0x[0-9a-fA-F]{40})').Groups[1].Value
    $stable = [regex]::Match($deployText, 'SimpleStablecoin\s*:\s*(0x[0-9a-fA-F]{40})').Groups[1].Value
    $vault = [regex]::Match($deployText, 'Vault\s*:\s*(0x[0-9a-fA-F]{40})').Groups[1].Value
    if (-not $admin -or -not $usdc -or -not $stable -or -not $vault) { throw 'Could not read deployment addresses.' }
    $accounts = (Invoke-Cast -CastArgs @('rpc', 'eth_accounts')) | ConvertFrom-Json
    $attacker = $accounts[1]
    Write-Demo "mUSDC=$usdc`nsUSD=$stable`nVault=$vault`nUser=$admin`nAttacker=$attacker"

    Send-Demo 'Ex1 faucet 1000 mUSDC' $admin $usdc 'faucet(address,uint256)' @($admin, '1000000000')
    Send-Demo 'Ex1 approve 1000 mUSDC' $admin $usdc 'approve(address,uint256)' @($vault, '1000000000')
    Send-Demo 'Ex1 deposit 1000 mUSDC' $admin $vault 'deposit(uint256)' @('1000000000')
    $deposit = Save-Snapshot 'Ex1 after deposit'
    if ($deposit.supply -ne 1000000000 -or $deposit.collateral -ne $deposit.supply -or $deposit.userStable -ne $deposit.supply) { throw 'Deposit accounting mismatch.' }
    Send-Demo 'Ex1 redeem 250 sUSD' $admin $vault 'redeem(uint256)' @('250000000')
    $redeem = Save-Snapshot 'Ex1 after redeem'
    if ($redeem.supply -ne 750000000 -or $redeem.collateral -ne $redeem.supply -or $redeem.userCollateral -ne 250000000 -or $redeem.userStable -ne 750000000) { throw 'Redemption accounting mismatch.' }

    Send-Demo 'Ex3 unauthorized mint correctly reverted' $attacker $stable 'mint(address,uint256)' @($attacker, '1000000000000') $false
    $role = Invoke-Cast -CastArgs @('call', $stable, 'MINTER_ROLE()(bytes32)')
    Send-Demo 'Ex3 admin grants MINTER_ROLE' $admin $stable 'grantRole(bytes32,address)' @($role, $attacker)
    Send-Demo 'Ex3 privileged mint without collateral' $attacker $stable 'mint(address,uint256)' @($attacker, '1000000000000')
    $broken = Save-Snapshot 'Ex3 unbacked issuance'
    if ($broken.supply -ne 1000750000000 -or $broken.collateral -ne 750000000 -or $broken.attackerStable -ne 1000000000000) { throw 'Role compromise demonstration mismatch.' }
    Write-Demo "`nEx3 result: totalSupply = $($broken.supply); totalCollateral = $($broken.collateral)"
    Write-Demo 'Supply = 1,000,750 sUSD; collateral = 750 mUSDC; unbacked gap = 1,000,000 tokens.'
    Write-Demo 'This demonstrates broken backing; no secondary-market price is measured.'
    Write-Demo 'PASS: Ex1 mint/redeem loop and Ex3 role-compromise demonstration.'
    $result = [pscustomobject]@{
        completedAtUtc = [DateTime]::UtcNow.ToString('o')
        chainId = 31337
        rpc = $rpc
        contracts = @{usdc=$usdc; stable=$stable; vault=$vault}
        snapshots = $snapshots.ToArray()
        transactions = $receipts.ToArray()
    }
    $result | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $evidenceDir 'ex1-ex3.json') -Encoding utf8
} finally {
    $transcript | Set-Content (Join-Path $evidenceDir 'ex1-ex3.txt') -Encoding utf8
    $env:PRIVATE_KEY = $savedPrivateKey
    $env:NO_COLOR = $savedColor
    if ($anvilProcess -and -not $anvilProcess.HasExited) { Stop-Process -Id $anvilProcess.Id }
}
