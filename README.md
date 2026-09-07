# clamctl

[![CI](https://github.com/26zl/clamctl/actions/workflows/ci.yml/badge.svg)](https://github.com/26zl/clamctl/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-lightgrey.svg)](#requirements)
[![Apple Silicon and Intel](https://img.shields.io/badge/arch-Apple%20Silicon%20%7C%20Intel-lightgrey.svg)](#requirements)
[![No root required](https://img.shields.io/badge/root-not%20required-success.svg)](#how-it-works)
[![ClamAV 1.5.x via Homebrew](https://img.shields.io/badge/ClamAV-1.5.x%20via%20Homebrew-orange.svg)](https://www.clamav.net/)

ClamAV on macOS from one command, without slowing your Mac down.

```text
./clamctl install        # Homebrew ClamAV, signatures, background jobs
clamctl status           # what runs, signature age, last scans
clamctl scan ~/Downloads
```

One bash script plus a small C helper it compiles on install. Everything runs
as your user through launchd at background priority; no `sudo`, no daemon
unless you ask for one, and `clamctl uninstall` removes it again.

## What it does

- Updates signatures every 4 hours.
- Scans new files in `~/Downloads` shortly after they finish downloading and
  quarantines infected ones.
- Runs a daily quick scan (Downloads, Desktop, Documents, `~/Applications`,
  LaunchAgents, `/tmp`) and a weekly full scan, skipped on battery. A scan the
  Mac was powered off for is caught up later that day.
- Quarantines in place (renamed, made unreadable) with `restore`, keeps a
  threat log and sends macOS notifications.
- `clamctl doctor` checks jobs, signatures and folder permissions;
  `clamctl pause 2h` mutes scans while you render or game.

Background jobs use launchd's `ProcessType Background`: efficiency cores only
on Apple Silicon, and I/O that yields to whatever you are doing. In the default
light mode nothing stays resident; each scan loads the signatures (about 20 s
in the background, 4 s from the Terminal), scans, and frees the ~1.3 GB again.
Daemon mode (`clamctl mode daemon`) keeps `clamd` loaded (~1.5 GB) so new
downloads are checked within seconds. Detection itself is not reduced: full
signature set, archives unpacked, heuristics on.

## Install

```text
git clone https://github.com/26zl/clamctl.git
cd clamctl
./clamctl install              # or: ./clamctl install --mode=daemon
```

Install copies the script to `~/.clamctl/bin`, builds the helper, writes
`~/.clamctl/clamctl.conf`, downloads the signatures (about 300 MB the first
time), loads the launchd jobs and runs `clamctl doctor`. The `clamctl` command
is linked into Homebrew's `bin`.

Two dialogs to expect: macOS asks whether `clamctl-agent` may access your
Downloads folder (allow it), and notifications come from "Script Editor", so
allow those under System Settings › Notifications if you want them.

**Full Disk Access** is optional. Without it, full scans skip Mail, Safari,
Messages and Time Machine data; `clamctl fda` opens the right settings pane
and shows the helper to add.

**Updating**: `git pull && ./clamctl apply`. The helper is rebuilt when the
script changes, and macOS then asks for folder access again and drops a Full
Disk Access grant, because the grant is tied to the binary's hash. To keep
grants across updates, create a self-signed "Code Signing" certificate named
`clamctl` in Keychain Access (Certificate Assistant › Create a Certificate),
set `CODESIGN_IDENTITY="clamctl"` in the config and run `clamctl apply`.
Update ClamAV itself with `brew upgrade clamav`.

## Commands

```text
clamctl install [--mode=light|daemon]   install ClamAV, config and background jobs
clamctl status                          what is running, signature age, last scans
clamctl doctor                          check jobs, signatures and folder permissions
clamctl scan PATH...                    scan now (--low hides it fully)
clamctl scan --quick | --full           run the daily or full scan now
clamctl scan --full --background        run it through the low-priority job instead
clamctl scan --stop                     abort the scan that is running
clamctl update                          fetch signatures now
clamctl threats [N]                     recent detections and what was done
clamctl quarantine [list|add FILE|restore ID|delete ID|purge]
clamctl pause [MINUTES|2h] | resume     pause scheduled and watched-folder scans
clamctl mode [light|daemon]             show or switch engine mode
clamctl start | stop | restart          control clamd (daemon mode)
clamctl log [clamctl|freshclam|clamd|scan] [-f]
clamctl fda                             help granting Full Disk Access to the helper
clamctl config [edit|path]              show or edit configuration, then apply
clamctl apply                           re-generate configs and reload jobs after edits
clamctl uninstall [--purge]             remove jobs (and optionally data)
```

Scan options: `--report-only`, `--quarantine`, `--low`, `--normal`,
`--background`, `--stop`.

## Configuration

`~/.clamctl/clamctl.conf` is a commented list of `KEY=value` and
`KEY=(list "with spaces")` lines; run `clamctl apply` after editing. It is
read as data, never executed, and unknown or out-of-range settings are
rejected. The settings most people touch:

| Setting | Default | Meaning |
| --- | --- | --- |
| `MODE` | `light` | `light` or `daemon` |
| `WATCH_DIRS` | `~/Downloads` | folders scanned shortly after new files appear |
| `ACTION` | `quarantine` | what watched-folder, quick and manual scans do with detections |
| `FULL_SCAN_ACTION` | `report` | full scans only report by default (false positives are likelier deep in apps and mail stores) |
| `SCAN_HOUR`, `SCAN_MINUTE` | 12:30 | daily scan time |
| `FULL_SCAN_EVERY_DAYS` | 7 | full scan interval |
| `QUICK_SCAN_PATHS`, `FULL_SCAN_PATHS` | see file | what the scans cover |
| `EXCLUDE_DIRS`, `EXCLUDE_NAMES` | see file | never scanned; add your own to `EXTRA_EXCLUDE_*` |
| `MAX_FILESIZE`, `MAX_SCANSIZE` | 400M, 1000M | ClamAV size limits |
| `NOTIFY`, `NOTIFY_CLEAN` | yes, no | notifications on detections / also on clean scans |
| `CODESIGN_IDENTITY` | empty | keychain certificate that signs the helper |

Files live in `~/.clamctl` (config, generated ClamAV configs, helper,
quarantine records, state) and `~/Library/Logs/clamctl`. Signatures stay in
Homebrew's `var/lib/clamav`.

## How it works

**Scheduling.** One daily launchd job runs the quick scan, or the full scan
when it is due and the Mac is on mains power. If the Mac was asleep, launchd
runs the job on wake; if it was powered off, the watched-folder job, which also
wakes every five minutes, starts the daily scan once 25 hours have passed.

**Watched folders.** launchd's `WatchPaths` starts the job when a watched
folder changes. It skips partial downloads and cloud placeholders, scans only
files it has not seen before, and lists the folder again after each scan so a
download that finished meanwhile is not missed.

**Quarantine.** A detected file is renamed with a `.clamctl-quarantined`
suffix, made unreadable and recorded with its original path and permissions;
later scans skip it and `restore` puts it back. Files are never moved to a
vault, so a job holding Full Disk Access never copies protected data
elsewhere. Heuristic and PUA detections are reported, not quarantined.

**Permissions.** macOS attributes a launchd job's file access to its first
executable, which for a shell script would be `/bin/bash`. The compiled
helper `clamctl-agent` is the job's executable instead. It only runs the
installed script after verifying its SHA-256, accepts a fixed set of
subcommands, starts bash with a clean environment, and turns off download of
dataless cloud files, so its grants cannot be borrowed by other software. The
remaining limit is inherent to Homebrew: its directories are writable by your
user, so software running as you could still influence what gets scanned.

**Engines.** Light mode runs `clamscan` per scan. Daemon mode runs `clamd` as
a launchd agent and `clamdscan --fdpass --multiscan`, which applies the same
exclusions client-side; if `clamd` does not answer, scans fall back to
`clamscan`.

The SIP exclusion list and the `--fdpass --multiscan` combination come from
[essandess/macOS-clamAV](https://github.com/essandess/macOS-clamAV).

## Requirements

- macOS 13 or later (what Homebrew supports), Apple Silicon or Intel.
- [Homebrew](https://brew.sh) and the Xcode Command Line Tools (Homebrew
  installs them).
- Tested end to end on macOS 26 (Apple Silicon). CI runs the offline test
  suites on macOS 26, macOS 15 and macOS 15 Intel runners. On Intel the
  background priority still keeps scans out of the way, but there are no
  efficiency cores to confine them to.

## Testing

`tests/dryrun.sh` and `tests/regression.sh` need only the ClamAV binaries and
run in CI. `tests/smoke.sh` plants EICAR files and exercises watched-folder
scans, quarantine, the helper's checks and daemon mode; it needs downloaded
signatures and runs in an isolated home with a stubbed `launchctl`.

## Uninstall

```text
clamctl uninstall          # removes the launchd jobs, keeps config and records
clamctl uninstall --purge  # removes ~/.clamctl and the logs as well
brew uninstall clamav      # if you no longer want ClamAV
```

## License

MIT, see [LICENSE](LICENSE). ClamAV is a separate GPL-2 program that clamctl
runs; nothing from it is bundled here.
