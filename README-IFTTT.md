<CodeBlock language="markdown" editable>
# RAM Altman


A RAM monitoring script with an unnecessarily public reporting system.

RAM Altman monitors available physical memory on your Windows computer and, when a configured threshold is exceeded, generates a randomised status message and sends it to IFTTT.

IFTTT then publishes the message to your connected X account.

Because apparently checking Task Manager wasn't enough.



Features
- Native Windows memory monitoring.
- IFTTT Webhooks integration.
- Automatic X post generation.
- Configurable X username mention.
- Randomised message subjects, openings and closings.
- Configurable available-memory threshold.
- Maximum one webhook trigger per local calendar day.
- Windows DPAPI encryption for webhook credentials.
- CSV memory logging.
- Execution locking to prevent simultaneous instances.
- Dry-run mode.
- No Python, WSL, SMTP server or third-party PowerShell modules required.
How it works
RAM Altman reads Windows physical-memory statistics through CIM.

When available physical memory exceeds the configured threshold, it generates a message and sends an HTTP request to IFTTT Webhooks.

IFTTT receives the event and passes the generated message to its X action.

Windows memory statistics
|
v
RAM Altman.ps1
|
v
RAM threshold
|
v
IFTTT Webhooks
|
v
X / Twitter
|
v
Public X post

Important: RAM Altman only verifies that IFTTT accepted the webhook request. It cannot independently verify that X published the post.
Requirements
- Windows 10 or Windows 11.
- Windows PowerShell 5.1 or PowerShell 7.
- An internet connection.
- An IFTTT account.
- An IFTTT Webhooks connection.
- An X account connected to IFTTT.
Installation
1. Download or clone this repository.
2. Extract the files into a directory.
3. Open PowerShell in that directory.
4. Configure IFTTT using the instructions below.
5. Run the setup wizard.
No administrator privileges are normally required.
IFTTT configuration
RAM Altman uses IFTTT Webhooks to communicate with X.
1. Connect Webhooks
Visit:

https://ifttt.com/maker_webhooks

Connect the Webhooks service to your IFTTT account.
2. Create an Applet
Create a new Applet.

Under If This:
1. Search for Webhooks.
2. Select Receive a web request.
3. Set the event name to:
ram_altman_alert
3. Configure the X action
Under Then That:
1. Search for X (Twitter).
2. Select Post a tweet.
3. Connect your X account if prompted.
4. Set the tweet text to:
{{Value1}}

The Value1 ingredient contains the generated RAM Altman message.

You can also use:
- DIL0 for available RAM percentage.
- DIL1 for total physical RAM.
4. Obtain your webhook URL
Open the Webhooks service documentation:

https://ifttt.com/maker_webhooks

Find your webhook URL.

It should resemble:

https://maker.ifttt.com/trigger/ram_altman_alert/with/key/YOUR_KEY

Keep this URL private.

Anyone with access to your Webhooks key may be able to trigger your IFTTT Applets.
Configuration
Run:

.\ram-altman-IFTTT.ps1 -Setup

The setup wizard asks for:
Setting	Description
Webhook URL	Your complete IFTTT Webhooks URL
X username	Account to mention in generated posts
Threshold	Available RAM percentage that triggers an event

The default mention is:

@sama

The default threshold is:

10%

The threshold measures available physical RAM, not used RAM.

For example, with a threshold of 10%, an event is triggered when more than 10% of physical memory is available.

The webhook URL is encrypted using Windows DPAPI.

The encrypted configuration is tied to the Windows user account that created it.
Usage
Configure
.\ram-altman-IFTTT.ps1 -Setup
Check current memory and configuration
.\ram-altman-IFTTT.ps1 -Status
Preview a generated post
.\ram-altman-IFTTT.ps1 -DryRun

Dry-run mode:
- Reads current memory statistics.
- Generates a randomised post.
- Displays the generated message.
- Does not trigger IFTTT.
- Does not update the daily alert state.
Run normally
.\ram-altman-IFTTT.ps1

The script checks available memory and triggers IFTTT if the threshold is exceeded and no event has already been triggered that day.
Display help
.\ram-altman-IFTTT.ps1 -Help
Daily limit
RAM Altman stores the date of the last successfully accepted IFTTT webhook request.

It will not trigger another event during the same local calendar day.

The state is stored in:

%APPDATA%\RAMAltman\state.json

The daily limit is local to the Windows installation.

Deleting the state file resets the limit. Moving the script to another computer also creates a separate state.

The limit is based on successful HTTP acceptance by IFTTT, not confirmed publication by X.
Memory logging
Every normal execution records a memory sample.

The CSV log is stored at:

%APPDATA%\RAMAltman\memory.csv

Logged fields:
Field	Description
TimestampUtc	UTC timestamp
TotalGiB	Total visible physical RAM
AvailableGiB	Available physical RAM
UsedGiB	Estimated used physical RAM
AvailablePercent	Available RAM percentage
UsedPercent	Used RAM percentage

The CSV file can be opened using Excel, LibreOffice or another spreadsheet application.
Scheduled execution
RAM Altman can be run automatically through Windows Task Scheduler.
1. Open Task Scheduler.
2. Select Create Basic Task.
3. Give it a name such as RAM Altman.
4. Choose a trigger, such as daily.
5. Choose Start a program.
6. Set the program to:
powershell.exe

7. Add these arguments:

-NoProfile -ExecutionPolicy Bypass -File "C:\Path\To\ram-altman-IFTTT.ps1"
8. Set the working directory to the folder containing the script.
9. Finish creating the task.
Choose a sensible interval. The script itself enforces the daily webhook limit.

The scheduled task must run under the same Windows account used during setup because the webhook URL is protected using that account's DPAPI context.
Configuration and data storage
All application data is stored under:

%APPDATA%\RAMAltman\

Files:
File	Purpose
config.json	Encrypted configuration
state.json	Last webhook trigger date
memory.csv	Memory monitoring history
run.lock	Execution lock

The webhook URL is not stored as readable plaintext in config.json.

DPAPI encryption is tied to the current Windows user and machine context.

This does not protect against malware or someone who already controls the logged-in Windows account.
Security
- Webhook URLs are encrypted using Windows DPAPI.
- HTTPS is required for webhook requests.
- The script only accepts IFTTT Webhooks URLs on maker.ifttt.com.
- The webhook URL is not intentionally printed in logs.
- Configuration is stored in the current user's application data directory.
Do not publish your webhook URL, API credentials or configuration files.

If your webhook URL is exposed, regenerate or rotate your IFTTT Webhooks key.
Limitations
- IFTTT must be available for the automation to run.
- The X action requires a working connected X account.
- IFTTT may impose service and account rate limits.
- A successful webhook request does not guarantee that X publishes a post.
- The daily limit is local and can be reset by deleting the state file.
- The script does not monitor GPU memory or virtual memory.
- Memory readings are based on Windows CIM physical-memory statistics.
Troubleshooting
Configuration not found
Run:

.\ram-altman-IFTTT.ps1 -Setup
Invalid webhook URL
Check that the URL:
- Starts with https://.
- Uses maker.ifttt.com.
- Contains the correct event name.
- Includes your complete Webhooks key.
IFTTT accepts the request but no post appears
Check:
- Your IFTTT Applet is enabled.
- Your X account is connected.
- The action is configured as Post a tweet.
- The tweet field contains DIL0.
- Your IFTTT activity history for errors.
No post is generated
Check the available-memory threshold:

.\ram-altman-IFTTT.ps1 -Status

Remember that the configured threshold refers to available RAM.
Another instance is already running
Wait for the other instance to finish.

The script uses an exclusive lock to prevent overlapping executions.
License
This project is distributed under the licence supplied by the original repository.

See the repository's LICENSE file for the applicable terms.
Disclaimer
RAM Altman is an experimental monitoring and automation project.

It is not affiliated with, endorsed by or associated with Sam Altman, OpenAI, IFTTT or X.

Generated posts are published through the user's own connected X account.

Use automation responsibly.
</CodeBlock>