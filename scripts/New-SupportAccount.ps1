#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Creates a local administrator account for remote support and authorizes an SSH key for it.

.DESCRIPTION
    Meant to run from the deployer USB on the target machine, after Install-OpenSsh.ps1.

      1. Reads the account password from a text file on the USB (never hardcoded here).
      2. Creates the local account, or resets its password if it already exists.
      3. Adds it to the local Administrators group (resolved by SID, so it works on any
         Windows language).
      4. Appends the public key to C:\ProgramData\ssh\administrators_authorized_keys and
         locks down its ACL (SYSTEM and Administrators only).
      5. Appends hostname, account and date to a CSV log (no password).

    The password file and the public key are created by prepare-usb.ps1. Treat the USB
    as sensitive while it contains the password file.

.PARAMETER AccountName
    Name of the support account. Default: support

.PARAMETER PasswordFile
    Single-line text file with the account password.

.PARAMETER PublicKeyFile
    SSH public key to authorize. If missing, the key step is skipped with a warning.

.PARAMETER LogFile
    CSV log of runs (no passwords). Default: support-accounts.csv next to the script's parent.
#>
param(
    [string]$AccountName = 'support',
    [string]$PasswordFile = (Join-Path (Split-Path $PSScriptRoot -Parent) 'support\support-password.txt'),
    [string]$PublicKeyFile = (Join-Path (Split-Path $PSScriptRoot -Parent) 'support\support-key.pub'),
    [string]$LogFile = (Join-Path (Split-Path $PSScriptRoot -Parent) 'logs\support-accounts.csv')
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $PasswordFile)) { throw "Password file not found: $PasswordFile" }
$pass = (Get-Content $PasswordFile -Raw).Trim()
if ([string]::IsNullOrEmpty($pass)) { throw "Password file is empty: $PasswordFile" }

# --- Account ---------------------------------------------------------------
$secure = ConvertTo-SecureString $pass -AsPlainText -Force
if (Get-LocalUser -Name $AccountName -ErrorAction SilentlyContinue) {
    Set-LocalUser -Name $AccountName -Password $secure
    Write-Host "Account '$AccountName' existed - password updated"
} else {
    New-LocalUser -Name $AccountName -Password $secure -FullName 'IT Support' `
        -Description 'Remote support account' -PasswordNeverExpires | Out-Null
    Write-Host "Account '$AccountName' created"
}
$pass = $null
$secure = $null

$adminGroup = (Get-LocalGroup | Where-Object { $_.SID.Value -eq 'S-1-5-32-544' }).Name
try {
    Add-LocalGroupMember -Group $adminGroup -Member $AccountName -ErrorAction Stop
    Write-Host "Added to group '$adminGroup'"
} catch {
    if ($_.Exception.Message -match 'already|miembro|member') {
        Write-Host "Already a member of '$adminGroup'"
    } else {
        throw
    }
}

# --- SSH key ---------------------------------------------------------------
$keyInstalled = 'no'
if (Test-Path $PublicKeyFile) {
    $pub = (Get-Content $PublicKeyFile -Raw).Trim()
    $keyFile = 'C:\ProgramData\ssh\administrators_authorized_keys'
    if (-not $pub) {
        Write-Warning "Public key file is empty - skipping key install"
    } elseif (-not (Test-Path (Split-Path $keyFile -Parent))) {
        Write-Warning "C:\ProgramData\ssh not found - run Install-OpenSsh.ps1 first. Skipping key install"
    } else {
        $lines = @(Get-Content $keyFile -ErrorAction SilentlyContinue | Where-Object { $_ })
        if ($lines -contains $pub) {
            Write-Host "Key already present in administrators_authorized_keys"
        } else {
            $lines += $pub
            Set-Content -Path $keyFile -Value $lines -Encoding UTF8
            Write-Host "Key added to administrators_authorized_keys"
        }
        icacls $keyFile /inheritance:r /grant 'SYSTEM:(F)' /grant 'Administrators:(F)' | Out-Null
        $keyInstalled = 'yes'
    }
} else {
    Write-Warning "Public key not found at $PublicKeyFile - skipping key install"
}

# --- Log (no password) -----------------------------------------------------
$logDir = Split-Path $LogFile -Parent
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
if (-not (Test-Path $LogFile)) { Set-Content -Path $LogFile -Encoding UTF8 -Value 'date,hostname,account,ssh_key' }
Add-Content -Path $LogFile -Encoding UTF8 -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm'),$env:COMPUTERNAME,$AccountName,$keyInstalled"
Write-Host "Support account ready: $AccountName@$env:COMPUTERNAME (ssh key: $keyInstalled)"
