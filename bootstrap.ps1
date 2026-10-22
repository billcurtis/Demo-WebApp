#Requires -Version 5.1
<#
.SYNOPSIS
    End-to-end bootstrap for the Cloud Gone Wild demo (billcurtis/Demo-WebApp).

.DESCRIPTION
    1. Checks prerequisites (Git, Terraform, Azure CLI, GitHub CLI).
    2. Validates the local repository and its GitHub remote.
    3. Signs in to Azure and GitHub interactively and verifies access.
    4. Creates and pushes a timestamped backup branch (once) without touching the working tree.
    5. Applies infra/bootstrap (state storage, Entra app, OIDC federated credential, RBAC).
    6. Sets GitHub Actions secrets and variables from the bootstrap outputs.
    7. Initializes and validates infra/app against the remote backend.
    8. Commits and pushes to the default branch, monitors the deploy workflow,
       and tests the public website.

    Safe to rerun: Terraform only changes what drifted, the backup branch is created once,
    and an unchanged commit is not re-pushed.

.EXAMPLE
    .\bootstrap.ps1

.EXAMPLE
    .\bootstrap.ps1 -ReuseExistingLogin
#>
[CmdletBinding()]
param(
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$SubscriptionId = 'f1a77dc4-b955-4493-bb61-64b356fd32ae',

    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
    [string]$Repository = 'billcurtis/Demo-WebApp',

    [string]$Location = 'eastus',
    [string]$Prefix = 'bill-demo-webapp',
    [string]$Environment = 'dev',
    [string]$StateKey = 'cloud-gone-wild/dev/app.tfstate',

    # Override only if the GitHub default branch cannot be detected.
    [string]$DefaultBranch = '',

    # Skip the interactive sign-ins when the existing Azure and GitHub sessions are already valid.
    [switch]$ReuseExistingLogin,

    [string]$CommitMessage = 'Deploy Cloud Gone Wild demo website'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$RepoRoot = $PSScriptRoot
$BootstrapDir = Join-Path $RepoRoot 'infra/bootstrap'
$AppDir = Join-Path $RepoRoot 'infra/app'
$BackupPattern = 'backup-before-cloud-demo-'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Step([string]$Message) {
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Ok([string]$Message) { Write-Host "    [ok] $Message" -ForegroundColor Green }
function Write-Info([string]$Message) { Write-Host "    $Message" }

function Stop-Bootstrap([string]$Message) {
    Write-Host ''
    Write-Host "STOPPED: $Message" -ForegroundColor Red
    exit 1
}

# Runs a native command and stops on a non-zero exit code. Returns trimmed stdout.
function Invoke-Native {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$FailureMessage = '',
        [switch]$AllowFailure
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $FilePath @Arguments
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $prev
    }
    if ($code -ne 0 -and -not $AllowFailure) {
        $msg = if ($FailureMessage) { $FailureMessage } else { "'$FilePath $($Arguments -join ' ')' failed with exit code $code." }
        Stop-Bootstrap $msg
    }
    if ($null -eq $out) { return '' }
    return (($out | ForEach-Object { "$_" }) -join "`n").Trim()
}

function Test-NativeSuccess {
    param([string]$FilePath, [string[]]$Arguments)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $FilePath @Arguments *> $null
        return ($LASTEXITCODE -eq 0)
    }
    finally {
        $ErrorActionPreference = $prev
    }
}

# ---------------------------------------------------------------------------
# 1. Prerequisites
# ---------------------------------------------------------------------------

Write-Step 'Checking prerequisites'

$prereqs = [ordered]@{
    git       = 'winget install --id Git.Git -e   (https://git-scm.com/download/win)'
    terraform = 'winget install --id Hashicorp.Terraform -e   (https://developer.hashicorp.com/terraform/install)'
    az        = 'winget install --id Microsoft.AzureCLI -e   (https://learn.microsoft.com/cli/azure/install-azure-cli-windows)'
    gh        = 'winget install --id GitHub.cli -e   (https://cli.github.com/)'
}
$missing = @()
foreach ($tool in $prereqs.Keys) {
    if (Get-Command $tool -ErrorAction SilentlyContinue) {
        Write-Ok "$tool found"
    }
    else {
        Write-Host "    [missing] $tool -> install with: $($prereqs[$tool])" -ForegroundColor Yellow
        $missing += $tool
    }
}
if ($missing.Count -gt 0) {
    Stop-Bootstrap "Install the missing tools ($($missing -join ', ')), open a new PowerShell window, and rerun .\bootstrap.ps1."
}

$tfVersion = (Invoke-Native terraform @('version', '-json') | ConvertFrom-Json).terraform_version
if ([version]$tfVersion -lt [version]'1.9.0') {
    Stop-Bootstrap "Terraform $tfVersion is too old. Install 1.9.0 or later."
}
Write-Ok "Terraform $tfVersion"

# ---------------------------------------------------------------------------
# 2. Repository validation
# ---------------------------------------------------------------------------

Write-Step 'Validating local repository'

$top = Invoke-Native git @('-C', $RepoRoot, 'rev-parse', '--show-toplevel') -FailureMessage "$RepoRoot is not a Git repository. Run bootstrap.ps1 from the root of a clone of $Repository."
if ((Resolve-Path $top).Path.TrimEnd('\', '/') -ne (Resolve-Path $RepoRoot).Path.TrimEnd('\', '/')) {
    Stop-Bootstrap "bootstrap.ps1 must live at the repository root. Found Git root '$top'."
}
Set-Location $RepoRoot

$remote = Invoke-Native git @('remote', 'get-url', 'origin') -FailureMessage "No 'origin' remote. Add it with: git remote add origin https://github.com/$Repository.git"
$remotePattern = '(?i)github\.com[:/]' + [regex]::Escape($Repository) + '(\.git)?/?$'
if ($remote -notmatch $remotePattern) {
    Stop-Bootstrap "The origin remote ($remote) does not point to github.com/$Repository."
}
Write-Ok "origin -> $Repository"

foreach ($path in @($BootstrapDir, $AppDir, (Join-Path $RepoRoot 'site/index.html'), (Join-Path $RepoRoot '.github/workflows/deploy.yml'))) {
    if (-not (Test-Path $path)) { Stop-Bootstrap "Expected path is missing: $path" }
}
Write-Ok 'Solution files present'

# ---------------------------------------------------------------------------
# 3. Azure sign-in
# ---------------------------------------------------------------------------

Write-Step 'Signing in to Azure'

$azReady = $false
if ($ReuseExistingLogin) {
    $azReady = Test-NativeSuccess az @('account', 'show', '--subscription', $SubscriptionId, '--only-show-errors', '-o', 'none')
    if ($azReady) { Write-Ok 'Reusing existing Azure CLI session' }
}
if (-not $azReady) {
    Write-Info 'A browser window will open. Sign in with an account that is Owner (or Owner-equivalent) on the subscription.'
    Invoke-Native az @('login', '--only-show-errors', '-o', 'none') -FailureMessage 'az login failed. Rerun the script and complete the sign-in.' | Out-Null
}

Invoke-Native az @('account', 'set', '--subscription', $SubscriptionId, '--only-show-errors') -FailureMessage "The signed-in account cannot access subscription $SubscriptionId." | Out-Null
$account = Invoke-Native az @('account', 'show', '--only-show-errors', '-o', 'json') | ConvertFrom-Json
if ($account.id -ne $SubscriptionId) {
    Stop-Bootstrap "Active subscription is $($account.id), expected $SubscriptionId. Nothing was changed."
}
$TenantId = $account.tenantId
$env:ARM_SUBSCRIPTION_ID = $SubscriptionId
$env:ARM_TENANT_ID = $TenantId
Write-Ok "Subscription: $($account.name) ($SubscriptionId)"
Write-Ok "Tenant:       $TenantId"
Write-Ok "Signed in as: $($account.user.name)"

$myOid = Invoke-Native az @('ad', 'signed-in-user', 'show', '--query', 'id', '-o', 'tsv', '--only-show-errors') -AllowFailure
if ($myOid) {
    $roles = Invoke-Native az @('role', 'assignment', 'list', '--assignee', $myOid, '--scope', "/subscriptions/$SubscriptionId", '--include-inherited', '--query', '[].roleDefinitionName', '-o', 'tsv', '--only-show-errors') -AllowFailure
    if ($roles -notmatch '(?m)^(Owner|User Access Administrator|Role Based Access Control Administrator)$') {
        Stop-Bootstrap 'The signed-in account needs Owner (or Contributor + User Access Administrator) on the subscription to create the custom role and role assignments.'
    }
    Write-Ok 'Azure RBAC rights sufficient for role assignments'
}

# ---------------------------------------------------------------------------
# 4. GitHub sign-in and repository access
# ---------------------------------------------------------------------------

Write-Step 'Signing in to GitHub'

$ghReady = $false
if ($ReuseExistingLogin) {
    $ghReady = Test-NativeSuccess gh @('auth', 'status', '--hostname', 'github.com')
    if ($ghReady) { Write-Ok 'Reusing existing GitHub CLI session' }
}
if (-not $ghReady) {
    & gh auth login --hostname github.com --git-protocol https --web --scopes 'repo,workflow'
    if ($LASTEXITCODE -ne 0) { Stop-Bootstrap 'gh auth login failed. Rerun the script and complete the sign-in.' }
}
if (-not (Test-NativeSuccess gh @('auth', 'status', '--hostname', 'github.com'))) {
    Stop-Bootstrap 'GitHub CLI is not authenticated. Run: gh auth login'
}
Invoke-Native gh @('auth', 'setup-git', '--hostname', 'github.com') -AllowFailure | Out-Null

$repoInfo = Invoke-Native gh @('repo', 'view', $Repository, '--json', 'nameWithOwner,viewerPermission,defaultBranchRef,isEmpty') -FailureMessage "Cannot access $Repository with the signed-in GitHub account." | ConvertFrom-Json
if ($repoInfo.viewerPermission -ne 'ADMIN') {
    Stop-Bootstrap "Admin permission on $Repository is required to set Actions secrets (current: $($repoInfo.viewerPermission))."
}
Write-Ok "Admin access to $($repoInfo.nameWithOwner)"

# ---------------------------------------------------------------------------
# 5. Default branch
# ---------------------------------------------------------------------------

Write-Step 'Determining default branch'

if (-not $DefaultBranch) {
    $detected = ''
    if ($repoInfo.defaultBranchRef -and $repoInfo.defaultBranchRef.name) { $detected = $repoInfo.defaultBranchRef.name }
    # An empty repo, or one whose first pushed branch was the backup, has no meaningful default yet.
    if (-not $detected -or $detected.StartsWith($BackupPattern)) {
        $detected = 'main'
        Write-Info "GitHub has no usable default branch yet; using '$detected'."
    }
    $DefaultBranch = $detected
}
$currentBranch = Invoke-Native git @('symbolic-ref', '--short', 'HEAD') -FailureMessage 'HEAD is detached. Check out the default branch first.'
if ($currentBranch -ne $DefaultBranch) {
    Stop-Bootstrap "Current branch is '$currentBranch' but the default branch is '$DefaultBranch'. Run: git switch $DefaultBranch"
}
Write-Ok "Default branch: $DefaultBranch"

# ---------------------------------------------------------------------------
# 6. Backup branch (created once, working tree untouched)
# ---------------------------------------------------------------------------

Write-Step 'Ensuring a backup branch exists'

$existingBackups = Invoke-Native git @('ls-remote', '--heads', 'origin', "refs/heads/$BackupPattern*") -FailureMessage 'Could not list remote branches. Check GitHub authentication.'
if ($existingBackups) {
    $names = ($existingBackups -split "`n" | ForEach-Object { ($_ -split 'refs/heads/')[1] }) -join ', '
    Write-Ok "Backup branch already on GitHub: $names (not recreated)"
}
else {
    $BackupBranch = $BackupPattern + (Get-Date -Format 'yyyyMMdd-HHmmss')
    $hasHead = Test-NativeSuccess git @('rev-parse', '--verify', '--quiet', 'HEAD')
    $tmpIndex = [IO.Path]::GetTempFileName()
    $oldIndex = $env:GIT_INDEX_FILE
    try {
        # Snapshot HEAD plus all uncommitted and untracked (non-ignored) files into a separate index.
        $env:GIT_INDEX_FILE = $tmpIndex
        Remove-Item $tmpIndex -Force
        if ($hasHead) { Invoke-Native git @('read-tree', 'HEAD') | Out-Null }
        Invoke-Native git @('add', '-A') | Out-Null
        $tree = Invoke-Native git @('write-tree')
    }
    finally {
        $env:GIT_INDEX_FILE = $oldIndex
        if (Test-Path $tmpIndex) { Remove-Item $tmpIndex -Force }
    }
    $msg = "Backup of $DefaultBranch before Cloud Gone Wild demo (including uncommitted changes)"
    $commitArgs = @('commit-tree', $tree, '-m', $msg)
    if ($hasHead) { $commitArgs = @('commit-tree', $tree, '-p', 'HEAD', '-m', $msg) }
    $backupCommit = Invoke-Native git $commitArgs
    Invoke-Native git @('branch', $BackupBranch, $backupCommit) | Out-Null
    Invoke-Native git @('push', 'origin', "refs/heads/${BackupBranch}:refs/heads/$BackupBranch") -FailureMessage "Pushing the backup branch failed. Nothing was replaced." | Out-Null
    Write-Ok "Created and pushed $BackupBranch"
}

# ---------------------------------------------------------------------------
# 7. Bootstrap Terraform
# ---------------------------------------------------------------------------

Write-Step 'Registering Azure resource providers'
foreach ($ns in 'Microsoft.Storage', 'Microsoft.Web', 'Microsoft.OperationalInsights', 'Microsoft.Insights', 'Microsoft.AlertsManagement') {
    Invoke-Native az @('provider', 'register', '--namespace', $ns, '--wait', '--only-show-errors') -FailureMessage "Could not register $ns." | Out-Null
    Write-Ok $ns
}

Write-Step 'Applying infra/bootstrap'

$bootstrapVars = @(
    "-var=subscription_id=$SubscriptionId",
    "-var=location=$Location",
    "-var=prefix=$Prefix",
    "-var=environment=$Environment",
    "-var=github_owner=$($Repository.Split('/')[0])",
    "-var=github_repository=$($Repository.Split('/')[1])",
    "-var=github_branch=$DefaultBranch",
    "-var=state_key=$StateKey"
)
& terraform "-chdir=$BootstrapDir" init -input=false
if ($LASTEXITCODE -ne 0) { Stop-Bootstrap 'terraform init failed in infra/bootstrap.' }
& terraform "-chdir=$BootstrapDir" plan -input=false '-out=bootstrap.tfplan' @bootstrapVars
if ($LASTEXITCODE -ne 0) { Stop-Bootstrap 'terraform plan failed in infra/bootstrap.' }
& terraform "-chdir=$BootstrapDir" apply -input=false bootstrap.tfplan
$applyCode = $LASTEXITCODE
Remove-Item (Join-Path $BootstrapDir 'bootstrap.tfplan') -ErrorAction SilentlyContinue
if ($applyCode -ne 0) { Stop-Bootstrap 'terraform apply failed in infra/bootstrap. Fix the error above and rerun; completed resources are kept in local state.' }

$out = Invoke-Native terraform @("-chdir=$BootstrapDir", 'output', '-json') | ConvertFrom-Json
$bootstrap = @{
    AZURE_CLIENT_ID          = $out.azure_client_id.value
    AZURE_TENANT_ID          = $out.azure_tenant_id.value
    AZURE_SUBSCRIPTION_ID    = $out.azure_subscription_id.value
    TF_STATE_RESOURCE_GROUP  = $out.state_resource_group_name.value
    TF_STATE_STORAGE_ACCOUNT = $out.state_storage_account_name.value
    TF_STATE_CONTAINER       = $out.state_container_name.value
    TF_STATE_KEY             = $out.state_key.value
}
foreach ($k in $bootstrap.Keys) {
    if (-not $bootstrap[$k]) { Stop-Bootstrap "Bootstrap output for $k is empty." }
}
if ($bootstrap.AZURE_SUBSCRIPTION_ID -ne $SubscriptionId -or $bootstrap.AZURE_TENANT_ID -ne $TenantId) {
    Stop-Bootstrap 'Bootstrap outputs do not match the active subscription/tenant. Refusing to configure GitHub.'
}
$expectedSubject = "repo:${Repository}:ref:refs/heads/$DefaultBranch"
if ($out.github_federated_credential_subject.value -ne $expectedSubject) {
    Stop-Bootstrap "Federated credential subject '$($out.github_federated_credential_subject.value)' does not match '$expectedSubject'."
}
Write-Ok "State: $($bootstrap.TF_STATE_RESOURCE_GROUP) / $($bootstrap.TF_STATE_STORAGE_ACCOUNT) / $($bootstrap.TF_STATE_CONTAINER)"
Write-Ok "OIDC subject: $expectedSubject"

# ---------------------------------------------------------------------------
# 8. GitHub Actions configuration
# ---------------------------------------------------------------------------

Write-Step 'Configuring GitHub Actions secrets and variables'

foreach ($name in 'AZURE_CLIENT_ID', 'AZURE_TENANT_ID', 'AZURE_SUBSCRIPTION_ID') {
    # Identifiers, not credentials; stored as secrets so they are masked in public workflow logs.
    Invoke-Native gh @('secret', 'set', $name, '--repo', $Repository, '--app', 'actions', '--body', $bootstrap[$name]) -FailureMessage "Could not set secret $name." | Out-Null
    Write-Ok "secret   $name"
}
foreach ($name in 'TF_STATE_RESOURCE_GROUP', 'TF_STATE_STORAGE_ACCOUNT', 'TF_STATE_CONTAINER', 'TF_STATE_KEY') {
    Invoke-Native gh @('variable', 'set', $name, '--repo', $Repository, '--body', $bootstrap[$name]) -FailureMessage "Could not set variable $name." | Out-Null
    Write-Ok "variable $name = $($bootstrap[$name])"
}

# ---------------------------------------------------------------------------
# 9. Application Terraform against the remote backend
# ---------------------------------------------------------------------------

Write-Step 'Initializing infra/app against the remote backend'

$backendArgs = @(
    "-backend-config=resource_group_name=$($bootstrap.TF_STATE_RESOURCE_GROUP)",
    "-backend-config=storage_account_name=$($bootstrap.TF_STATE_STORAGE_ACCOUNT)",
    "-backend-config=container_name=$($bootstrap.TF_STATE_CONTAINER)",
    "-backend-config=key=$($bootstrap.TF_STATE_KEY)"
)
$initOk = $false
for ($i = 1; $i -le 12; $i++) {
    & terraform "-chdir=$AppDir" init -input=false -reconfigure @backendArgs
    if ($LASTEXITCODE -eq 0) { $initOk = $true; break }
    Write-Info "Backend not reachable yet (role assignments can take a few minutes to propagate). Retry $i/12 in 20 s..."
    Start-Sleep -Seconds 20
}
if (-not $initOk) { Stop-Bootstrap 'terraform init for infra/app failed. Confirm you have Storage Blob Data Contributor on the state container.' }
Invoke-Native terraform @("-chdir=$AppDir", 'validate') -FailureMessage 'terraform validate failed for infra/app.' | Out-Null
Write-Ok 'infra/app validated'

Write-Step 'Locking providers for Linux runners and Windows workstations'
foreach ($dir in $BootstrapDir, $AppDir) {
    Invoke-Native terraform @("-chdir=$dir", 'providers', 'lock', '-platform=linux_amd64', '-platform=windows_amd64', '-platform=darwin_arm64') -FailureMessage "terraform providers lock failed in $dir." | Out-Null
}
Invoke-Native terraform @('fmt', '-check', '-recursive', 'infra') -FailureMessage 'terraform fmt -check failed. Run: terraform fmt -recursive infra' | Out-Null
Write-Ok 'Lock files and formatting verified'

# ---------------------------------------------------------------------------
# 10. Commit and push
# ---------------------------------------------------------------------------

Write-Step "Committing and pushing to $DefaultBranch"

Invoke-Native git @('add', '-A') | Out-Null
$staged = Invoke-Native git @('diff', '--cached', '--name-only')
$forbidden = $staged -split "`n" | Where-Object { $_ -match '(\.tfstate(\.backup)?$|\.tfplan$|(^|/)\.terraform/|\.zip$|(^|/)terraform\.tfvars$)' }
if ($forbidden) {
    Invoke-Native git @('reset', '-q') | Out-Null
    Stop-Bootstrap "Refusing to commit sensitive or generated files: $($forbidden -join ', '). Check .gitignore."
}
if ($staged) {
    Invoke-Native git @('commit', '-m', $CommitMessage) -FailureMessage 'git commit failed. Configure user.name and user.email.' | Out-Null
    Write-Ok 'Committed changes'
}
else {
    Write-Ok 'Nothing new to commit'
}

$headSha = Invoke-Native git @('rev-parse', 'HEAD')
$remoteSha = Invoke-Native git @('ls-remote', 'origin', "refs/heads/$DefaultBranch") -AllowFailure
$remoteSha = if ($remoteSha) { ($remoteSha -split '\s+')[0] } else { '' }
$pushed = $false
if ($remoteSha -ne $headSha) {
    Invoke-Native git @('push', '-u', 'origin', "HEAD:refs/heads/$DefaultBranch") -FailureMessage "git push failed. If the branch diverged, pull and rerun. Force push is intentionally not used." | Out-Null
    $pushed = $true
    Write-Ok "Pushed $($headSha.Substring(0, 7))"
}
else {
    Write-Ok 'Remote already up to date'
}

$repoInfo = Invoke-Native gh @('repo', 'view', $Repository, '--json', 'defaultBranchRef') | ConvertFrom-Json
if (-not $repoInfo.defaultBranchRef -or $repoInfo.defaultBranchRef.name -ne $DefaultBranch) {
    Invoke-Native gh @('repo', 'edit', $Repository, '--default-branch', $DefaultBranch) -FailureMessage "Could not set the GitHub default branch to $DefaultBranch." | Out-Null
    Write-Ok "GitHub default branch set to $DefaultBranch"
}

# ---------------------------------------------------------------------------
# 11. Monitor the deployment workflow
# ---------------------------------------------------------------------------

Write-Step 'Monitoring GitHub Actions deployment'

function Get-DeployRun([string]$Sha) {
    $json = Invoke-Native gh @('run', 'list', '--repo', $Repository, '--workflow', 'deploy.yml', '--branch', $DefaultBranch, '--limit', '20', '--json', 'databaseId,headSha,status,conclusion,createdAt,url') -AllowFailure
    if (-not $json) { return $null }
    return ($json | ConvertFrom-Json) | Where-Object { $_.headSha -eq $Sha } | Sort-Object createdAt -Descending | Select-Object -First 1
}

$run = $null
for ($i = 0; $i -lt 18 -and -not $run; $i++) {
    $run = Get-DeployRun $headSha
    if (-not $run) { Start-Sleep -Seconds 10 }
}
if (-not $run -or (-not $pushed -and $run.conclusion -and $run.conclusion -ne 'success')) {
    Write-Info 'Starting deploy.yml via workflow_dispatch...'
    $startedAfter = (Get-Date).ToUniversalTime()
    Invoke-Native gh @('workflow', 'run', 'deploy.yml', '--repo', $Repository, '--ref', $DefaultBranch) -FailureMessage 'Could not dispatch deploy.yml.' | Out-Null
    $run = $null
    for ($i = 0; $i -lt 18 -and -not $run; $i++) {
        Start-Sleep -Seconds 10
        $candidate = Get-DeployRun $headSha
        if ($candidate -and ([datetime]$candidate.createdAt).ToUniversalTime() -ge $startedAfter.AddSeconds(-5)) { $run = $candidate }
    }
}
if (-not $run) { Stop-Bootstrap "No deploy.yml run found for $headSha. Check https://github.com/$Repository/actions" }

Write-Info "Run: $($run.url)"
& gh run watch $run.databaseId --repo $Repository --exit-status --interval 15
if ($LASTEXITCODE -ne 0) {
    Write-Host ''
    Write-Host 'Failed step log (tail):' -ForegroundColor Yellow
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    & gh run view $run.databaseId --repo $Repository --log-failed 2>$null | Select-Object -Last 60
    $ErrorActionPreference = $prev
    Stop-Bootstrap "Deployment workflow failed: $($run.url)"
}
Write-Ok 'Deployment workflow succeeded'

# ---------------------------------------------------------------------------
# 12. Website address and endpoint test
# ---------------------------------------------------------------------------

Write-Step 'Testing the public website'

$siteUrl = Invoke-Native terraform @("-chdir=$AppDir", 'output', '-raw', 'website_url') -FailureMessage 'Could not read website_url from the remote state.'
& (Join-Path $RepoRoot 'scripts/Test-Deployment.ps1') -Url $siteUrl
$testOk = ($LASTEXITCODE -eq 0)

Write-Host ''
Write-Host '================ Cloud Gone Wild ================' -ForegroundColor Cyan
Write-Host "Subscription : $SubscriptionId"
Write-Host "Tenant       : $TenantId"
Write-Host "Branch       : $DefaultBranch"
Write-Host "State        : $($bootstrap.TF_STATE_RESOURCE_GROUP) / $($bootstrap.TF_STATE_STORAGE_ACCOUNT)"
Write-Host "Workflow run : $($run.url)"
Write-Host "Website      : $siteUrl"
if ($testOk) {
    Write-Host 'Endpoint     : PASSED (HTTP 200)' -ForegroundColor Green
}
else {
    Write-Host 'Endpoint     : FAILED' -ForegroundColor Red
    exit 1
}
