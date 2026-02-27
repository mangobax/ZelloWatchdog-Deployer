# ================================
# Portable Provisioning Script
# ================================
# Deploys ZelloWatchdog onto a fresh Windows machine from a USB drive.
# Automatically selects x64/x86 config, installs all prerequisites,
# creates the NSSM service, imports scheduled tasks, and configures
# the system for unattended headless operation.
#
# Usage: Right-click START.ps1 → "Run with PowerShell"
#        (will self-elevate to Administrator if needed)
# ================================

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
Write-Host "Starting provisioning from $Root"

# --- Relaunch as admin if needed (before loading config) ---
if (-not ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {

    Write-Host "Relaunching as Administrator..."
    Start-Process powershell `
      "-ExecutionPolicy Bypass -NoProfile -File `"$PSCommandPath`"" `
      -Verb RunAs
    exit
}

# --- Read Configuration File ---
$Is64Bit = [Environment]::Is64BitOperatingSystem

$ConfigFile = if ($Is64Bit) {
    Write-Host "Detected x64 OS"
    "config_x64.json"
} else {
    Write-Host "Detected x86 OS"
    "config_x86.json"
}

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

$TargetUser    = $Config.user.name
$PlainPassword = $Config.user.password

# ================================
# 1. Set local account password
# ================================
Write-Host "`n--- Step 1: Set local account password ---" -ForegroundColor Yellow

try {
    net user $TargetUser $PlainPassword | Out-Null
    Write-Host "Password set for user '$TargetUser'"
} catch {
    Write-Warning "Failed to set password for '$TargetUser': $_"
}

# ================================
# 2. Enable Remote Desktop + disable NLA
# ================================
Write-Host "`n--- Step 2: Remote Desktop ---" -ForegroundColor Yellow

try {
    if ($Config.remoteDesktop.enable) {
        Set-ItemProperty `
            "HKLM:\System\CurrentControlSet\Control\Terminal Server" `
            -Name "fDenyTSConnections" -Value 0

        # Enable firewall rules for RDP
        Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue
        Write-Host "Remote Desktop enabled"
    }

    if ($Config.remoteDesktop.disableNLA) {
        Set-ItemProperty `
            "HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" `
            -Name "UserAuthentication" -Value 0
        Write-Host "NLA disabled"
    }
} catch {
    Write-Warning "Failed to configure Remote Desktop: $_"
}

# ================================
# 3. Install Zello
# ================================
Write-Host "`n--- Step 3: Install Zello ---" -ForegroundColor Yellow

$ZelloInstaller = Join-Path $Root $Config.applications.zelloInstaller

try {
    if (Test-Path $ZelloInstaller) {
        Write-Host "Running Zello installer (silent)..."
        Start-Process -FilePath $ZelloInstaller `
                      -ArgumentList "/S" `
                      -Wait `
                      -NoNewWindow
        Write-Host "Zello installed"
    } else {
        Write-Warning "Zello installer not found: $ZelloInstaller"
    }
} catch {
    Write-Warning "Zello installation failed: $_"
}

# ================================
# 4. Install Python
# ================================
Write-Host "`n--- Step 4: Install Python ---" -ForegroundColor Yellow

$PythonInstaller = Join-Path $Root $Config.applications.pythonInstaller

try {
    if (Test-Path $PythonInstaller) {
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
        Write-Warning "Python installer not found: $PythonInstaller"
    }
} catch {
    Write-Warning "Python installation failed: $_"
}

# ================================
# 5. Install Notepad++ (optional)
# ================================
Write-Host "`n--- Step 5: Install Notepad++ ---" -ForegroundColor Yellow

if ($Config.applications.PSObject.Properties.Name -contains "notepadPlusPlus") {
    $NppInstaller = Join-Path $Root $Config.applications.notepadPlusPlus

    try {
        if (Test-Path $NppInstaller) {
            Write-Host "Running Notepad++ installer (silent)..."
            Start-Process -FilePath $NppInstaller `
                          -ArgumentList "/S" `
                          -Wait `
                          -NoNewWindow
            Write-Host "Notepad++ installed"
        } else {
            Write-Warning "Notepad++ installer not found: $NppInstaller"
        }
    } catch {
        Write-Warning "Notepad++ installation failed: $_"
    }
} else {
    Write-Host "Notepad++ not configured — skipping"
}

# ================================
# 6. Copy ZelloWatchdog project files
# ================================
Write-Host "`n--- Step 6: Copy ZelloWatchdog project ---" -ForegroundColor Yellow

$SourceProject = Join-Path $Root $Config.paths.documentsSubfolder
$Dest = "C:\Users\$TargetUser\Documents\$($Config.paths.documentsSubfolder)"

try {
    if (-not (Test-Path $SourceProject)) {
        throw "Source project folder not found: $SourceProject"
    }

    if (Test-Path $Dest) {
        Write-Host "Destination exists — merging files (overwrite)..."
    }

    Copy-Item $SourceProject $Dest -Recurse -Force
    Write-Host "Copied ZelloWatchdog project to $Dest"
} catch {
    Write-Warning "Failed to copy ZelloWatchdog project: $_"
}

# ================================
# 7. Install Python dependencies (pip)
# ================================
Write-Host "`n--- Step 7: Install Python dependencies ---" -ForegroundColor Yellow

$RequirementsFile = if ($Is64Bit) { "requirements_x64.txt" } else { "requirements_x86.txt" }
$RequirementsPath = Join-Path $Dest $RequirementsFile

try {
    if (Test-Path $RequirementsPath) {
        Write-Host "Installing pip packages from $RequirementsFile..."
        $pipResult = & python -m pip install -r $RequirementsPath 2>&1
        Write-Host ($pipResult | Out-String)
        Write-Host "Python dependencies installed"
    } else {
        Write-Warning "Requirements file not found: $RequirementsPath"
    }
} catch {
    Write-Warning "Failed to install Python dependencies: $_"
}

# ================================
# 8. Environment variables
# ================================
Write-Host "`n--- Step 8: Environment variables ---" -ForegroundColor Yellow

try {
    foreach ($key in $Config.environmentVariables.PSObject.Properties) {
        [Environment]::SetEnvironmentVariable($key.Name, $key.Value, "Machine")
        Write-Host "  Set $($key.Name)"
    }
    Write-Host "Environment variables configured"
} catch {
    Write-Warning "Failed to set environment variables: $_"
}

# ================================
# 9. Import scheduled tasks
# ================================
Write-Host "`n--- Step 9: Import scheduled tasks ---" -ForegroundColor Yellow

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

Get-ChildItem "$TasksDir\*.xml" | ForEach-Object {

    $TempXml = Join-Path $env:TEMP $_.Name

    try {
        # Read XML content
        $XmlContent = Get-Content $_.FullName -Raw

        # Replace UserId with resolved SID (machine-independent)
        $XmlContent = $XmlContent -replace '<UserId>.*?</UserId>', "<UserId>$Sid</UserId>"

        # For the AutoUpdate task, fix paths to match the actual install location
        if ($_.BaseName -like "*AutoUpdate*") {
            $UpdaterPath = Join-Path $Dest "updater.py"
            $XmlContent = $XmlContent -replace '<Arguments>.*?</Arguments>',
                "<Arguments>`"$UpdaterPath`"</Arguments>"
            $XmlContent = $XmlContent -replace '<WorkingDirectory>.*?</WorkingDirectory>',
                "<WorkingDirectory>$Dest</WorkingDirectory>"
        }

        $XmlContent | Set-Content $TempXml -Encoding UTF8

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
# 10. Install NSSM + create service
# ================================
Write-Host "`n--- Step 10: Install NSSM + create service ---" -ForegroundColor Yellow

$NssmSource = Join-Path $Root $Config.applications.nssm
$NssmTarget = Join-Path $env:WINDIR "System32\nssm.exe"

if (-not (Test-Path $NssmTarget)) {
    if (-not (Test-Path $NssmSource)) {
        throw "NSSM source not found: $NssmSource"
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

# Resolve python.exe — look for the full path via Get-Command
$PythonExe = $Config.service.pythonExe
try {
    $ResolvedPython = (Get-Command $PythonExe -ErrorAction Stop).Source
    $PythonExe = $ResolvedPython
    Write-Host "Resolved Python: $PythonExe"
} catch {
    Write-Warning "Could not resolve '$PythonExe' on PATH — using as-is"
}

if (-not (Test-Path $PythonExe)) {
    Write-Warning "Python executable not found at '$PythonExe' — service may fail to start"
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

    Write-Host "NSSM service '$ServiceName' installed (not started — start after reboot or manually)"
} catch {
    Write-Warning "Failed to configure NSSM service: $_"
}

# ================================
# 11. Power configuration
# ================================
Write-Host "`n--- Step 11: Power configuration ---" -ForegroundColor Yellow

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
# 12. Enable auto-login (netplwiz equivalent)
# ================================
Write-Host "`n--- Step 12: Auto-login ---" -ForegroundColor Yellow

try {
    if ($Config.user.autoLogin) {
        $RegPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
        Set-ItemProperty $RegPath "AutoAdminLogon"  "1"
        Set-ItemProperty $RegPath "DefaultUserName" $TargetUser
        Set-ItemProperty $RegPath "DefaultPassword" $PlainPassword
        Write-Host "Auto-login configured for '$TargetUser'"
    } else {
        Write-Host "Auto-login disabled in config — skipping"
    }
} catch {
    Write-Warning "Failed to configure auto-login: $_"
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
