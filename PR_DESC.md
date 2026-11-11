# Add native Windows support

## Summary

Adds a native Windows PowerShell implementation of RAM Altman, alongside a batch launcher and Windows-specific documentation.

## Changes

- Adds `ram-altman.ps1` for Windows physical-memory monitoring.
- Adds `ram-altman.bat` as a convenient launcher.
- Supports Resend and Brevo email APIs.
- Adds an interactive setup wizard and configurable available-memory threshold.
- Protects the API key using Windows DPAPI for the current user.
- Logs memory samples to CSV.
- Prevents overlapping runs with an exclusive lock.
- Limits recorded successful alerts to one per local calendar day.
- Adds status and dry-run modes.
- Documents Task Scheduler configuration and troubleshooting.

## Compatibility

- Windows 10 and Windows 11
- Windows PowerShell 5.1 and PowerShell 7+

## Testing

This is a proposed port and should be tested on supported Windows versions before merging. Provider delivery also depends on valid API credentials and a verified sender address/domain.

## Notes for maintainers

The contribution is kept in separate Windows-specific files to minimise disruption to the existing implementation. Please adjust filenames or directory placement to match the upstream project's conventions.
