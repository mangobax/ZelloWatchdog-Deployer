#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs the official Win32-OpenSSH server from an MSI and starts it.

.DESCRIPTION
    Windows 10 builds older than 2004 (for example LTSC 1809 and LTSB 2016) ship an
    OpenSSH Server capability whose sshd.exe can fail to load, so this deployer always
    uses the official Win32-OpenSSH MSI (PowerShell/Win32-OpenSSH on GitHub) instead.
    The same MSI works on every supported build and needs no internet access.

    Steps:
      1. Optionally verify the MSI against an expected SHA-256.
      2. Install it silently (skipped if a working sshd.exe is already installed).
      3. Check sshd.exe starts (sshd -t) before configuring anything.
      4. Set the sshd service to Automatic and start it.
      5. Make PowerShell the default SSH shell.
      6. Limit the firewall rule to the requested network profile.

    Authorize keys afterwards with New-SupportAccount.ps1 (needs C:\ProgramData\ssh,
    which sshd creates on first start).

.PARAMETER MsiPath
    Path to OpenSSH-Win64-*.msi or OpenSSH-Win32-*.msi (match the OS architecture).

.PARAMETER ExpectedSha256
    Optional SHA-256 of the MSI. The install is aborted if it does not match.

.PARAMETER FirewallProfile
    Network profile(s) the SSH rule stays enabled on. Default: Private. Use Any only
    when the machine is on a trusted network.
#>
param(
    [Parameter(Mandatory)][string]$MsiPath,
    [string]$ExpectedSha256 = "",
    [ValidateSet('Private', 'Public', 'Domain', 'Any')][string]$FirewallProfile = 'Private'
)

$ErrorActionPreference = 'Stop'
$SshdExe = Join-Path $env:ProgramFiles 'OpenSSH\sshd.exe'

function Test-Sshd {
    if (-not (Test-Path $SshdExe)) { return $false }
    & $SshdExe -t 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

if (Test-Sshd) {
    Write-Host "Win32-OpenSSH already installed and sshd loads - skipping MSI"
} else {
    if (-not (Test-Path $MsiPath)) { throw "MSI not found: $MsiPath" }

    if ($ExpectedSha256) {
        $actual = (Get-FileHash $MsiPath -Algorithm SHA256).Hash
        if ($actual -ne $ExpectedSha256.ToUpper()) { throw "MSI hash mismatch - not installing ($MsiPath)" }
        Write-Host "MSI hash verified"
    }

    Write-Host "Installing $(Split-Path $MsiPath -Leaf)..."
    $proc = Start-Process msiexec.exe -ArgumentList "/i `"$MsiPath`" /qn /norestart" -Wait -PassThru
    if ($proc.ExitCode -notin 0, 3010) { throw "msiexec failed with exit code $($proc.ExitCode)" }

    if (-not (Test-Sshd)) {
        throw "sshd.exe did not pass 'sshd -t' after installation (exit $LASTEXITCODE). Not configuring the service."
    }
    Write-Host "sshd.exe version: $((Get-Item $SshdExe).VersionInfo.FileVersion)"
}

Set-Service -Name sshd -StartupType Automatic
if ((Get-Service sshd).Status -ne 'Running') { Start-Service sshd }
Write-Host "sshd service running (startup: Automatic)"

New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell `
    -Value 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' `
    -PropertyType String -Force | Out-Null
Write-Host "Default SSH shell: powershell.exe"

# The MSI creates its own inbound rule; fall back to a new one if it is missing
$rules = @(Get-NetFirewallRule -Direction Inbound -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -like 'OpenSSH*' -or $_.Name -like 'OpenSSH*' })
if ($rules.Count -eq 0) {
    New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' `
        -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow -Profile $FirewallProfile | Out-Null
    Write-Host "Created firewall rule for TCP 22 (profile: $FirewallProfile)"
} else {
    foreach ($r in $rules) {
        Set-NetFirewallRule -Name $r.Name -Enabled True -Profile $FirewallProfile
    }
    Write-Host "Firewall rule(s) limited to profile: $FirewallProfile"
}

if (-not (Get-NetTCPConnection -LocalPort 22 -State Listen -ErrorAction SilentlyContinue)) {
    Write-Warning "Nothing is listening on TCP 22 yet"
} else {
    Write-Host "sshd is listening on TCP 22"
}
