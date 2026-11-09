# Privacy Notice

This notice describes how the `ram-altman.sh` script in the **Ram-Altman** repository handles information. It covers the script as currently implemented, not the separate `ram-altman.lol` website, GitHub, or any email service used to deliver messages.

## What the script reads

The script reads Linux memory statistics from `/proc/meminfo` (or a file selected through `RAM_ALTMAN_MEMINFO`). It calculates total, used, and available RAM and the percentage available. It does **not** inspect running processes, files, browsing activity, or the contents of memory.

## What stays on your computer

In normal mode, each run appends a sample to `usage.csv` containing:

- A timestamp, including the local time-zone offset
- Total RAM in KiB (`total_kb`)
- Used RAM in KiB (`used_kb`)
- Available RAM in KiB (`available_kb`)
- Available RAM as a percentage (`available_pct`)

By default, these records are stored under `~/.local/state/ram-altman/`. You can choose another directory with `RAM_ALTMAN_STATE_DIR` (or change the base state directory using `XDG_STATE_HOME`). The script also keeps a `last_sent` date and files used to rotate email templates; it may create a lock file to prevent overlapping runs.

The CSV log is trimmed after it exceeds 10 MiB, retaining its header and up to the last 50,000 samples. Other state files have no automatic expiration. The script does not encrypt these local files; access depends on your operating system's file permissions.

## What can leave your computer

**The script does not send data to a hard-coded address, to the project maintainer, or to OpenAI.** It has no built-in analytics or telemetry endpoint.

A normal run **can send an email to the address you configure** in `RAM_ALTMAN_TO`, using the sender address in `RAM_ALTMAN_FROM` and, optionally, the display name in `RAM_ALTMAN_FROM_NAME`. Both recipient and sender addresses must be configured for normal operation. If available RAM exceeds `RAM_ALTMAN_THRESHOLD` (10% by default), the script attempts to send an email at most once per day, using the system's `sendmail`, `msmtp`, or `mail` command. The actual recipient is whoever you configure; it is not necessarily Sam Altman.

Depending on the randomly selected message template, the email may include your machine's total RAM, available RAM, and available percentage, rounded for display. Email headers or the mail system also carry delivery details such as the configured sender and recipient addresses, subject, and date. The script does not attach the local CSV log.

Once sent, the message and delivery metadata may be processed, stored, forwarded, or logged by your email provider, intermediary mail servers, and the recipient. Their practices are outside this project's control. **Email is not a private channel by default.** Only send usage information to an address you intend to contact, and respect requests to stop emailing.

## Your choices

- `./ram-altman.sh --status` prints the current memory figures locally without sending an email or writing usage samples.
- `./ram-altman.sh --dry-run` previews a potential email locally without sending it or writing usage samples.
- Do not configure a real recipient or schedule normal runs if you do not want memory information emailed.
- Stop the script or remove its cron entry to prevent future samples and emails.
- Delete the state directory (by default `~/.local/state/ram-altman/`) to remove the script's local logs and state. This does **not** delete copies of previously sent emails from mailboxes or mail servers.

## Scope and updates

This notice reflects the repository's shell script at the time it was written. Review the source before running a changed version, and check the privacy practices of your configured email provider separately. If you find a discrepancy between this notice and the code, please open an issue in the repository.
