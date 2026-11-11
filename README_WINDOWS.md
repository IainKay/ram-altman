# RAM Altman for Windows

Native Windows support for RAM Altman. This implementation checks physical memory, records samples to CSV, and can send an email alert when available RAM rises above a configurable threshold.

It uses PowerShell and the Resend or Brevo email API. It does **not** require WSL, Python, SMTP credentials, or third-party PowerShell modules.

> **Contribution note:** This directory is intended as a proposed Windows port for an upstream repository. Check that repository's licence, contribution guide, naming conventions, and existing project structure before copying these files into it. Do not replace the upstream licence with a new one.

## Files

| File | Purpose |
|---|---|
| `ram-altman.ps1` | Main Windows implementation |
| `ram-altman.bat` | Convenient launcher |
| `README-WINDOWS.md` | Windows installation and usage guide |
| `PULL_REQUEST_DESCRIPTION.md` | Suggested pull request description |
| `.gitignore` | Excludes local/editor artefacts |

## Requirements

- Windows 10 or Windows 11
- Windows PowerShell 5.1 or PowerShell 7+
- Internet access when sending an alert
- A Resend or Brevo account and a verified sender address/domain

No administrator privileges are required for normal use. The configuration is stored under the current Windows user's `%APPDATA%` directory.

## Installation

1. Download or clone the repository.
2. Keep `ram-altman.ps1` and `ram-altman.bat` in the same directory.
3. Open Command Prompt or PowerShell in that directory.
4. Run setup:

```powershell
.\ram-altman.bat -Setup
```

If Windows blocks local script execution, the batch launcher uses a process-scoped `-ExecutionPolicy Bypass`. It does not change the machine's or user's PowerShell execution policy.

## Email provider setup

The setup wizard supports:

### Resend

1. Create an API key in the Resend dashboard: <https://resend.com/api-keys>
2. Verify the sender domain/address as required by Resend.
3. Select Resend in the setup wizard and enter the key.

### Brevo

1. Create an API key in the Brevo dashboard: <https://app.brevo.com/settings/keys/api>
2. Configure and verify a sender in Brevo.
3. Select Brevo in the setup wizard and enter the key.

The script does not send a test message during setup. The first real alert is the first API send attempt, because sending a test email without explicit consent would be a rather questionable setup wizard feature.

## Usage

Run a normal memory check:

```powershell
.\ram-altman.bat
```

Configure or replace the provider settings:

```powershell
.\ram-altman.bat -Setup
```

Show current memory and configuration status:

```powershell
.\ram-altman.bat -Status
```

Preview an alert without sending an email or changing the daily-send state:

```powershell
.\ram-altman.bat -DryRun
```

Show command help:

```powershell
.\ram-altman.bat -Help
```

The alert threshold is entered during setup. The default is 10 percent. An alert is sent only when available physical memory is **strictly greater than** the configured threshold.

## Run automatically with Task Scheduler

1. Open **Task Scheduler**.
2. Choose **Create Basic Task**.
3. Give it a name such as `RAM Altman`.
4. Choose a schedule, such as **Daily**.
5. Set the action to **Start a program**.
6. Program/script:

```text
powershell.exe
```

7. Add arguments (replace the path with the actual location):

```text
-NoProfile -ExecutionPolicy Bypass -File "C:\Path\To\ram-altman.ps1"
```

8. Finish the wizard.
9. Open the task's properties and review **Run only when user is logged on** versus **Run whether user is logged on or not**. DPAPI credentials are protected for the account that created the configuration, so use the same Windows account for setup and scheduled execution.
10. Run the task manually once and inspect its history and the CSV log.

For frequent monitoring, use **Create Task** rather than the Basic Task wizard and configure a repeat interval appropriate to your needs. The script's daily limit prevents more than one recorded successful alert per local calendar day.

## Data and security

All runtime data is stored here:

```text
%APPDATA%\RAMAltman\
```

- `config.json`: provider settings and DPAPI-encrypted API key
- `state.json`: date of the last provider-accepted alert
- `memory.csv`: memory samples
- `run.lock`: process lock file

The API key is encrypted with Windows DPAPI for the current user. It is not stored as plaintext in the configuration file. The key can normally be decrypted only by the same Windows user on the same Windows installation. Re-run setup if you move to another Windows account or reinstall Windows.

Do not commit your real `config.json`, API key, state, or memory logs to GitHub. The `.gitignore` in this contribution folder excludes common local artefacts, but runtime data is stored outside the project directory anyway.

## Behaviour and limitations

- Uses `Win32_OperatingSystem` CIM values to read total and free physical memory.
- Logs each successful memory sample to CSV.
- Sends an alert only when available RAM is above the configured threshold.
- Records the local date only after the provider API call succeeds.
- Uses an exclusive lock file to avoid overlapping runs.
- `-DryRun` does not send an email or update the daily alert state.
- A provider accepting an API request does not guarantee final inbox delivery.
- If the provider accepts a message but the response is lost, a later run could retry. No client-side script can guarantee exactly-once email delivery across an uncertain network failure.
- The script does not delete or rotate the CSV log automatically.

## Troubleshooting

### `Configuration not found`

Run:

```powershell
.\ram-altman.bat -Setup
```

### API authentication or sender error

Check that the API key is correct, active, and permitted to send. Confirm that the sender address/domain is verified with the provider.

### Scheduled task cannot decrypt the API key

Run setup while signed in as the same Windows account that runs the scheduled task. DPAPI-protected configuration is user-specific.

### No email is sent

Check the available RAM percentage with:

```powershell
.\ram-altman.bat -Status
```

The alert condition is `available percentage > threshold`, not greater-than-or-equal. Also check whether an alert has already been recorded for the current local date.

### PowerShell cannot find the script

Keep `ram-altman.bat` and `ram-altman.ps1` in the same directory.

## Contributing

Before submitting this port upstream:

1. Read the upstream contribution guidelines.
2. Confirm that the upstream licence permits your contribution.
3. Test on Windows 10/11 with Windows PowerShell 5.1 and, if possible, PowerShell 7.
4. Test setup, status, dry-run, below-threshold, above-threshold, provider errors, and repeated same-day runs.
5. Do not include real API keys, email addresses, configuration files, or personal logs in commits.
6. Adapt paths and documentation to the upstream project's existing layout.

This implementation has not been independently validated on every Windows version or provider account configuration. Treat it as a proposed contribution until those tests are completed.
