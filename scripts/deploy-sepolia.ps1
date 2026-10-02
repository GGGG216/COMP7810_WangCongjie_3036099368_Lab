#requires -Version 7.0
<#
.SYNOPSIS
Deploy the Tier 2 contracts to Sepolia and verify their source on Etherscan.
.DESCRIPTION
First configure PRIVATE_KEY, SEPOLIA_RPC_URL and ETHERSCAN_API_KEY in the ignored
project .env file, or in the process environment (which takes precedence).
Use a dedicated wallet containing Sepolia test ETH only. The script rejects zero
keys and the first 20 accounts from Anvil's publicly known default mnemonic.

    .\scripts\deploy-sepolia.ps1
    .\scripts\deploy-sepolia.ps1 -Mode VerifyOnly

VerifyOnly requires the RPC and Etherscan API key, but no private key. It reads
evidence/sepolia.json, or recovers public details from the Sepolia broadcast file,
and never broadcasts transactions. Use it after an Etherscan outage or failed
verification; do not deploy again. An interrupted/partial broadcast is recorded
as incomplete and must be inspected and resumed separately, not redeployed.

Only public addresses, transaction hashes, deployment/verification outcomes and
their metadata are saved to evidence/sepolia.json. Native tool output is captured
but never printed or saved, because errors can contain credentials. Foundry's
own broadcast/cache files remain ignored by Git. Existing Anvil evidence is not
changed. All process environment changes are restored on exit.
#>
[CmdletBinding()]
param(
    [ValidateSet('Deploy', 'VerifyOnly')]
    [string]$Mode = 'Deploy'
)

$ErrorActionPreference = 'Stop'
$labRoot = Split-Path $PSScriptRoot -Parent
$foundryDir = Join-Path $labRoot '.tools\foundry'
$forgeExe = Join-Path $foundryDir 'forge.exe'
$castExe = Join-Path $foundryDir 'cast.exe'
$solcPath = Join-Path $labRoot '.tools\solc-0.8.24.exe'
$evidencePath = Join-Path $labRoot 'evidence\sepolia.json'
$broadcastDir = Join-Path $labRoot 'broadcast\Deploy.s.sol\11155111'
$broadcastPath = Join-Path $broadcastDir 'run-latest.json'
$minterRole = '0x9f2df0fed2c77648de5860a4cc508cd0818c85b8b8a1ab4ceeef8d981c8956a6'
$contractSources = [ordered]@{
    MockUSDC = 'src/MockUSDC.sol:MockUSDC'
    SimpleStablecoin = 'src/SimpleStablecoin.sol:SimpleStablecoin'
    Vault = 'src/Vault.sol:Vault'
}
$managedNames = @('PRIVATE_KEY', 'SEPOLIA_RPC_URL', 'ETHERSCAN_API_KEY', 'PATH',
    'FOUNDRY_SOLC', 'FOUNDRY_PROFILE', 'NO_COLOR')
$savedEnvironment = @{}
foreach ($name in $managedNames) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
$locationPushed = $false
$runLock = $null

function Read-LabEnv {
    $values = @{}
    $envPath = Join-Path $labRoot '.env'
    if (-not (Test-Path -LiteralPath $envPath)) { return $values }
    $lineNumber = 0
    foreach ($line in [IO.File]::ReadAllLines($envPath)) {
        $lineNumber++
        if ($line -match '^\s*(#.*)?$') { continue }
        # Parse data, never evaluate shell expressions or expand $variables.
        if ($line -notmatch '^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
            throw ".env has invalid assignment syntax on line $lineNumber."
        }
        $name = $Matches[1]
        $raw = $Matches[2].Trim()
        if ($name -notin @('PRIVATE_KEY', 'SEPOLIA_RPC_URL', 'ETHERSCAN_API_KEY')) { continue }
        if ($values.ContainsKey($name)) { throw ".env repeats $name; keep one assignment." }
        if ($raw.StartsWith('"') -or $raw.StartsWith("'")) {
            $quote = [regex]::Escape($raw.Substring(0, 1))
            if ($raw -notmatch ("^$quote(.*?)$quote\s*(?:#.*)?$")) {
                throw ".env has an unmatched quote on line $lineNumber."
            }
            $values[$name] = $Matches[1]
        } else {
            $values[$name] = ($raw -replace '\s+#.*$', '').Trim()
        }
    }
    return $values
}

function Invoke-LabTool([string]$Executable, [string[]]$ToolArgs) {
    # ArgumentList bypasses shell parsing. Secrets are inherited as environment
    # variables, never included in the command line or in messages to the user.
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Executable
    $startInfo.WorkingDirectory = $labRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $ToolArgs) { $startInfo.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        $null = $process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Output = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
        }
    } finally {
        $process.Dispose()
    }
}

function Assert-PrivateKey {
    $key = $env:PRIVATE_KEY
    if ($key -notmatch '^(?:0x)?[0-9a-fA-F]{64}$') {
        throw 'Set PRIVATE_KEY to a dedicated Sepolia wallet key in the ignored .env file.'
    }
    $hex = ($key -replace '^0x', '').ToLowerInvariant()
    $curveOrder = 'fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141'
    if ($hex -match '^0+$' -or [string]::Compare($hex, $curveOrder, [StringComparison]::Ordinal) -ge 0) {
        throw 'PRIVATE_KEY is zero or outside the valid secp256k1 range. Replace the .env placeholder with your dedicated Sepolia key.'
    }
    $env:PRIVATE_KEY = "0x$hex"
    $publicMnemonic = 'test test test test test test test test test test test junk'
    foreach ($index in 0..19) {
        $fixture = Invoke-LabTool $castExe @('wallet', 'private-key', $publicMnemonic, "$index")
        if ($fixture.ExitCode -ne 0 -or $fixture.Output.Trim() -notmatch '^0x[0-9a-fA-F]{64}$') {
            throw 'Could not validate the public Anvil fixture key denylist; no broadcast was attempted.'
        }
        if ($env:PRIVATE_KEY -eq $fixture.Output.Trim()) {
            throw 'Refusing a publicly known Anvil fixture key. Use your own dedicated Sepolia wallet.'
        }
    }
}

function Invoke-SepoliaRpc([string]$Method, [object[]]$RpcParams = @()) {
    try {
        $request = @{jsonrpc = '2.0'; id = 1; method = $Method; params = $RpcParams} | ConvertTo-Json -Depth 5 -Compress
        $response = Invoke-RestMethod -Uri $env:SEPOLIA_RPC_URL -Method Post -ContentType 'application/json' -Body $request -TimeoutSec 30
    } catch {
        throw "Sepolia RPC request failed ($Method). Check SEPOLIA_RPC_URL and connectivity; endpoint details were suppressed."
    }
    if ($null -ne $response.error -or $null -eq $response.result) {
        throw "Sepolia RPC returned an invalid response for $Method; endpoint details were suppressed."
    }
    return $response.result
}

function Assert-Sepolia {
    $uri = $null
    if (-not [uri]::TryCreate($env:SEPOLIA_RPC_URL, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https') {
        throw 'SEPOLIA_RPC_URL must be an absolute HTTPS endpoint.'
    }
    $chain = Invoke-SepoliaRpc 'eth_chainId'
    if ($chain -notmatch '^0x[0-9a-fA-F]+$') { throw 'RPC returned an invalid chain ID; no broadcast was attempted.' }
    try { $chainId = [Convert]::ToUInt64($chain.Substring(2), 16) }
    catch { throw 'RPC returned an invalid chain ID; no broadcast was attempted.' }
    if ($chainId -ne 11155111) { throw 'RPC is not Ethereum Sepolia (11155111); refusing this endpoint.' }
}

function Test-Address([object]$Value) {
    return $Value -is [string] -and $Value -match '^0x[0-9a-fA-F]{40}$' -and $Value -notmatch '^0x0{40}$'
}

function Test-TxHash([object]$Value) {
    return $Value -is [string] -and $Value -match '^0x[0-9a-fA-F]{64}$'
}

function Save-PublicEvidence([object]$Evidence) {
    $directory = Split-Path $evidencePath -Parent
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $tempPath = Join-Path $directory 'sepolia.json.tmp'
    $Evidence | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $tempPath -Encoding utf8
    Move-Item -LiteralPath $tempPath -Destination $evidencePath -Force
}

function Read-BroadcastEvidence {
    try { $broadcast = Get-Content -LiteralPath $broadcastPath -Raw | ConvertFrom-Json }
    catch { throw 'Cannot parse the Sepolia broadcast artifact. It has been preserved for inspection.' }
    if ($broadcast.chain -ne 11155111) { throw 'Broadcast artifact has the wrong chain ID.' }
    $contracts = [ordered]@{}
    $publicTransactions = [Collections.Generic.List[object]]::new()
    $deployer = $null
    $grantConfirmed = $false
    foreach ($tx in $broadcast.transactions) {
        if ($tx.contractName -notin $contractSources.Keys) { continue }
        if ($tx.transaction.chainId -ne '0xaa36a7') { throw 'A broadcast transaction targets the wrong chain.' }
        if (-not (Test-Address $tx.transaction.from)) { throw 'A deployment sender is invalid.' }
        if ($null -eq $deployer) { $deployer = $tx.transaction.from }
        if ($deployer -ne $tx.transaction.from) { throw 'Unexpected mixed deployment senders.' }
        $receipt = @($broadcast.receipts | Where-Object { $_.transactionHash -eq $tx.hash -and (Test-TxHash $_.transactionHash) })
        $status = 'pending'
        if ($receipt.Count -eq 1) { $status = if ($receipt[0].status -eq '0x1') { 'confirmed' } else { 'failed' } }
        if (Test-TxHash $tx.hash) {
            $publicTransactions.Add([ordered]@{hash = $tx.hash; contract = $tx.contractName; status = $status})
        }
        if ($tx.transactionType -eq 'CREATE' -and (Test-Address $tx.contractAddress)) {
            if ($contracts.Contains($tx.contractName)) { throw 'Unexpected duplicate contract deployment in the broadcast artifact.' }
            if ($status -eq 'confirmed' -and $receipt[0].contractAddress -ne $tx.contractAddress) {
                throw 'Deployment receipt and contract address do not match.'
            }
            $contracts[$tx.contractName] = [ordered]@{
                address = $tx.contractAddress
                transactionHash = if (Test-TxHash $tx.hash) { $tx.hash } else { $null }
                deployment = $status
                verification = 'pending'
                explorerUrl = "https://sepolia.etherscan.io/address/$($tx.contractAddress)#code"
            }
        }
        if ($tx.transactionType -eq 'CALL' -and $tx.contractName -eq 'SimpleStablecoin' -and
            $tx.function -eq 'grantRole(bytes32,address)' -and $status -eq 'confirmed' -and
            $tx.arguments.Count -eq 2 -and $tx.arguments[0] -eq $minterRole -and
            $contracts.Contains('Vault') -and $contracts.Contains('SimpleStablecoin') -and
            $tx.arguments[1] -eq $contracts.Vault.address -and $tx.contractAddress -eq $contracts.SimpleStablecoin.address) {
            $grantConfirmed = $true
        }
    }
    $complete = $grantConfirmed -and $contracts.Count -eq 3
    foreach ($name in $contractSources.Keys) {
        if (-not $contracts.Contains($name) -or $contracts[$name].deployment -ne 'confirmed') { $complete = $false }
    }
    return [ordered]@{
        chainId = 11155111
        recordedAtUtc = [DateTime]::UtcNow.ToString('o')
        deployer = $deployer
        deployment = if ($complete) { 'complete' } else { 'incomplete' }
        vaultMinterRole = if ($grantConfirmed) { 'confirmed' } else { 'unconfirmed' }
        contracts = $contracts
        transactions = $publicTransactions.ToArray()
    }
}

function Read-SavedEvidence {
    try { $saved = Get-Content -LiteralPath $evidencePath -Raw | ConvertFrom-Json -AsHashtable }
    catch { throw 'Cannot parse evidence/sepolia.json. The existing evidence has been preserved.' }
    if ($saved.chainId -ne 11155111 -or -not (Test-Address $saved.deployer) -or
        $saved.deployment -notin @('complete', 'incomplete') -or
        $saved.vaultMinterRole -notin @('confirmed', 'unconfirmed')) { throw 'Invalid Sepolia evidence metadata.' }
    # Whitelist public fields when re-saving; never copy arbitrary file contents.
    $contracts = [ordered]@{}
    foreach ($name in $contractSources.Keys) {
        if (-not $saved.contracts.ContainsKey($name)) { continue }
        $entry = $saved.contracts[$name]
        if (-not (Test-Address $entry.address) -or $entry.deployment -notin @('pending', 'confirmed', 'failed') -or
            ($null -ne $entry.transactionHash -and -not (Test-TxHash $entry.transactionHash)) -or
            $entry.verification -notin @('pending', 'verified', 'failed')) { throw "Invalid public deployment record for $name." }
        $contracts[$name] = [ordered]@{
            address = $entry.address
            transactionHash = $entry.transactionHash
            deployment = $entry.deployment
            verification = $entry.verification
            explorerUrl = "https://sepolia.etherscan.io/address/$($entry.address)#code"
        }
    }
    $transactions = @()
    foreach ($tx in $saved.transactions) {
        if (-not (Test-TxHash $tx.hash) -or $tx.contract -notin $contractSources.Keys -or
            $tx.status -notin @('pending', 'confirmed', 'failed')) { throw 'Invalid public transaction record.' }
        $transactions += [ordered]@{hash = $tx.hash; contract = $tx.contract; status = $tx.status}
    }
    return [ordered]@{
        chainId = 11155111
        recordedAtUtc = [DateTime]::UtcNow.ToString('o')
        deployer = $saved.deployer
        deployment = $saved.deployment
        vaultMinterRole = $saved.vaultMinterRole
        contracts = $contracts
        transactions = $transactions
    }
}

try {
    $fileValues = Read-LabEnv
    foreach ($name in @('PRIVATE_KEY', 'SEPOLIA_RPC_URL', 'ETHERSCAN_API_KEY')) {
        if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name, 'Process')) -and $fileValues.ContainsKey($name)) {
            [Environment]::SetEnvironmentVariable($name, $fileValues[$name], 'Process')
        }
    }
    # Fail before any network request or filesystem mutation when credentials are absent.
    if ($Mode -eq 'Deploy' -and [string]::IsNullOrWhiteSpace($env:PRIVATE_KEY)) {
        throw 'Configure PRIVATE_KEY, SEPOLIA_RPC_URL and ETHERSCAN_API_KEY in the ignored .env file first.'
    }
    foreach ($tool in @($forgeExe, $castExe, $solcPath)) {
        if (-not (Test-Path -LiteralPath $tool)) { throw 'Run .\scripts\setup-windows.ps1 first.' }
    }
    $env:PATH = "$foundryDir;$env:PATH"
    $env:FOUNDRY_SOLC = $solcPath
    $env:FOUNDRY_PROFILE = 'default'
    $env:NO_COLOR = '1'
    Push-Location $labRoot
    $locationPushed = $true
    if ($Mode -eq 'Deploy') { Assert-PrivateKey }
    foreach ($name in @('SEPOLIA_RPC_URL', 'ETHERSCAN_API_KEY')) {
        if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name, 'Process'))) {
            throw "Configure $name in the ignored .env file before running Tier 2."
        }
    }
    Assert-Sepolia
    New-Item -ItemType Directory -Path $broadcastDir -Force | Out-Null
    try { $runLock = [IO.File]::Open((Join-Path $broadcastDir '.tier2.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch { throw 'Another Sepolia workflow is already running. Wait for it to finish.' }

    if ($Mode -eq 'Deploy') {
        if ((Test-Path -LiteralPath $evidencePath) -or (Test-Path -LiteralPath $broadcastPath)) {
            throw 'Sepolia deployment evidence already exists. Use -Mode VerifyOnly; inspect and resume any incomplete broadcast separately instead of redeploying.'
        }
        # Recheck immediately before the only command that can submit transactions.
        Assert-Sepolia
        Write-Host 'Deploying MockUSDC, SimpleStablecoin and Vault to Ethereum Sepolia (11155111)...'
        $result = Invoke-LabTool $forgeExe @('script', 'script/Deploy.s.sol:Deploy', '--rpc-url', 'sepolia', '--chain', 'sepolia', '--broadcast', '--slow', '--non-interactive')
        if (Test-Path -LiteralPath $broadcastPath) {
            $evidence = Read-BroadcastEvidence
            Save-PublicEvidence $evidence
        } else {
            throw 'Forge did not produce a Sepolia broadcast artifact. No deployment success is claimed; inspect local state before retrying.'
        }
        if ($result.ExitCode -ne 0 -or $evidence.deployment -ne 'complete') {
            throw 'Sepolia deployment was not confirmed complete. Public evidence is preserved; inspect the broadcast artifact and resume it rather than deploying again.'
        }
    } elseif (Test-Path -LiteralPath $evidencePath) {
        $evidence = Read-SavedEvidence
        # A manually resumed broadcast can upgrade previously incomplete evidence.
        if ($evidence.deployment -eq 'incomplete' -and (Test-Path -LiteralPath $broadcastPath)) {
            $recovered = Read-BroadcastEvidence
            if ($recovered.deployer -ne $evidence.deployer) { throw 'Resumed broadcast has a different deployer.' }
            foreach ($name in $evidence.contracts.Keys) {
                if (-not $recovered.contracts.Contains($name) -or $recovered.contracts[$name].address -ne $evidence.contracts[$name].address) {
                    throw 'Resumed broadcast does not match the existing deployment addresses.'
                }
            }
            $evidence = $recovered
            Save-PublicEvidence $evidence
        }
    } elseif (Test-Path -LiteralPath $broadcastPath) {
        $evidence = Read-BroadcastEvidence
        Save-PublicEvidence $evidence
    } else {
        throw 'No Sepolia deployment exists to verify. Configure the three credentials and run deployment first.'
    }

    if ($evidence.deployment -ne 'complete' -or $evidence.contracts.Count -ne 3 -or $evidence.vaultMinterRole -ne 'confirmed') {
        throw 'Deployment is incomplete. Verification does not submit missing transactions; inspect and resume the existing broadcast first.'
    }
    $failed = [Collections.Generic.List[string]]::new()
    foreach ($name in $contractSources.Keys) {
        $entry = $evidence.contracts[$name]
        $code = Invoke-SepoliaRpc 'eth_getCode' @($entry.address, 'latest')
        if ($entry.deployment -ne 'confirmed' -or $code -notmatch '^0x[0-9a-fA-F]+$' -or $code -eq '0x0') {
            throw "No confirmed contract code at the recorded $name address. Evidence was preserved."
        }
        $verifyArgs = @('verify-contract', $entry.address, $contractSources[$name], '--chain', 'sepolia',
            '--verifier', 'etherscan', '--compiler-version', '0.8.24+commit.e11b9ed9',
            '--num-of-optimizations', '200', '--watch', '--retries', '10', '--delay', '6')
        # Constructor arguments are only public addresses; encode locally without RPC.
        if ($name -eq 'SimpleStablecoin') {
            $encoded = Invoke-LabTool $castExe @('abi-encode', 'constructor(address)', $evidence.deployer)
        } elseif ($name -eq 'Vault') {
            $encoded = Invoke-LabTool $castExe @('abi-encode', 'constructor(address,address)', $evidence.contracts.MockUSDC.address, $evidence.contracts.SimpleStablecoin.address)
        } else { $encoded = $null }
        if ($null -ne $encoded) {
            if ($encoded.ExitCode -ne 0 -or $encoded.Output.Trim() -notmatch '^0x[0-9a-fA-F]+$') { throw 'Could not encode public constructor arguments.' }
            $verifyArgs += @('--constructor-args', $encoded.Output.Trim())
        }
        Write-Host "Verifying $name at $($entry.address)..."
        $verified = Invoke-LabTool $forgeExe $verifyArgs
        $entry.verification = if ($verified.ExitCode -eq 0) { 'verified' } else { 'failed' }
        Save-PublicEvidence $evidence
        Write-Host "$name verification: $($entry.verification)"
        if ($verified.ExitCode -ne 0) { $failed.Add($name) }
    }
    if ($failed.Count -ne 0) {
        throw ('Deployment is preserved; verification failed for ' + ($failed -join ', ') + '. Check ETHERSCAN_API_KEY and retry: .\scripts\deploy-sepolia.ps1 -Mode VerifyOnly')
    }
    Write-Host 'Tier 2 complete. Public addresses and verified source links are in evidence/sepolia.json.'
} finally {
    if ($null -ne $runLock) { $runLock.Dispose() }
    if ($locationPushed) { Pop-Location }
    foreach ($name in $managedNames) {
        if ($null -eq $savedEnvironment[$name]) {
            Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
        } else {
            [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process')
        }
    }
}
