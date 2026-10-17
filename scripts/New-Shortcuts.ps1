#Requires -Version 5.1
<#
.SYNOPSIS
    Creates the ZelloWatchdog desktop shortcuts for the radio user.

.DESCRIPTION
    Writes Start/Stop batch files into the install folder and these shortcuts on the user's desktop:
      Start_Zellowatchdog   starts the service (asks for administrator rights)
      Stop_Zellowatchdog    stops the service (asks for administrator rights)
      zello_watchdog        opens the install folder
      ZelloDesktop          opens the Zello data folder (%APPDATA%\ZelloDesktop)
    Safe to run again: existing shortcuts are overwritten.

.PARAMETER User
    Windows account that owns the desktop.

.PARAMETER InstallDir
    ZelloWatchdog install folder.
#>
param(
    [Parameter(Mandatory)][string]$User,
    [Parameter(Mandatory)][string]$InstallDir,
    [string]$ServiceName = 'ZelloWatchdog'
)

$ErrorActionPreference = 'Stop'

$profileDir = "C:\Users\$User"
$desktop    = Join-Path $profileDir 'Desktop'
if (-not (Test-Path -LiteralPath $desktop)) { New-Item -ItemType Directory -Path $desktop -Force | Out-Null }
if (-not (Test-Path -LiteralPath $InstallDir)) { throw "Install folder not found: $InstallDir" }

$nssm = '%WINDIR%\System32\nssm.exe'
$bats = @{
    'Start_Zellowatchdog' = "@echo off`r`n`"$nssm`" start $ServiceName`r`necho.`r`npause`r`n"
    'Stop_Zellowatchdog'  = "@echo off`r`n`"$nssm`" stop $ServiceName`r`necho.`r`npause`r`n"
}
foreach ($name in $bats.Keys) {
    [IO.File]::WriteAllText((Join-Path $InstallDir "$name.bat"), $bats[$name], [Text.Encoding]::ASCII)
}

function New-Shortcut([string]$Name, [string]$Target, [string]$WorkDir, [switch]$RunAsAdmin) {
    $path = Join-Path $desktop "$Name.lnk"
    $sh = New-Object -ComObject WScript.Shell
    $lnk = $sh.CreateShortcut($path)
    $lnk.TargetPath = $Target
    if ($WorkDir) { $lnk.WorkingDirectory = $WorkDir }
    $lnk.Save()
    if ($RunAsAdmin) {
        # "Run as administrator" is bit 0x20 of the byte at offset 0x15 in the .lnk header
        $bytes = [IO.File]::ReadAllBytes($path)
        $bytes[0x15] = $bytes[0x15] -bor 0x20
        [IO.File]::WriteAllBytes($path, $bytes)
    }
    Write-Host "  Shortcut: $path"
}

New-Shortcut 'Start_Zellowatchdog' (Join-Path $InstallDir 'Start_Zellowatchdog.bat') $InstallDir -RunAsAdmin
New-Shortcut 'Stop_Zellowatchdog'  (Join-Path $InstallDir 'Stop_Zellowatchdog.bat')  $InstallDir -RunAsAdmin
New-Shortcut 'zello_watchdog'      $InstallDir ''
New-Shortcut 'ZelloDesktop'        (Join-Path $profileDir 'AppData\Roaming\ZelloDesktop') ''
