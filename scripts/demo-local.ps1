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
    if ($CastArgs[0] -eq 'call') { $CastArgs += @('--private-key', $ephemeralAdminKey) }
    $displayArgs = $CastArgs.Clone()
    for ($i = 0; $i -lt $displayArgs.Length - 1; $i++) {
        if ($displayArgs[$i] -eq '--private-key') { $displayArgs[$i + 1] = '<ephemeral-local-key>' }
    }
    Write-Demo ('cast ' + ($displayArgs -join ' ') + " --rpc-url $rpc")
    $result = & cast @CastArgs --rpc-url $rpc 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($result | Out-String).Trim()
    if ($exitCode -ne 0 -and -not $AllowFailure) { throw "cast failed: $text" }
    return $text
}

function Send-Demo([string]$Label, [string]$From, [string]$To, [string]$Signature, [string[]]$Values, [bool]$ExpectSuccess = $true) {
    # Fresh keys exist only in memory, and their accounts are funded only on Anvil.
    $fixtureKey = if ($From -eq $admin) { $ephemeralAdminKey } elseif ($From -eq $attacker) {
        $ephemeralAttackerKey
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
    $walletResult = & cast wallet new --number 2 --json 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Could not generate temporary local test accounts.' }
    $wallets = $walletResult | ConvertFrom-Json
    if ($wallets.PSObject.Properties.Name -contains 'schema_version') { $wallets = $wallets.data }
    if (@($wallets).Count -ne 2) { throw 'Expected two temporary local test accounts.' }
    $ephemeralAdminKey = $wallets[0].private_key
    $ephemeralAttackerKey = $wallets[1].private_key
    $attacker = $wallets[1].address
    foreach ($key in @($ephemeralAdminKey, $ephemeralAttackerKey)) {
        if ($key -notmatch '^0x[0-9a-fA-F]{64}$') { throw 'Invalid temporary local key.' }
    }
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
    foreach ($wallet in $wallets) {
        $fundRequest = @{jsonrpc='2.0'; id=1; method='anvil_setBalance'; params=@($wallet.address, '0x21e19e0c9bab2400000')} | ConvertTo-Json -Compress
        $fundResult = Invoke-RestMethod -Uri $rpc -Method Post -ContentType 'application/json' -Body $fundRequest
        if ($null -ne $fundResult.error) { throw 'Could not fund the temporary local account.' }
    }
    $env:PRIVATE_KEY = $ephemeralAdminKey
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
