# ZelloWatchdog Deployer

A portable USB provisioning tool that deploys [ZelloWatchdog](https://github.com/marcoagbarreto/ZelloWatchdog) onto a fresh Windows machine in a single script execution. It installs all prerequisites, configures the system for unattended headless operation, and registers ZelloWatchdog as a Windows service — no manual setup required.

---

## What It Does

`START.ps1` performs the following steps automatically:

| Step | Action |
|---|---|
| 1 | Sets the local user account password |
| 2 | Enables Remote Desktop and disables NLA |
| 3 | Installs Zello (silent) |
| 4 | Installs Python (silent, all users, added to PATH) |
| 5 | Installs Notepad++ (silent, optional) |
| 6 | Copies the ZelloWatchdog project to the user's Documents folder |
| 7 | Installs Python dependencies (`requests`, `psutil`) via pip |
| 8 | Sets environment variables (Telegram bot token & chat ID) |
| 9 | Imports Windows Scheduled Tasks (Zello launcher, auto-update, power management) |
| 10 | Installs NSSM and registers ZelloWatchdog as a Windows service |
| 11 | Configures power settings (disable sleep/hibernate on AC) |
| 12 | Enables auto-login for the target user |

The script auto-detects whether the OS is **x64** or **x86** and loads the corresponding config file.

---

## Prerequisites

- **Windows 10/11** (x64 or x86)
- A local user account must already exist on the target machine (the script sets its password, it does not create the account)

---

## USB Drive Setup

### Step 1: Clone this repository

```powershell
git clone https://github.com/mangobax/ZelloWatchdog-Deployer.git
```

### Step 2: Download the ZelloWatchdog project

Download or clone the [ZelloWatchdog](https://github.com/mangobax/ZelloWatchdog) repository and place its contents inside the `ZelloWatchdog/` folder:

```powershell
git clone https://github.com/mangobax/ZelloWatchdog.git zello_watchdog_repo
```

Copy the required files:

```powershell
Copy-Item zello_watchdog_repo\zello_watchdog.py   ZelloWatchdog\
Copy-Item zello_watchdog_repo\updater.py           ZelloWatchdog\
Copy-Item zello_watchdog_repo\config.ini           ZelloWatchdog\
Copy-Item zello_watchdog_repo\version.txt          ZelloWatchdog\
Copy-Item zello_watchdog_repo\auto_update.enabled  ZelloWatchdog\
Copy-Item zello_watchdog_repo\requirements_x64.txt ZelloWatchdog\
Copy-Item zello_watchdog_repo\requirements_x86.txt ZelloWatchdog\
```

### Step 3: Download the scheduled task XMLs

From the same ZelloWatchdog repository, copy the task XML files into the `tasks/` folder:

```powershell
Copy-Item zello_watchdog_repo\tasks\*.xml tasks\
```

You should have these four files:

- `[Radio] Application - LaunchZelloGUI.xml`
- `[Radio] Application - AutoUpdate.xml`
- `[Radio] Power Management - Scheduled Sleep.xml`
- `[Radio] Power Management - Scheduled Wake.xml`

### Step 4: Download the installers

Place the following installers inside the `installers/` folder. The script expects the exact subfolder structure shown below — update the paths in `config_x64.json` / `config_x86.json` if your filenames differ.

| Installer | Download Link | Destination |
|---|---|---|
| **Zello Desktop v2.6** | [zello.com](https://zello.com/) | `installers\ZelloSetup_2_6_0.exe` |
| **Python 3.12+** (x64) | [python.org](https://www.python.org/downloads/) | `installers\python\python-3.x.x-amd64.exe` |
| **Python 3.12+** (x86) | [python.org](https://www.python.org/downloads/) | `installers\python\python-3.x.x-x86.exe` |
| **NSSM 2.24** | [nssm.cc](https://nssm.cc/download) | `installers\nssm-2.24\win64\nssm.exe` and `installers\nssm-2.24\win32\nssm.exe` |
| **Notepad++** (optional) | [notepad-plus-plus.org](https://notepad-plus-plus.org/downloads/) | `installers\notepad++\npp.x.x.x.Installer.x64.exe` and/or `npp.x.x.x.Installer.exe` |

> **Note:** If you use different installer versions or filenames, update the `applications` section in both config JSON files to match.

### Step 5: Edit the config files

Edit `config_x64.json` and `config_x86.json` to match your environment:

```jsonc
{
  "user": {
    "name": "radio",              // Local Windows username
    "password": "radio",          // Password to set for that user
    "autoLogin": true             // Enable automatic login on boot
  },
  "environmentVariables": {
    "TELEGRAM_BOT_TOKEN": "...",  // Your Telegram bot token
    "TELEGRAM_CHAT_ID": "..."    // Your Telegram chat ID
  }
}
```

See the [Configuration Reference](#configuration-reference) below for all available options.

---

## Required Folder Structure

After completing all steps above, your deployer folder should look like this:

```
ZelloWatchdog Deployer/
│
├── START.ps1                          ← Provisioning script (run this)
├── config_x64.json                    ← Config for 64-bit Windows
├── config_x86.json                    ← Config for 32-bit Windows
│
├── installers/                        ← ⬇ Download these yourself
│   ├── ZelloSetup_2_6_0.exe
│   ├── python/
│   │   ├── python-3.x.x-amd64.exe
│   │   └── python-3.x.x-x86.exe
│   ├── nssm-2.24/
│   │   ├── win64/
│   │   │   └── nssm.exe
│   │   └── win32/
│   │       └── nssm.exe
│   └── notepad++/                     ← Optional
│       ├── npp.x.x.x.Installer.x64.exe
│       └── npp.x.x.x.Installer.exe
│
├── tasks/                             ← ⬇ From ZelloWatchdog repo
│   ├── [Radio] Application - AutoUpdate.xml
│   ├── [Radio] Application - LaunchZelloGUI.xml
│   ├── [Radio] Power Management - Scheduled Sleep.xml
│   └── [Radio] Power Management - Scheduled Wake.xml
│
├── ZelloWatchdog/                     ← ⬇ From ZelloWatchdog repo
│   ├── zello_watchdog.py
│   ├── updater.py
│   ├── config.ini
│   ├── version.txt
│   ├── auto_update.enabled
│   ├── requirements_x64.txt
│   └── requirements_x86.txt
│
└── logs/                              ← Created automatically
    └── provision-YYYYMMDD-HHmmss.log
```

> Items marked **⬇** are not included in this repository and must be obtained separately.

---

## Usage

1. Copy the entire deployer folder onto a USB flash drive
2. Plug the USB into the target Windows machine
3. Right-click `START.ps1` → **"Run with PowerShell"**

The script will:
- Self-elevate to Administrator (UAC prompt)
- Auto-detect x64/x86 and load the correct config
- Execute all 12 provisioning steps
- Write a transcript log to `logs/`

After the script completes:

1. **Open Zello**, log in to your account, and close it (this creates the WAL database file the watchdog monitors)
2. **Start the service:**
   ```powershell
   nssm start ZelloWatchdog
   ```
3. **Reboot** to verify auto-login and service auto-start work correctly

---

## Configuration Reference

Both `config_x64.json` and `config_x86.json` share the same schema. The only differences are the installer paths (pointing to the correct architecture).

| Section | Key | Description |
|---|---|---|
| `user` | `name` | Local Windows username to configure |
| `user` | `password` | Password to set for that account |
| `user` | `autoLogin` | `true` to enable auto-login on boot (plaintext password stored in registry) |
| `remoteDesktop` | `enable` | `true` to enable Remote Desktop |
| `remoteDesktop` | `disableNLA` | `true` to disable Network Level Authentication (for older RDP clients) |
| `paths` | `documentsSubfolder` | Subfolder name under `C:\Users\<user>\Documents\` where the watchdog is installed |
| `applications` | `zelloInstaller` | Relative path to the Zello installer |
| `applications` | `pythonInstaller` | Relative path to the Python installer |
| `applications` | `notepadPlusPlus` | Relative path to the Notepad++ installer (optional — remove this key to skip) |
| `applications` | `nssm` | Relative path to `nssm.exe` |
| `service` | `name` | Windows service name (`ZelloWatchdog`) |
| `service` | `pythonExe` | Python executable name or path (resolved via PATH after install) |
| `service` | `script` | Filename of the watchdog script inside the project folder |
| `power` | `sleep` | AC standby timeout in minutes (`0` = never) |
| `power` | `hibernate` | AC hibernate timeout in minutes (`0` = never) |
| `power` | `displayOffMinutes` | Turn off display after N minutes on AC |
| `environmentVariables` | `TELEGRAM_BOT_TOKEN` | Telegram bot token (set as system-wide env var) |
| `environmentVariables` | `TELEGRAM_CHAT_ID` | Telegram chat ID (set as system-wide env var) |

---

## Provisioning Steps Detail

### Step 1 — Set Local Account Password
Sets the password for the local user account specified in the config. The account must already exist.

### Step 2 — Remote Desktop
Enables RDP and opens the firewall rule. Optionally disables NLA for compatibility with older clients.

### Step 3 — Install Zello
Runs the Zello installer in silent mode (`/S`).

### Step 4 — Install Python
Runs the Python installer in silent mode with `InstallAllUsers=1` and `PrependPath=1`. Refreshes `PATH` in the current session so `pip` is immediately available.

### Step 5 — Install Notepad++ (optional)
If `notepadPlusPlus` is defined in the config, installs it silently. Otherwise skips.

### Step 6 — Copy ZelloWatchdog Project
Copies the `ZelloWatchdog/` folder to `C:\Users\<user>\Documents\ZelloWatchdog\`.

### Step 7 — Install Python Dependencies
Runs `pip install -r requirements_x64.txt` (or `x86`) to install `requests` and `psutil`.

### Step 8 — Environment Variables
Sets `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID` as system-wide environment variables.

### Step 9 — Import Scheduled Tasks
Imports all `.xml` files from the `tasks/` folder into Windows Task Scheduler. Automatically replaces the `<UserId>` in each XML with the resolved SID of the target user, so the tasks work regardless of machine name. The AutoUpdate task paths are patched to match the actual install location.

### Step 10 — Install NSSM + Create Service
Copies `nssm.exe` to `System32`, creates the `ZelloWatchdog` service pointing to `python.exe zello_watchdog.py`, and configures auto-start and restart-on-failure. The service is installed but **not started** — start it after Zello's first-run setup.

### Step 11 — Power Configuration
Disables sleep and hibernate on AC power. Sets the display-off timeout. Prevents idle standby.

### Step 12 — Auto-Login
Configures Windows to automatically log in as the target user on boot (via Winlogon registry keys). Required for Zello to run in an interactive GUI session on headless machines.

---

## Logs

Every run creates a timestamped transcript in the `logs/` folder:

```
logs/provision-20260226-190000.log
```

Review this file if anything goes wrong during provisioning.

---

## Security Notes

- **Passwords** in `config_x64.json` / `config_x86.json` are stored in **plaintext**. Do not commit these files with real credentials to a public repository.
- **Auto-login** stores the password in the Windows registry in plaintext. This is acceptable for dedicated kiosk/radio machines on a private network.
- **Telegram credentials** are set as system-wide environment variables. They are visible to any process on the machine.

> **Recommendation:** Update the config files with real credentials only on the USB drive itself. Keep the repository copies with placeholder values.

---

## License

This project is licensed under the [Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International (CC BY-NC-SA 4.0)](https://creativecommons.org/licenses/by-nc-sa/4.0/).
