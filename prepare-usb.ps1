#Requires -Version 5.1
<#
.SYNOPSIS
    Prepares a deployer USB: installers, project files, offline pip wheels, support
    account files, per-architecture configs and an integrity manifest.

.DESCRIPTION
    Run on the administrator's PC (internet needed for the project zip and the wheels).
    The target is a folder or the root of a USB drive; START.ps1 is then run from there on
    each radio station.

      1. Validates the target and free space.
      2. Finds the installers you downloaded in -InstallersDir, checks their Authenticode
         signatures and copies them into the layout START.ps1 expects.
      3. Downloads the ZelloWatchdog project (main branch by default) and copies the
         files and scheduled-task XMLs the stations need.
      4. Downloads pip wheels (requests, psutil) for x64 and x86 so stations can install
         them without internet.
      5. Creates support\ with the support account password (generated, or reused from
         -SupportPasswordFile) and your SSH public key.
      6. Writes config_x64.json / config_x86.json from the repo templates, filling in the
         real installer names and the secrets you type (Telegram, Tailscale, passwords).
      7. Writes manifest.sha256.json so START.ps1 can detect a corrupted or altered file.

    Secrets are typed at hidden prompts and written ONLY to the USB, never to this repo.
    Treat the USB as sensitive.

.PARAMETER UsbPath
    Target root. Default: D:\

.PARAMETER InstallersDir
    Folder holding the installers you downloaded (searched recursively).

.PARAMETER PythonSeries
    Python series to deploy. Default: 3.12

.PARAMETER SupportAccount
    Name of the support account created on the stations. Default: support

.PARAMETER SupportPasswordFile
    Existing single-line password file to reuse for the support account. If omitted, an
    existing support\support-password.txt on the USB is kept, else a new one is generated.

.PARAMETER RotateSupportPassword
    Generate a new support password even if one already exists on the USB.

.PARAMETER PublicKeyPath
    SSH public key to authorize for the support account.

.PARAMETER RadioUserName
    Default Windows username offered by START.ps1 on the stations. Default: radio

.PARAMETER ProjectZipUrl
    Zip of the ZelloWatchdog project. Default: main branch on GitHub.

.PARAMETER SkipWheels
    Do not download pip wheels (stations will need internet for pip).

.PARAMETER SkipProjectDownload
    Reuse the ZelloWatchdog\ and tasks\ folders already on the target.

.PARAMETER NoPrompt
    Do not ask for secrets; leave placeholders in the configs (START.ps1 still asks for the
    account password on the station). Useful for tests.

.PARAMETER Force
    Continue when the target is not a removable drive or a signature is not valid.
#>
param(
    [string]$UsbPath = 'D:\',
    [string]$InstallersDir = (Join-Path $env:USERPROFILE 'Downloads\Zello installers'),
    [string]$PythonSeries = '3.12',
    [string]$SupportAccount = 'support',
    [string]$SupportPasswordFile = '',
    [switch]$RotateSupportPassword,
    [string]$PublicKeyPath = (Join-Path $env:USERPROFILE '.ssh\id_ed25519.pub'),
    [string]$RadioUserName = 'radio',
    [string]$ProjectZipUrl = 'https://github.com/mangobax/ZelloWatchdog/archive/refs/heads/main.zip',
    [switch]$SkipWheels,
    [switch]$SkipProjectDownload,
    [switch]$NoPrompt,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$RepoRoot = $PSScriptRoot
$Usb = (Resolve-Path -LiteralPath $UsbPath).Path.TrimEnd('\')
$Problems = New-Object System.Collections.Generic.List[string]

function Write-Step { param([string]$m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-OK   { param([string]$m) Write-Host "    OK: $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "    WARN: $m" -ForegroundColor Yellow }

function Read-Secret {
    param([string]$Prompt)
    $s = Read-Host $Prompt -AsSecureString
    [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))
}

function New-RandomPassword {
    # 24 characters from a crypto RNG; no ambiguous characters (0/O, 1/l/I)
    $chars = 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789!@#%^*'
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    $buf = New-Object byte[] 24
    $rng.GetBytes($buf)
    -join ($buf | ForEach-Object { $chars[$_ % $chars.Length] })
}

# --- 1. Target ---------------------------------------------------------------
Write-Step "Checking target $Usb"

if ($Usb -eq $RepoRoot.TrimEnd('\')) { throw "The target cannot be the repository folder itself." }
if (-not (Test-Path -LiteralPath $InstallersDir)) { throw "Installers folder not found: $InstallersDir" }

$driveLetter = $Usb.Substring(0, 1)
$vol = Get-Volume -DriveLetter $driveLetter -ErrorAction SilentlyContinue
if ($vol) {
    if ($vol.DriveType -ne 'Removable' -and -not $Force) {
        throw "$($Usb.Substring(0,2)) is not a removable drive ($($vol.DriveType)). Use -Force to continue anyway."
    }
    Write-OK ("{0} {1}, {2:N1} GB free" -f $Usb.Substring(0, 2), $vol.FileSystem, ($vol.SizeRemaining / 1GB))
}

# --- 2. Installers -----------------------------------------------------------
Write-Step "Looking for installers in $InstallersDir"

function Find-Installer {
    param([string]$Pattern, [string]$Exclude = '')
    Get-ChildItem -LiteralPath $InstallersDir -Recurse -File -Filter $Pattern -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\src\\' -and (-not $Exclude -or $_.Name -notmatch $Exclude) } |
        Sort-Object Name -Descending | Select-Object -First 1
}

$catalog = [ordered]@{
    zello   = @{ File = (Find-Installer 'ZelloSetup_*.exe');                         Dest = 'installers';                  Required = $true }
    py64    = @{ File = (Find-Installer "python-$PythonSeries.*-amd64.exe");         Dest = 'installers\python';           Required = $true }
    py32    = @{ File = (Find-Installer "python-$PythonSeries.*.exe" '-(amd64|arm64)'); Dest = 'installers\python';        Required = $true }
    nssm64  = @{ File = (Get-ChildItem -LiteralPath $InstallersDir -Recurse -File -Filter nssm.exe | Where-Object { $_.FullName -match '\\win64\\' } | Select-Object -First 1); Dest = 'installers\nssm\win64'; Required = $true }
    nssm32  = @{ File = (Get-ChildItem -LiteralPath $InstallersDir -Recurse -File -Filter nssm.exe | Where-Object { $_.FullName -match '\\win32\\' } | Select-Object -First 1); Dest = 'installers\nssm\win32'; Required = $true }
    ssh64   = @{ File = (Find-Installer 'OpenSSH-Win64-*.msi');                      Dest = 'installers';                  Required = $true }
    ssh32   = @{ File = (Find-Installer 'OpenSSH-Win32-*.msi');                      Dest = 'installers';                  Required = $true }
    ts      = @{ File = (Find-Installer 'tailscale-setup-*.exe');                    Dest = 'installers';                  Required = $true }
    npp64   = @{ File = (Find-Installer 'npp.*.Installer.x64.exe');                  Dest = 'installers\notepad++';        Required = $false }
    npp32   = @{ File = (Find-Installer 'npp.*.Installer.exe');                      Dest = 'installers\notepad++';        Required = $false }
}

foreach ($k in $catalog.Keys) {
    $item = $catalog[$k]
    if (-not $item.File) {
        if ($item.Required) { $Problems.Add("Missing installer: $k"); Write-Host "    MISSING: $k" -ForegroundColor Red }
        else { Write-Warn "Optional installer not found: $k" }
        continue
    }
    $sig = Get-AuthenticodeSignature -LiteralPath $item.File.FullName
    # NSSM ships unsigned; everything else must carry a valid signature
    if ($sig.Status -ne 'Valid' -and $k -notlike 'nssm*') {
        if ($Force) { Write-Warn "$($item.File.Name): signature $($sig.Status) (continuing: -Force)" }
        else { $Problems.Add("$($item.File.Name): signature is $($sig.Status)"); Write-Host "    BAD SIGNATURE: $($item.File.Name) ($($sig.Status))" -ForegroundColor Red; continue }
    }
    $signer = if ($sig.SignerCertificate) { ($sig.SignerCertificate.Subject -split ',')[0] -replace 'CN=', '' } else { 'unsigned' }
    Write-OK "$k : $($item.File.Name) [$signer]"
}
if ($Problems.Count -gt 0) { throw "Installer problems:`n  " + ($Problems -join "`n  ") }

# Free-space check now that sizes are known
$needBytes = ($catalog.Values | Where-Object { $_.File } | ForEach-Object { $_.File.Length } | Measure-Object -Sum).Sum + 300MB
if ($vol -and $vol.SizeRemaining -lt $needBytes) {
    throw ("Not enough free space: need about {0:N0} MB, have {1:N0} MB" -f ($needBytes / 1MB), ($vol.SizeRemaining / 1MB))
}

Write-Step "Copying installers"
foreach ($k in $catalog.Keys) {
    $item = $catalog[$k]
    if (-not $item.File) { continue }
    $destDir = Join-Path $Usb $item.Dest
    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    Copy-Item -LiteralPath $item.File.FullName -Destination (Join-Path $destDir $item.File.Name) -Force
    $item.Rel = (Join-Path $item.Dest $item.File.Name)
}
Write-OK "installers copied"

# --- 3. Deployer files and project ---------------------------------------------
Write-Step "Copying deployer files"
foreach ($f in 'START.ps1', 'README.md', 'LICENSE') {
    Copy-Item -LiteralPath (Join-Path $RepoRoot $f) -Destination (Join-Path $Usb $f) -Force
}
New-Item -ItemType Directory -Path (Join-Path $Usb 'scripts') -Force | Out-Null
Copy-Item -Path (Join-Path $RepoRoot 'scripts\*.ps1') -Destination (Join-Path $Usb 'scripts') -Force
Write-OK "START.ps1 and scripts\ copied"

$projectDir = Join-Path $Usb 'ZelloWatchdog'
$tasksDir   = Join-Path $Usb 'tasks'
$projectFiles = 'zello_watchdog.py', 'updater.py', 'config.ini', 'version.txt', 'auto_update.enabled',
                'requirements_x64.txt', 'requirements_x86.txt'

if (-not $SkipProjectDownload) {
    Write-Step "Downloading ZelloWatchdog project"
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "zw-prepare-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $zip = Join-Path $tmp 'project.zip'
        Invoke-WebRequest -Uri $ProjectZipUrl -OutFile $zip -UseBasicParsing
        Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
        $srcRoot = Get-ChildItem $tmp -Directory | Select-Object -First 1
        if (-not $srcRoot) { throw "Unexpected zip layout" }

        foreach ($d in $projectDir, $tasksDir) {
            if (Test-Path $d) { Remove-Item $d -Recurse -Force }
            New-Item -ItemType Directory -Path $d | Out-Null
        }
        foreach ($f in $projectFiles) {
            $src = Join-Path $srcRoot.FullName $f
            if (-not (Test-Path $src)) { throw "Missing in the project zip: $f" }
            Copy-Item $src (Join-Path $projectDir $f) -Force
        }
        Copy-Item -Path (Join-Path $srcRoot.FullName 'tasks\*.xml') -Destination $tasksDir -Force
        Write-OK ("project version {0}, {1} task XML(s)" -f (Get-Content (Join-Path $projectDir 'version.txt') -Raw).Trim(),
            @(Get-ChildItem $tasksDir -Filter *.xml).Count)
    } finally {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
} else {
    Write-Step "Skipping project download (reusing existing folders)"
}
foreach ($f in $projectFiles) {
    if (-not (Test-Path (Join-Path $projectDir $f))) { throw "Project file missing on target: $f" }
}
if (-not (Get-ChildItem $tasksDir -Filter *.xml -ErrorAction SilentlyContinue)) { throw "No task XML files in $tasksDir" }

# --- 4. Offline wheels ------------------------------------------------------
if (-not $SkipWheels) {
    Write-Step "Downloading pip wheels for x64 and x86 (Python $PythonSeries)"
    $py = (Get-Command python.exe -ErrorAction SilentlyContinue | Where-Object { $_.Source -notlike '*\WindowsApps\*' } | Select-Object -First 1)
    if (-not $py) {
        Write-Warn "No python.exe on this PC - wheels skipped (stations will need internet for pip)"
    } else {
        $abi = 'cp' + ($PythonSeries -replace '\.', '')
        foreach ($pair in @(@('x64', 'win_amd64'), @('x86', 'win32'))) {
            $dest = Join-Path $Usb "wheels\$($pair[0])"
            if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
            New-Item -ItemType Directory -Path $dest -Force | Out-Null
            $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
            $out = & $py.Source -m pip download -r (Join-Path $projectDir "requirements_$($pair[0]).txt") -d $dest `
                --only-binary=:all: --platform "$($pair[1])" --python-version $PythonSeries --implementation cp --abi $abi 2>&1
            $code = $LASTEXITCODE
            $ErrorActionPreference = $prev
            if ($code -ne 0) { Write-Host ($out | Out-String); throw "pip download failed for $($pair[0]) (exit $code)" }
            Write-OK ("{0}: {1} wheel(s)" -f $pair[0], @(Get-ChildItem $dest -Filter *.whl).Count)
        }
    }
}

# --- 5. Support account files -----------------------------------------------
Write-Step "Preparing support account files"
$supportDir = Join-Path $Usb 'support'
New-Item -ItemType Directory -Path $supportDir -Force | Out-Null
$passFile = Join-Path $supportDir 'support-password.txt'

if ($SupportPasswordFile) {
    if (-not (Test-Path -LiteralPath $SupportPasswordFile)) { throw "Password file not found: $SupportPasswordFile" }
    Copy-Item -LiteralPath $SupportPasswordFile -Destination $passFile -Force
    Write-OK "support password copied from the file you provided"
} elseif ((Test-Path $passFile) -and -not $RotateSupportPassword) {
    Write-OK "existing support password kept (use -RotateSupportPassword for a new one)"
} else {
    Set-Content -LiteralPath $passFile -Value (New-RandomPassword) -Encoding UTF8 -NoNewline
    Write-OK "new support password generated in support\support-password.txt (store it in your password manager)"
}

$supportEnabled = $false
if (Test-Path -LiteralPath $PublicKeyPath) {
    Copy-Item -LiteralPath $PublicKeyPath -Destination (Join-Path $supportDir 'support-key.pub') -Force
    $supportEnabled = $true
    Write-OK "public key copied from $PublicKeyPath"
} else {
    Write-Warn "No public key at $PublicKeyPath - the support account will be disabled in the configs. Create one with ssh-keygen and re-run."
}

# --- 6. Secrets and configs --------------------------------------------------
Write-Step "Writing configs"
$telegramToken = ''; $telegramChat = ''; $radioPassword = ''; $tsKey = ''
if (-not $NoPrompt) {
    Write-Host "    Hidden prompts. Leave empty to keep a placeholder (or to be asked on the station)."
    $telegramToken = Read-Secret "    Telegram bot token"
    $telegramChat  = Read-Host   "    Telegram chat id"
    $radioPassword = Read-Secret "    Windows password for the radio account '$RadioUserName'"
    $tsKey         = Read-Secret "    Tailscale auth key (reusable + tagged recommended)"
}

foreach ($arch in 'x64', 'x86') {
    $cfg = Get-Content (Join-Path $RepoRoot "config_$arch.json") -Raw | ConvertFrom-Json
    $suffix = if ($arch -eq 'x64') { '64' } else { '32' }

    $cfg.user.name = $RadioUserName
    $cfg.user.password = $radioPassword
    $cfg.applications.zelloInstaller   = $catalog.zello.Rel
    $cfg.applications.pythonInstaller  = $catalog["py$suffix"].Rel
    $cfg.applications.nssm             = $catalog["nssm$suffix"].Rel
    if ($catalog["npp$suffix"].File) { $cfg.applications.notepadPlusPlus = $catalog["npp$suffix"].Rel }
    else { $cfg.applications.PSObject.Properties.Remove('notepadPlusPlus') }

    $cfg.openssh.msi = $catalog["ssh$suffix"].Rel
    $cfg.support.accountName = $SupportAccount
    $cfg.support.enable = $supportEnabled
    $cfg.tailscale.installer = $catalog.ts.Rel
    if ($tsKey) { $cfg.tailscale.authKey = $tsKey }

    if ($telegramToken) { $cfg.environmentVariables.TELEGRAM_BOT_TOKEN = $telegramToken }
    if ($telegramChat)  { $cfg.environmentVariables.TELEGRAM_CHAT_ID = $telegramChat }

    $cfg | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $Usb "config_$arch.json") -Encoding UTF8
    Write-OK "config_$arch.json"
}
Remove-Variable telegramToken, radioPassword, tsKey -ErrorAction SilentlyContinue

# --- 7. Integrity manifest ---------------------------------------------------
Write-Step "Writing integrity manifest"
$manifest = [ordered]@{}
foreach ($dir in 'installers', 'wheels') {
    $p = Join-Path $Usb $dir
    if (-not (Test-Path $p)) { continue }
    Get-ChildItem $p -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Substring($Usb.Length).TrimStart('\')
        $manifest[$rel] = (Get-FileHash $_.FullName -Algorithm SHA256).Hash
    }
}
$manifest | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Usb 'manifest.sha256.json') -Encoding UTF8
Write-OK "$($manifest.Count) file(s) hashed"

# --- 8. Final verification ---------------------------------------------------
Write-Step "Verifying the target"
$expected = @('START.ps1', 'config_x64.json', 'config_x86.json', 'manifest.sha256.json',
              'scripts\Install-OpenSsh.ps1', 'scripts\New-SupportAccount.ps1', 'scripts\Install-Tailscale.ps1',
              'scripts\Set-TelegramCredentials.ps1', 'scripts\New-Shortcuts.ps1',
              'support\support-password.txt') + ($projectFiles | ForEach-Object { "ZelloWatchdog\$_" }) +
            ($catalog.Values | Where-Object { $_.File } | ForEach-Object { $_.Rel })
$missing = @($expected | Where-Object { -not (Test-Path -LiteralPath (Join-Path $Usb $_)) })
if ($missing.Count -gt 0) {
    $missing | ForEach-Object { Write-Host "    MISSING: $_" -ForegroundColor Red }
    throw "The target is incomplete ($($missing.Count) file(s) missing)."
}
Write-OK "$($expected.Count) expected files present"

$sizeMb = [math]::Round(((Get-ChildItem $Usb -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum) / 1MB, 1)
Write-Host "`n========================================" -ForegroundColor Green
Write-Host " DEPLOYER READY - $Usb ($sizeMb MB)" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host " Run START.ps1 on each station (right-click > Run with PowerShell)."
Write-Host " The target holds secrets (support password, configs). Keep it safe; do not commit it."
Write-Host "========================================`n" -ForegroundColor Green
