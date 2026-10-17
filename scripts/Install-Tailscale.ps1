#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs Tailscale silently and joins the tailnet with an auth key.

.DESCRIPTION
    Runs the signed Tailscale installer from the USB, waits for the Tailscale service,
    then runs 'tailscale up --unattended' so the node stays connected without a logged-in
    user. The auth key is never written to the console or to the transcript.

    Without -AuthKey the client is installed only; join the tailnet by hand with
    'tailscale up' afterwards.

.PARAMETER InstallerPath
    tailscale-setup-*.exe (or the MSI).

.PARAMETER AuthKey
    Tailscale auth key (preferably reusable and tagged, created in the admin console).

.PARAMETER Hostname
    Node name in the tailnet. Default: the Windows computer name.
#>
param(
    [Parameter(Mandatory)][string]$InstallerPath,
    [string]$AuthKey = '',
    [string]$Hostname = $env:COMPUTERNAME
)

$ErrorActionPreference = 'Stop'
$TsExe = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'

if (Test-Path $TsExe) {
    Write-Host "Tailscale already installed - skipping installer"
} else {
    if (-not (Test-Path $InstallerPath)) { throw "Tailscale installer not found: $InstallerPath" }
    Write-Host "Installing $(Split-Path $InstallerPath -Leaf)..."
    $isMsi = $InstallerPath -like '*.msi'
    $installArgs = if ($isMsi) { "/i `"$InstallerPath`" /qn /norestart" } else { '/quiet' }
    $exe = if ($isMsi) { 'msiexec.exe' } else { $InstallerPath }
    $p = Start-Process $exe -ArgumentList $installArgs -Wait -PassThru
    if ($p.ExitCode -notin 0, 3010) { throw "Tailscale installer failed with exit code $($p.ExitCode)" }
}

# Wait for the service and the CLI
$deadline = (Get-Date).AddSeconds(90)
while ((Get-Date) -lt $deadline) {
    $svc = Get-Service -Name Tailscale -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running' -and (Test-Path $TsExe)) { break }
    Start-Sleep -Seconds 3
}
if (-not (Test-Path $TsExe)) { throw "tailscale.exe not found after install: $TsExe" }

if (-not $AuthKey) {
    Write-Warning "No auth key supplied - Tailscale installed but not joined. Run: tailscale up"
    return
}

# Pass the key through an environment variable so it never shows in output
$env:TS_AUTHKEY_DEPLOY = $AuthKey
try {
    & $TsExe up "--authkey=$env:TS_AUTHKEY_DEPLOY" "--hostname=$Hostname" --unattended 2>&1 |
        ForEach-Object { $_ -replace [regex]::Escape($AuthKey), '***' } | Write-Host
    if ($LASTEXITCODE -ne 0) { throw "tailscale up failed with exit code $LASTEXITCODE" }
} finally {
    Remove-Item Env:\TS_AUTHKEY_DEPLOY -ErrorAction SilentlyContinue
}

$ip = (& $TsExe ip -4 2>$null | Select-Object -First 1)
Write-Host "Tailscale joined as '$Hostname' (IPv4: $ip)"
