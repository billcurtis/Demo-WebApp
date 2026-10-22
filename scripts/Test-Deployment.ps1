#Requires -Version 5.1
<#
.SYNOPSIS
    Tests the Cloud Gone Wild website endpoint.
.DESCRIPTION
    Retries until the root address returns HTTP 200 with the expected headline, then
    confirms the stylesheet and script are served. Exits 1 on failure.
.EXAMPLE
    ./scripts/Test-Deployment.ps1 -Url https://example.azurewebsites.net
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^https://')]
    [string]$Url,

    [string]$ExpectedText = 'You deployed another website nobody asked for',

    [ValidateRange(1, 120)]
    [int]$MaxAttempts = 30,

    [ValidateRange(1, 120)]
    [int]$DelaySeconds = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$base = $Url.TrimEnd('/')

function Invoke-Probe {
    param([string]$Target)
    try {
        $r = Invoke-WebRequest -Uri $Target -UseBasicParsing -TimeoutSec 30 -Headers @{ 'Cache-Control' = 'no-cache' }
        return [pscustomobject]@{ Status = [int]$r.StatusCode; Content = [string]$r.Content; Error = $null }
    }
    catch {
        $status = 0
        if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) {
            $status = [int]$_.Exception.Response.StatusCode
        }
        return [pscustomobject]@{ Status = $status; Content = ''; Error = $_.Exception.Message }
    }
}

$rootOk = $false
for ($i = 1; $i -le $MaxAttempts; $i++) {
    $p = Invoke-Probe -Target "$base/"
    if ($p.Status -eq 200 -and $p.Content -like "*$ExpectedText*") {
        Write-Host "[$i/$MaxAttempts] $base/ -> HTTP 200 with expected headline."
        $rootOk = $true
        break
    }
    $why = if ($p.Status -eq 200) { 'HTTP 200 but headline not found (site content may still be propagating)' } elseif ($p.Error) { $p.Error } else { "HTTP $($p.Status)" }
    Write-Host "[$i/$MaxAttempts] $base/ -> $why. Retrying in $DelaySeconds s..."
    Start-Sleep -Seconds $DelaySeconds
}

if (-not $rootOk) {
    Write-Host "Endpoint test FAILED: $base/ did not return HTTP 200 with the expected headline after $MaxAttempts attempts." -ForegroundColor Red
    exit 1
}

$failed = @()
foreach ($asset in 'styles.css', 'script.js') {
    $p = Invoke-Probe -Target "$base/$asset"
    if ($p.Status -eq 200) {
        Write-Host "$base/$asset -> HTTP 200"
    }
    else {
        $failed += $asset
        Write-Host "$base/$asset -> HTTP $($p.Status) $($p.Error)"
    }
}

if ($failed.Count -gt 0) {
    Write-Host "Endpoint test FAILED: assets not served: $($failed -join ', ')." -ForegroundColor Red
    exit 1
}

Write-Host "Endpoint test PASSED: $base/"
exit 0
