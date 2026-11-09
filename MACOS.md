# macOS support

`ram-altman.sh` supports macOS and Linux. On macOS it reads physical memory
from `sysctl` and virtual-memory statistics from `vm_stat`.

Install the script somewhere on your `PATH`, configure the same
`RAM_ALTMAN_TO`, `RAM_ALTMAN_FROM`, and optional threshold/state variables used
on Linux, then schedule it with `launchd` or cron. For example:

```sh
RAM_ALTMAN_TO=you@example.com \
RAM_ALTMAN_FROM=mac@example.com \
./ram-altman.sh --status
```

macOS does not provide Linux's `flock` or `shuf`, so the script uses an atomic
lock directory and a POSIX `awk` shuffle fallback on that platform.
