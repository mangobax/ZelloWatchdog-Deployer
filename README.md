# ZelloWatchdog Deployer

A portable USB provisioning tool that deploys [ZelloWatchdog](https://github.com/mangobax/ZelloWatchdog) onto a fresh Windows machine in a single script execution. It installs all prerequisites, configures the system for unattended headless operation, sets up remote access, and registers ZelloWatchdog as a Windows service.

Two scripts do the work:

| Script | Runs on | Purpose |
|---|---|---|
| `prepare-usb.ps1` | Your admin PC | Builds the USB: installers, project files, offline pip wheels, support account files, configs, integrity manifest |
| `START.ps1` | Each radio station | Provisions the machine from the USB |

---

## What `START.ps1` does

| Step | Action |
|---|---|
| 1 | Asks for the Windows username (default from config), creates the local administrator account if it does not exist, sets its password |
| 2 | Enables Remote Desktop and disables NLA |
| 3 | Installs the official Win32-OpenSSH MSI and creates an optional support account with an authorized SSH key |
| 4 | Installs Tailscale and joins the tailnet with an auth key |
| 5 | Installs Zello (silent) |
| 6 | Installs Python (silent, all users, added to PATH) |
| 7 | Installs Notepad++ (silent, optional) |
| 8 | Copies the ZelloWatchdog project to the user's Documents folder |
| 9 | Installs `requests` and `psutil` with pip (offline from the USB wheels when present) |
| 10 | Sets environment variables (Telegram bot token & chat ID) |
| 11 | Imports Windows Scheduled Tasks (Zello launcher, auto-update, power management) |
| 12 | Installs NSSM and registers ZelloWatchdog as a Windows service |
| 13 | Configures power settings (disable sleep/hibernate on AC) |
| 14 | Enables auto-login for the target user |

The station name used in alerts is the Windows computer name; the script does not rename the machine.

The script auto-detects whether the OS is **x64** or **x86** and loads `config_x64.json` or `config_x86.json`.

---

## Prerequisites

- **Windows 10 or later** (x64 or x86). Windows 10 builds older than 2004 are supported because OpenSSH comes from the official MSI instead of the Windows capability.
- On your admin PC: PowerShell 5.1+, internet access, Python (any version, only used to download pip wheels), and an SSH key pair if you want remote support (`ssh-keygen -t ed25519`).
- A Tailscale **auth key** (create it in the Tailscale admin console; reusable and tagged is recommended).
- A Telegram bot token and chat ID for alerts.

---

## Building the USB

### Step 1: Download the installers

Put these files in one folder on your admin PC (subfolders are fine; the script searches recursively):

| Installer | Where to get it | Expected name pattern |
|---|---|---|
| Zello Desktop | [zello.com](https://zello.com/) | `ZelloSetup_*.exe` |
| Python 3.12 (x64 and x86) | [python.org](https://www.python.org/downloads/) | `python-3.12.*-amd64.exe`, `python-3.12.*.exe` |
| NSSM 2.24 | [nssm.cc](https://nssm.cc/download) | `...\win64\nssm.exe`, `...\win32\nssm.exe` |
| Win32-OpenSSH MSI (x64 and x86) | [Win32-OpenSSH releases](https://github.com/PowerShell/Win32-OpenSSH/releases) | `OpenSSH-Win64-*.msi`, `OpenSSH-Win32-*.msi` |
| Tailscale | [tailscale.com](https://tailscale.com/download/windows) | `tailscale-setup-*.exe` |
| Notepad++ (optional) | [notepad-plus-plus.org](https://notepad-plus-plus.org/downloads/) | `npp.*.Installer.x64.exe`, `npp.*.Installer.exe` |

Every installer except NSSM (which is unsigned) must carry a valid Authenticode signature; `prepare-usb.ps1` refuses anything else unless you pass `-Force`.

### Step 2: Run `prepare-usb.ps1`

```powershell
git clone https://github.com/mangobax/ZelloWatchdog-Deployer.git
cd ZelloWatchdog-Deployer
.\prepare-usb.ps1 -UsbPath D:\ -InstallersDir "C:\path\to\installers"
```

It will:

1. Validate the target (removable drive, free space) and the installers' signatures.
2. Copy the installers into the layout `START.ps1` expects.
3. Download the ZelloWatchdog project (`main` branch) and copy the needed files and task XMLs.
4. Download pip wheels for x64 and x86.
5. Create `support\` with the support account password (generated, or reused from `-SupportPasswordFile`) and your SSH public key.
6. Ask, at hidden prompts, for the Telegram token and chat ID, the Windows password for the radio account, and the Tailscale auth key, and write them into the configs **on the USB only**.
7. Write `manifest.sha256.json` so `START.ps1` can detect a corrupted or altered installer.

Useful parameters: `-PythonSeries`, `-SupportAccount`, `-SupportPasswordFile`, `-RotateSupportPassword`, `-PublicKeyPath`, `-RadioUserName`, `-SkipWheels`, `-SkipProjectDownload`, `-NoPrompt`, `-Force`. Run `Get-Help .\prepare-usb.ps1 -Full` for details.

### Resulting USB layout

```
D:\
├── START.ps1
├── config_x64.json            ← generated, contains secrets
├── config_x86.json            ← generated, contains secrets
├── manifest.sha256.json
├── scripts\
│   ├── Install-OpenSsh.ps1
│   ├── New-SupportAccount.ps1
│   └── Install-Tailscale.ps1
├── installers\                ← Zello, Python, NSSM, OpenSSH, Tailscale, Notepad++
├── wheels\x64, wheels\x86     ← offline pip packages
├── ZelloWatchdog\             ← project files
├── tasks\                     ← scheduled task XMLs
├── support\                   ← support password + public key (sensitive)
└── logs\                      ← created on the stations
```

---

## Using the USB on a station

1. Plug the USB into the target Windows machine.
2. Right-click `START.ps1` → **Run with PowerShell** (it self-elevates; a UAC prompt appears).
3. Enter the Windows username when asked (or run `.\START.ps1 -UserName radio`).

The script writes a transcript to `logs\`. After it finishes:

1. **Open Zello**, log in, and close it (this creates the WAL database file the watchdog monitors).
2. **Start the service:** `nssm start ZelloWatchdog`
3. **Reboot** to verify auto-login and service auto-start.

---

## Configuration reference

`config_x64.json` and `config_x86.json` share one schema; they differ only in the installer paths. The repository copies are templates with placeholders; `prepare-usb.ps1` writes the real ones to the USB.

| Section | Key | Description |
|---|---|---|
| `user` | `name` | Default Windows username offered by `START.ps1` |
| `user` | `password` | Password for that account. Empty = `START.ps1` asks for it |
| `user` | `autoLogin` | `true` to enable auto-login (plaintext password in the registry) |
| `remoteDesktop` | `enable` / `disableNLA` | Enable RDP / disable Network Level Authentication |
| `paths` | `documentsSubfolder` | Folder on the USB holding the project |
| `paths` | `installFolder` | Folder under `C:\Users\<user>\Documents\` where it is installed |
| `applications` | `zelloInstaller`, `pythonInstaller`, `notepadPlusPlus`, `nssm` | Relative installer paths (remove `notepadPlusPlus` to skip) |
| `openssh` | `enable`, `msi`, `firewallProfile` | OpenSSH MSI and the network profile its firewall rule stays on (`Private` by default) |
| `support` | `enable`, `accountName`, `passwordFile`, `publicKeyFile` | Support administrator account and the files that feed it |
| `tailscale` | `enable`, `installer`, `authKey`, `hostname` | Tailscale install and join (hostname defaults to the computer name) |
| `service` | `name`, `pythonExe`, `script` | NSSM service definition |
| `power` | `sleep`, `hibernate`, `displayOffMinutes` | AC timeouts in minutes (`0` = never) |
| `environmentVariables` | `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` | Set as system-wide environment variables |

---

## Notes on the steps

- **Local account:** the account becomes a local administrator because the auto-update task must stop and start the service.
- **Scheduled tasks:** the XML files use `InteractiveToken` (no stored password), so they run while the user is logged on, which auto-login guarantees. The `UserId` is replaced with the resolved SID of the target user, the update task paths are patched to the real install folder, and the Zello launcher path is detected (Zello installs under `Program Files (x86)` only on 64-bit Windows).
- **OpenSSH:** the official MSI is used on every build. Authorized keys go to `C:\ProgramData\ssh\administrators_authorized_keys` with a locked-down ACL.
- **Tailscale:** the auth key is passed through an environment variable and masked in the transcript.
- **Offline pip:** `START.ps1` uses `pip --no-index --find-links wheels\<arch>` when the wheels exist and falls back to the internet otherwise.
- **Integrity:** if `manifest.sha256.json` is present, every installer is checked against it before it runs.

---

## Logs

Every run creates a timestamped transcript in `logs\` (for example `provision-20260226-190000.log`); the support-account step appends to `logs\support-accounts.csv` (no passwords). Review them if anything goes wrong.

---

## Security notes

- The generated configs, `support\support-password.txt`, the Telegram token and the Tailscale key all live on the USB in **plaintext**. Treat the USB as sensitive: keep it supervised, consider BitLocker To Go, and wipe the `support\` folder and configs when the deployment round ends.
- **Never commit** the generated configs or the `support\` folder. The repository `.gitignore` excludes the USB artifacts.
- **Auto-login** stores the account password in the registry in plaintext. That is acceptable for dedicated radio machines in controlled locations.
- The Telegram credentials are system-wide environment variables, visible to any process on the machine.
- The OpenSSH firewall rule defaults to the `Private` profile. Widen it (`openssh.firewallProfile`) only on trusted networks.

---

## License

This project is licensed under the [Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International (CC BY-NC-SA 4.0)](https://creativecommons.org/licenses/by-nc-sa/4.0/).
