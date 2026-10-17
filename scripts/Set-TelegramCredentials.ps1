#Requires -Version 5.1
<#
.SYNOPSIS
    Sets the Telegram bot token and chat id for ZelloWatchdog as machine environment variables.

.DESCRIPTION
    Values come from, in order: -Token/-ChatId, the deployer config file
    (environmentVariables.TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID), or a prompt.
    They are stored as machine environment variables because the updater replaces
    config.ini on every release, so secrets must not live there.
    Sends a test message, then restarts the service so it picks the values up.
    Run from an elevated PowerShell. Safe to run again.

.PARAMETER ConfigPath
    Deployer config json. Default: config_x64.json / config_x86.json in the folder above this script.

.PARAMETER Interactive
    Prompt for any value that is missing or still a placeholder. An empty answer skips it.

.EXAMPLE
    .\Set-TelegramCredentials.ps1
    .\Set-TelegramCredentials.ps1 -Token 123:ABC -ChatId -100123456
#>
param(
    [string]$ConfigPath = '',
    [string]$Token = '',
    [string]$ChatId = '',
    [string]$ServiceName = 'ZelloWatchdog',
    [switch]$Interactive,
    [switch]$NoTest
)

$ErrorActionPreference = 'Stop'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw 'Run this script from an elevated PowerShell (Run as administrator).' }

function Test-Placeholder([string]$v) { [string]::IsNullOrWhiteSpace($v) -or $v -like 'YOUR_*' -or $v -like 'CHANGE_ME*' }

# 1. Config file
if (-not $ConfigPath) {
    $arch = if ([Environment]::Is64BitOperatingSystem) { 'x64' } else { 'x86' }
    $ConfigPath = Join-Path (Split-Path -Parent $PSScriptRoot) "config_$arch.json"
}
if ((Test-Placeholder $Token) -or (Test-Placeholder $ChatId)) {
    if (Test-Path -LiteralPath $ConfigPath) {
        $vars = (Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json).environmentVariables
        if (Test-Placeholder $Token)  { $Token  = [string]$vars.TELEGRAM_BOT_TOKEN }
        if (Test-Placeholder $ChatId) { $ChatId = [string]$vars.TELEGRAM_CHAT_ID }
        Write-Host "Read config: $ConfigPath"
    } else {
        Write-Host "Config not found ($ConfigPath)"
    }
}

# 2. Prompt for what is still missing
if (Test-Placeholder $Token) {
    $s = Read-Host 'Telegram bot token (hidden, Enter to skip)' -AsSecureString
    $Token = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))
}
if (Test-Placeholder $ChatId) { $ChatId = Read-Host 'Telegram chat id (Enter to skip)' }

if ((Test-Placeholder $Token) -or (Test-Placeholder $ChatId)) {
    Write-Warning 'Token or chat id missing: Telegram alerts stay off. Run this script again when you have them.'
    exit 0
}

# 3. Store as machine environment variables
[Environment]::SetEnvironmentVariable('TELEGRAM_BOT_TOKEN', $Token.Trim(), 'Machine')
[Environment]::SetEnvironmentVariable('TELEGRAM_CHAT_ID', $ChatId.Trim(), 'Machine')
Write-Host 'Machine environment variables TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID set.' -ForegroundColor Green

# 4. Test message
if (-not $NoTest) {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $body = @{ chat_id = $ChatId.Trim(); text = "ZelloWatchdog: Telegram configured on $env:COMPUTERNAME" }
        $null = Invoke-RestMethod -Uri "https://api.telegram.org/bot$($Token.Trim())/sendMessage" -Method Post -Body $body -TimeoutSec 20
        Write-Host 'Test message sent. Check the Telegram chat.' -ForegroundColor Green
    } catch {
        # The exception text can contain the URL (with the token): print only the HTTP status
        $code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 'no response' }
        Write-Warning "Test message failed ($code). Check the token, the chat id, and that the bot was added to the chat."
    }
}

# 5. Restart the service so it reads the new environment
$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -eq 'Running') {
    Restart-Service -Name $ServiceName -Force
    Write-Host "Service '$ServiceName' restarted."
} elseif ($svc) {
    Write-Host "Service '$ServiceName' is not running; it will read the values when it starts."
} else {
    Write-Host "Service '$ServiceName' is not installed yet."
}
