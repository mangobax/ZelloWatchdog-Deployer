# ================================
# Portable Provisioning Script
# ================================
# Deploys ZelloWatchdog onto a fresh Windows machine from a USB drive.
# Automatically selects x64/x86 config, installs all prerequisites,
# creates the NSSM service, imports scheduled tasks, and configures
# the system for unattended headless operation.
#
# Usage: Right-click START.ps1 -> "Run with PowerShell"
#        (will self-elevate to Administrator if needed)
#        Optional: START.ps1 -UserName radio   (skips the username prompt)
# ================================

param(
    [string]$UserName = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# --- Resolve script root (works from USB, UNC, or local path) ---
$Root = if ($PSScriptRoot) {
    $PSScriptRoot
} elseif ($PSCommandPath) {
    Split-Path -Parent $PSCommandPath
} else {
    (Get-Location).Path
}

# --- Ensure logs directory exists ---
$LogDir = Join-Path $Root "logs"
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force | Out-Null }

$Log = Join-Path $LogDir "provision-$(Get-Date -f yyyyMMdd-HHmmss).log"
Start-Transcript -Path $Log

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  ZelloWatchdog Deployer" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan
Write-Host "Starting provisioning from $Root on $env:COMPUTERNAME"

# --- Relaunch as admin if needed (before loading config) ---
if (-not ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {

    Write-Host "Relaunching as Administrator..."
    $relaunchArgs = "-ExecutionPolicy Bypass -NoProfile -File `"$PSCommandPath`""
    if ($UserName) { $relaunchArgs += " -UserName `"$UserName`"" }
    Start-Process powershell $relaunchArgs -Verb RunAs
    exit
}

# --- Helpers ---------------------------------------------------------------

function Get-Cfg {
    # Safe property read under StrictMode: returns $Default when the key is missing
    param($Object, [string]$Name, $Default = $null)
    if ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name) {
        return $Object.$Name
    }
    return $Default
}

function Resolve-Python {
    # Prefer the real interpreter over the Microsoft Store alias in WindowsApps
    $cmd = Get-Command python.exe -ErrorAction SilentlyContinue |
        Where-Object { $_.Source -notlike '*\WindowsApps\*' } | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    foreach ($dir in @("$env:ProgramFiles\Python3*", "${env:ProgramFiles(x86)}\Python3*")) {
        $found = Get-ChildItem $dir -Filter python.exe -Recurse -Depth 1 -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    return $null
}

function Find-ZelloExe {
    foreach ($p in @("${env:ProgramFiles(x86)}\Zello\Zello.exe", "$env:ProgramFiles\Zello\Zello.exe")) {
        if ($p -and (Test-Path $p)) { return $p }
    }
    return $null
}

# Optional integrity manifest written by prepare-usb.ps1 (relative path -> SHA-256)
$Manifest = $null
$ManifestPath = Join-Path $Root "manifest.sha256.json"
if (Test-Path $ManifestPath) { $Manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json }

function Test-InstallerHash {
    param([string]$Path)
    if (-not $Manifest) { return $true }
    $rel = $Path.Substring($Root.Length).TrimStart('\')
    $entry = $Manifest.PSObject.Properties[$rel]
    if (-not $entry) {
        Write-Warning "No manifest entry for $rel - installing without hash check"
        return $true
    }
    $actual = (Get-FileHash $Path -Algorithm SHA256).Hash
    if ($actual -ne $entry.Value.ToUpper()) {
        Write-Warning "HASH MISMATCH for $rel - the file changed since the USB was prepared. Skipping it."
        return $false
    }
    return $true
}

# --- Read Configuration File ---
$Is64Bit = [Environment]::Is64BitOperatingSystem
$Arch    = if ($Is64Bit) { "x64" } else { "x86" }

$ConfigFile = "config_$Arch.json"
Write-Host "Detected $Arch OS"

$ConfigPath = Join-Path $Root $ConfigFile

if (-not (Test-Path $ConfigPath)) {
    throw "Config file not found: $ConfigPath"
}

try {
    $Config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    Write-Host "Configuration loaded from $ConfigFile"
} catch {
    throw "Invalid JSON in $ConfigFile : $_"
}

# ================================
# 1. Local account (ask for username, create if missing, set password)
# ================================
Write-Host "`n--- Step 1: Local account ---" -ForegroundColor Yellow

$DefaultUser = Get-Cfg $Config.user "name" "radio"
if (-not $UserName) {
    $answer = Read-Host "Windows username for this radio station [$DefaultUser]"
    $UserName = if ($answer) { $answer.Trim() } else { $DefaultUser }
}
$TargetUser = $UserName

$PlainPassword = Get-Cfg $Config.user "password" ""
if ([string]::IsNullOrEmpty($PlainPassword) -or $PlainPassword -like "CHANGE_ME*") {
    $secure = Read-Host "Password for '$TargetUser' (hidden)" -AsSecureString
    $PlainPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
}
if ([string]::IsNullOrEmpty($PlainPassword)) { throw "A password is required for '$TargetUser'" }

try {
    $adminGroup = (Get-LocalGroup | Where-Object { $_.SID.Value -eq 'S-1-5-32-544' }).Name
    if (Get-LocalUser -Name $TargetUser -ErrorAction SilentlyContinue) {
        Set-LocalUser -Name $TargetUser -Password (ConvertTo-SecureString $PlainPassword -AsPlainText -Force)
        Write-Host "Password updated for existing user '$TargetUser'"
    } else {
        New-LocalUser -Name $TargetUser -Password (ConvertTo-SecureString $PlainPassword -AsPlainText -Force) `
            -PasswordNeverExpires -Description "ZelloWatchdog radio station account" | Out-Null
        Write-Host "User '$TargetUser' created"
    }
    # The updater task needs elevation (stops/starts the service), so the account must be an administrator
    try { Add-LocalGroupMember -Group $adminGroup -Member $TargetUser -ErrorAction Stop } catch {
        if ($_.Exception.Message -notmatch 'already|miembro|member') { throw }
    }
    Write-Host "'$TargetUser' is a member of '$adminGroup'"
} catch {
    Write-Warning "Failed to configure local account '$TargetUser': $_"
}

# ================================
# 2. Enable Remote Desktop + disable NLA
# ================================
Write-Host "`n--- Step 2: Remote Desktop ---" -ForegroundColor Yellow

try {
    $rdp = Get-Cfg $Config "remoteDesktop"
    if (Get-Cfg $rdp "enable" $false) {
        Set-ItemProperty `
            "HKLM:\System\CurrentControlSet\Control\Terminal Server" `
            -Name "fDenyTSConnections" -Value 0

        # Enable firewall rules for RDP
        Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue
        Write-Host "Remote Desktop enabled"
    }

    if (Get-Cfg $rdp "disableNLA" $false) {
        Set-ItemProperty `
            "HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" `
            -Name "UserAuthentication" -Value 0
        Write-Host "NLA disabled"
    }
} catch {
    Write-Warning "Failed to configure Remote Desktop: $_"
}

# ================================
# 3. OpenSSH server + support account
# ================================
Write-Host "`n--- Step 3: OpenSSH server + support account ---" -ForegroundColor Yellow

$Ssh = Get-Cfg $Config "openssh"
if ($Ssh -and (Get-Cfg $Ssh "enable" $false)) {
    try {
        $msi = Join-Path $Root (Get-Cfg $Ssh "msi" "")
        if (-not (Test-Path $msi)) { throw "OpenSSH MSI not found: $msi" }
        if (-not (Test-InstallerHash $msi)) { throw "OpenSSH MSI failed the hash check" }

        & (Join-Path $Root "scripts\Install-OpenSsh.ps1") `
            -MsiPath $msi -FirewallProfile (Get-Cfg $Ssh "firewallProfile" "Private")

        $Support = Get-Cfg $Config "support"
        if ($Support -and (Get-Cfg $Support "enable" $false)) {
            & (Join-Path $Root "scripts\New-SupportAccount.ps1") `
                -AccountName (Get-Cfg $Support "accountName" "support") `
                -PasswordFile (Join-Path $Root (Get-Cfg $Support "passwordFile" "support\support-password.txt")) `
                -PublicKeyFile (Join-Path $Root (Get-Cfg $Support "publicKeyFile" "support\support-key.pub")) `
                -LogFile (Join-Path $LogDir "support-accounts.csv")
        } else {
            Write-Host "Support account disabled in config - skipping"
        }
    } catch {
        Write-Warning "OpenSSH / support account setup failed: $_"
    }
} else {
    Write-Host "OpenSSH disabled in config - skipping"
}

# ================================
# 4. Tailscale
# ================================
Write-Host "`n--- Step 4: Tailscale ---" -ForegroundColor Yellow

$Ts = Get-Cfg $Config "tailscale"
if ($Ts -and (Get-Cfg $Ts "enable" $false)) {
    try {
        $tsInstaller = Join-Path $Root (Get-Cfg $Ts "installer" "")
        if (-not (Test-Path $tsInstaller)) { throw "Tailscale installer not found: $tsInstaller" }
        if (-not (Test-InstallerHash $tsInstaller)) { throw "Tailscale installer failed the hash check" }

        $tsHost = Get-Cfg $Ts "hostname" ""
        if (-not $tsHost) { $tsHost = $env:COMPUTERNAME }
        $tsKey = Get-Cfg $Ts "authKey" ""
        if ($tsKey -like "YOUR_*") { $tsKey = "" }

        & (Join-Path $Root "scripts\Install-Tailscale.ps1") `
            -InstallerPath $tsInstaller -AuthKey $tsKey -Hostname $tsHost
    } catch {
        Write-Warning "Tailscale setup failed: $_"
    }
} else {
    Write-Host "Tailscale disabled in config - skipping"
}

# ================================
# 5. Install Zello
# ================================
Write-Host "`n--- Step 5: Install Zello ---" -ForegroundColor Yellow

$ZelloInstaller = Join-Path $Root $Config.applications.zelloInstaller

try {
    if ((Test-Path $ZelloInstaller) -and (Test-InstallerHash $ZelloInstaller)) {
        Write-Host "Running Zello installer (silent)..."
        Start-Process -FilePath $ZelloInstaller `
                      -ArgumentList "/S" `
                      -Wait `
                      -NoNewWindow
        Write-Host "Zello installed"
    } else {
        Write-Warning "Zello installer missing or failed the hash check: $ZelloInstaller"
    }
} catch {
    Write-Warning "Zello installation failed: $_"
}

# ================================
# 6. Install Python
# ================================
Write-Host "`n--- Step 6: Install Python ---" -ForegroundColor Yellow

$PythonInstaller = Join-Path $Root $Config.applications.pythonInstaller

try {
    if ((Test-Path $PythonInstaller) -and (Test-InstallerHash $PythonInstaller)) {
        Write-Host "Running Python installer (silent, all users, prepend PATH)..."
        Start-Process -FilePath $PythonInstaller `
                      -ArgumentList "/quiet InstallAllUsers=1 PrependPath=1" `
                      -Wait `
                      -NoNewWindow
        Write-Host "Python installed"

        # Refresh PATH so pip is available in this session
        $MachinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
        $UserPath    = [Environment]::GetEnvironmentVariable("Path", "User")
        $env:Path    = "$MachinePath;$UserPath"
    } else {
        Write-Warning "Python installer missing or failed the hash check: $PythonInstaller"
    }
} catch {
    Write-Warning "Python installation failed: $_"
}

# ================================
# 7. Install Notepad++ (optional)
# ================================
Write-Host "`n--- Step 7: Install Notepad++ ---" -ForegroundColor Yellow

if ($Config.applications.PSObject.Properties.Name -contains "notepadPlusPlus") {
    $NppInstaller = Join-Path $Root $Config.applications.notepadPlusPlus

    try {
        if ((Test-Path $NppInstaller) -and (Test-InstallerHash $NppInstaller)) {
            Write-Host "Running Notepad++ installer (silent)..."
            Start-Process -FilePath $NppInstaller `
                          -ArgumentList "/S" `
                          -Wait `
                          -NoNewWindow
            Write-Host "Notepad++ installed"
        } else {
            Write-Warning "Notepad++ installer missing or failed the hash check: $NppInstaller"
        }
    } catch {
        Write-Warning "Notepad++ installation failed: $_"
    }
} else {
    Write-Host "Notepad++ not configured - skipping"
}

# ================================
# 8. Copy ZelloWatchdog project files
# ================================
Write-Host "`n--- Step 8: Copy ZelloWatchdog project ---" -ForegroundColor Yellow

$SourceFolder  = Get-Cfg $Config.paths "documentsSubfolder" "ZelloWatchdog"
$InstallFolder = Get-Cfg $Config.paths "installFolder" $SourceFolder
$SourceProject = Join-Path $Root $SourceFolder
$Dest = "C:\Users\$TargetUser\Documents\$InstallFolder"

try {
    if (-not (Test-Path $SourceProject)) {
        throw "Source project folder not found: $SourceProject"
    }

    if (Test-Path $Dest) {
        Write-Host "Destination exists - merging files (overwrite)..."
    } else {
        New-Item -ItemType Directory -Path $Dest -Force | Out-Null
    }

    # Copy the CONTENTS, so an existing destination is merged instead of nested one level deeper
    Copy-Item (Join-Path $SourceProject "*") $Dest -Recurse -Force
    Write-Host "Copied ZelloWatchdog project to $Dest"
} catch {
    Write-Warning "Failed to copy ZelloWatchdog project: $_"
}

# ================================
# 9. Install Python dependencies (pip)
# ================================
Write-Host "`n--- Step 9: Install Python dependencies ---" -ForegroundColor Yellow

$RequirementsFile = "requirements_$Arch.txt"
$RequirementsPath = Join-Path $Dest $RequirementsFile
$WheelsDir        = Join-Path $Root "wheels\$Arch"

try {
    $PythonForPip = Resolve-Python
    if (-not $PythonForPip) { throw "python.exe not found after installation" }

    if (Test-Path $RequirementsPath) {
        # pip writes notices to stderr; under 'Stop' Windows PowerShell 5.1 would turn them into errors
        $ErrorActionPreference = "Continue"
        if (Test-Path $WheelsDir) {
            Write-Host "Installing pip packages offline from $WheelsDir..."
            $pipResult = & $PythonForPip -m pip install --no-index --find-links $WheelsDir -r $RequirementsPath 2>&1
        } else {
            Write-Host "No local wheels - installing from the internet..."
            $pipResult = & $PythonForPip -m pip install -r $RequirementsPath 2>&1
        }
        $pipExit = $LASTEXITCODE
        $ErrorActionPreference = "Stop"
        Write-Host ($pipResult | Out-String)
        if ($pipExit -ne 0) { throw "pip exited with code $pipExit" }
        Write-Host "Python dependencies installed"
    } else {
        Write-Warning "Requirements file not found: $RequirementsPath"
    }
} catch {
    Write-Warning "Failed to install Python dependencies: $_"
}

# ================================
# 10. Environment variables
# ================================
Write-Host "`n--- Step 10: Environment variables ---" -ForegroundColor Yellow

try {
    foreach ($key in $Config.environmentVariables.PSObject.Properties) {
        if ($key.Value -like "YOUR_*") {
            Write-Warning "  $($key.Name) is still a placeholder - Telegram alerts will not work until it is set"
            continue
        }
        [Environment]::SetEnvironmentVariable($key.Name, $key.Value, "Machine")
        Write-Host "  Set $($key.Name)"
    }
    Write-Host "Environment variables configured"
} catch {
    Write-Warning "Failed to set environment variables: $_"
}

# Telegram values still missing (placeholders in the config): ask for them now.
# The script reads the same config file, stores machine env vars, and sends a test message.
if (-not [Environment]::GetEnvironmentVariable("TELEGRAM_BOT_TOKEN", "Machine") -or
    -not [Environment]::GetEnvironmentVariable("TELEGRAM_CHAT_ID", "Machine")) {
    try {
        & (Join-Path $Root "scripts\Set-TelegramCredentials.ps1") -ConfigPath $ConfigPath -ServiceName $Config.service.name -Interactive
    } catch {
        Write-Warning "Telegram setup failed: $_"
    }
}

# ================================
# 11. Import scheduled tasks
# ================================
Write-Host "`n--- Step 11: Import scheduled tasks ---" -ForegroundColor Yellow

try {
    $Account = New-Object System.Security.Principal.NTAccount(
        $env:COMPUTERNAME,
        $TargetUser
    )

    $Sid = $Account.Translate(
        [System.Security.Principal.SecurityIdentifier]
    ).Value

    if (-not $Sid -or $Sid.Length -lt 10) {
        throw "Empty or invalid SID"
    }

    Write-Host "Resolved SID for '$TargetUser': $Sid"
} catch {
    throw "Failed to resolve SID for local user '$TargetUser': $_"
}

if (-not (Get-Service Schedule -ErrorAction SilentlyContinue)) {
    throw "Task Scheduler service not available"
}

$TasksDir = Join-Path $Root "tasks"
$ZelloExe = Find-ZelloExe
$XmlEncoding = New-Object System.Text.UnicodeEncoding($false, $true)   # UTF-16 LE + BOM, as the XML declares

Get-ChildItem "$TasksDir\*.xml" | ForEach-Object {

    $TempXml = Join-Path $env:TEMP $_.Name

    try {
        # Read XML content (encoding is detected from the BOM)
        $XmlContent = [IO.File]::ReadAllText($_.FullName)

        # Replace UserId with the resolved SID (machine-independent). Tasks use
        # InteractiveToken, so no password is stored; they run while the user is logged on.
        $XmlContent = $XmlContent -replace '<UserId>.*?</UserId>', "<UserId>$Sid</UserId>"

        # AutoUpdate: point to the real install location
        if ($_.BaseName -like "*AutoUpdate*") {
            $UpdaterPath = Join-Path $Dest "updater.py"
            $XmlContent = $XmlContent -replace '<Arguments>.*?</Arguments>',
                "<Arguments>`"$UpdaterPath`"</Arguments>"
            $XmlContent = $XmlContent -replace '<WorkingDirectory>.*?</WorkingDirectory>',
                "<WorkingDirectory>$Dest</WorkingDirectory>"
        }

        # LaunchZelloGUI: Zello installs under Program Files (x86) only on 64-bit Windows
        if ($_.BaseName -like "*LaunchZelloGUI*" -and $ZelloExe) {
            $XmlContent = $XmlContent -replace '<Command>.*?</Command>', "<Command>`"$ZelloExe`"</Command>"
        }

        [IO.File]::WriteAllText($TempXml, $XmlContent, $XmlEncoding)

        $result = schtasks /create /tn $_.BaseName /xml $TempXml /f 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "schtasks failed for $($_.BaseName): $result"
        } else {
            Write-Host "  Imported task: $($_.BaseName)"
        }
    } catch {
        Write-Warning "Failed to import task $($_.BaseName): $_"
    } finally {
        Remove-Item $TempXml -ErrorAction SilentlyContinue
    }
}

# ================================
# 12. Install NSSM + create service
# ================================
Write-Host "`n--- Step 12: Install NSSM + create service ---" -ForegroundColor Yellow

$NssmSource = Join-Path $Root $Config.applications.nssm
$NssmTarget = Join-Path $env:WINDIR "System32\nssm.exe"

if (-not (Test-Path $NssmTarget)) {
    if (-not (Test-Path $NssmSource)) {
        throw "NSSM source not found: $NssmSource"
    }
    if (-not (Test-InstallerHash $NssmSource)) {
        throw "NSSM failed the hash check: $NssmSource"
    }

    Copy-Item $NssmSource $NssmTarget -Force
    Write-Host "NSSM installed to System32"
} else {
    Write-Host "NSSM already present in System32"
}

$ServiceName = $Config.service.name
$ScriptPath  = Join-Path $Dest $Config.service.script
$AppDir      = Split-Path $ScriptPath -Parent
$StdoutLog   = Join-Path $Dest "$ServiceName.out.log"
$StderrLog   = Join-Path $Dest "$ServiceName.err.log"

# Resolve python.exe to a full path
$PythonExe = Resolve-Python
if (-not $PythonExe) {
    $PythonExe = $Config.service.pythonExe
    Write-Warning "Could not resolve Python - using '$PythonExe' as-is"
} else {
    Write-Host "Resolved Python: $PythonExe"
}

if (-not (Test-Path $PythonExe)) {
    Write-Warning "Python executable not found at '$PythonExe' - service may fail to start"
}

if (-not (Test-Path $ScriptPath)) {
    throw "Service script not found: $ScriptPath"
}

try {
    # Remove existing service if present (clean reinstall)
    $existingService = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($existingService) {
        Write-Host "Removing existing '$ServiceName' service..."
        nssm stop $ServiceName 2>&1 | Out-Null
        nssm remove $ServiceName confirm 2>&1 | Out-Null
        Start-Sleep -Seconds 2
    }

    nssm install $ServiceName "`"$PythonExe`"" "`"$ScriptPath`""
    nssm set $ServiceName AppDirectory $AppDir
    nssm set $ServiceName Start SERVICE_AUTO_START
    nssm set $ServiceName AppRestartDelay 5000
    nssm set $ServiceName AppStopMethodSkip 6
    nssm set $ServiceName AppExit Default Restart
    nssm set $ServiceName DisplayName "Zello Watchdog Service"
    nssm set $ServiceName Description "Monitors Zello and restarts it if unhealthy"
    nssm set $ServiceName AppStdout $StdoutLog
    nssm set $ServiceName AppStderr $StderrLog

    Write-Host "NSSM service '$ServiceName' installed (not started - start after Zello's first-run setup)"
} catch {
    Write-Warning "Failed to configure NSSM service: $_"
}

# ================================
# 13. Power configuration
# ================================
Write-Host "`n--- Step 13: Power configuration ---" -ForegroundColor Yellow

try {
    powercfg /change standby-timeout-ac $Config.power.sleep
    powercfg /change hibernate-timeout-ac $Config.power.hibernate
    powercfg /change monitor-timeout-ac $Config.power.displayOffMinutes
    powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 0
    powercfg /setactive SCHEME_CURRENT

    Write-Host "Power settings configured (sleep=$($Config.power.sleep), hibernate=$($Config.power.hibernate), display=$($Config.power.displayOffMinutes)min)"
} catch {
    Write-Warning "Failed to configure power settings: $_"
}

# ================================
# 14. Enable auto-login (netplwiz equivalent)
# ================================
Write-Host "`n--- Step 14: Auto-login ---" -ForegroundColor Yellow

try {
    if (Get-Cfg $Config.user "autoLogin" $false) {
        $RegPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
        Set-ItemProperty $RegPath "AutoAdminLogon"    "1"
        Set-ItemProperty $RegPath "DefaultUserName"   $TargetUser
        # "." = this computer. Avoids a stale domain name if the machine is renamed later.
        Set-ItemProperty $RegPath "DefaultDomainName" "."
        Set-ItemProperty $RegPath "DefaultPassword"   $PlainPassword
        Write-Host "Auto-login configured for '$TargetUser'"
    } else {
        Write-Host "Auto-login disabled in config - skipping"
    }
} catch {
    Write-Warning "Failed to configure auto-login: $_"
}

$PlainPassword = $null

# ================================
# 15. Desktop shortcuts
# ================================
Write-Host "`n--- Step 15: Desktop shortcuts ---" -ForegroundColor Yellow

try {
    & (Join-Path $Root "scripts\New-Shortcuts.ps1") -User $TargetUser -InstallDir $Dest -ServiceName $ServiceName
} catch {
    Write-Warning "Failed to create desktop shortcuts: $_"
}

# ================================
# Done
# ================================
Write-Host "`n========================================" -ForegroundColor Green
Write-Host "  Provisioning complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host "`nNext steps:"
Write-Host "  1. Open Zello, log in, and close it (creates the WAL database file)"
Write-Host "  2. Start the service:  nssm start $ServiceName"
Write-Host "  3. Reboot to verify auto-login and service auto-start"
Write-Host ""

Stop-Transcript
