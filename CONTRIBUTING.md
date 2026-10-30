# Contributing

Bug reports, fixes and documentation improvements are welcome. This page
covers what you need, which checks a change must pass and how to try a change
without disturbing a real installation.

## What you need

- macOS 13 or later with [Homebrew](https://brew.sh), ClamAV
  (`brew install clamav`) and the Xcode Command Line Tools, which provide
  the `cc` that builds the helper.
- [ShellCheck](https://www.shellcheck.net) (`brew install shellcheck`).

Everything is in one script, `clamctl`, including the C source of the helper
(`runner_source`), which is compiled on `install` and rebuilt by `apply`
whenever the script changes. The tests live in `tests/`.

## Constraints

- The script runs under macOS `/bin/bash` 3.2. No associative arrays,
  `mapfile`, `${var,,}`, `declare -g` or other bash 4 features;
  `/bin/bash -n clamctl` is part of the tests.
- Configuration is data. `parse_config_stream` reads
  `~/.clamctl/clamctl.conf` without evaluating it. A new setting needs an
  entry in `default_config`, in `CONFIG_SCALARS` or `CONFIG_ARRAYS`, and a
  check in `validate_config`.
- Nothing runs as root, and the helper only accepts its fixed list of
  subcommands. Keep it that way; see [SECURITY.md](SECURITY.md) for why.
- Four-space indentation, as in the existing code and `.editorconfig`.
  shfmt is not used.

## Checks

CI (`.github/workflows/ci.yml`) runs these on every pull request and on
pushes to `main`; run the same locally before opening a pull request:

```text
shellcheck -s bash clamctl tests/*.sh
tests/dryrun.sh
tests/regression.sh
```

CI runs the two test scripts on `macos-26`, `macos-15` and `macos-15-intel`
runners after `brew install clamav`; ShellCheck runs on Ubuntu.

- `tests/dryrun.sh` installs into a throwaway home with stand-in signature
  files: install, helper build, plist generation, status, doctor, pause,
  daemon-mode files, the configuration parser, failed updates and uninstall.
- `tests/regression.sh` sources the script's functions and exercises failure
  paths with a fake scanner: validation, quarantine rollback, locks,
  watched-folder filtering and the helper's verification of the script.
- `tests/smoke.sh` is the end-to-end check and does not run in CI. It needs
  downloaded signatures, plants EICAR test files, runs real scans and,
  unless called with `--quick`, starts a real `clamd` on a socket inside the
  test root. Run it when you change scanning, quarantine or daemon mode.

## Testing without touching your installation

All three test scripts run against an isolated home under `/tmp`: they set
`CLAMCTL_HOME`, `CLAMCTL_LOG_DIR` and `CLAMCTL_LAUNCH_AGENTS` to temporary
directories, point `CLAMCTL_LAUNCHCTL` at a stub, set `CLAMCTL_NO_SYMLINK=1`
so nothing is linked into Homebrew's `bin`, and `CLAMCTL_NOTIFY=no`. They
never load launchd jobs or read `~/.clamctl`, and they remove the test root
when they finish. The same variables let you run the script by hand against a
scratch home.

To try a change against your real installation, run `./clamctl apply` from
the clone: it installs the working copy to `~/.clamctl/bin`, rebuilds the
helper and reloads the jobs. macOS then asks for folder access again, and a
Full Disk Access grant has to be renewed unless you sign the helper (see the
README). To go back, check out `main` and run `./clamctl apply` again.

## Pull requests

- Branch from `main`, one topic per pull request.
- Add a check to `tests/dryrun.sh` or `tests/regression.sh` for the
  behaviour you change; put failure paths in `regression.sh`.
- Say which macOS version and architecture you tested on and whether you ran
  `tests/smoke.sh`.
- Commit subjects are imperative and say what changed; use the body for why.
  There is no prefix convention.
- CI must be green on all runners. The maintainer reviews and merges. There
  is no release process: `main` is what `git pull && ./clamctl apply`
  installs.

Dependabot keeps the pinned GitHub Actions current. Security problems go
through [SECURITY.md](SECURITY.md), not the issue tracker.
