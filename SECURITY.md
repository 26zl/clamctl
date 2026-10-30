# Security policy

clamctl runs ClamAV as your user through launchd and gives a compiled helper
the folder and Full Disk Access grants that macOS ties to the job's first
executable. Bugs in that boundary matter more than usual, so please report
them privately.

## What to report here

- Anything that lets other software use the helper's grants: running code
  other than the verified installed script through `clamctl-agent`, getting
  past its SHA-256 check or its fixed list of subcommands, or feeding it an
  environment it should have dropped.
- A configuration file that executes code. `~/.clamctl/clamctl.conf` is
  parsed as data; a value that runs a command is a vulnerability.
- Quarantine, restore, delete or purge touching a file other than the one
  recorded (symlinks, path tricks, races), or purge deleting outside
  `~/.clamctl`.
- Generated launchd plists or ClamAV configs that can be influenced by file
  names or settings in a way that changes what runs.
- A secret or personal data committed to the repository.

Not handled here: bugs in ClamAV itself (report those to the
[ClamAV project](https://github.com/Cisco-Talos/clamav/security)), missed
detections and false positives (signature quality), and the limit the README
already states that Homebrew's directories are writable by your user.

## How to report

Use GitHub private vulnerability reporting:
[open a draft security advisory](https://github.com/26zl/clamctl/security/advisories/new).
Do not open a public issue for something exploitable; ordinary bugs go in a
normal [issue](https://github.com/26zl/clamctl/issues).

Please include the macOS version and architecture, the ClamAV version
(`brew list --versions clamav`), the mode (`clamctl status`), the commit of
clamctl you ran, and steps to reproduce. Use synthetic files such as EICAR,
and leave real quarantine records, scan logs and personal paths out of the
report.

## Supported versions

There are no tagged releases; the current `main` is the supported version.
The version string in the script (`clamctl --version`) only identifies the
code. Update with `git pull && ./clamctl apply`, and update the engine with
`brew upgrade clamav`.

## What to expect

One person maintains this in their spare time, so there is no guaranteed
response time; reports are read and answered as soon as possible. Fixes land
on `main` with a regression test where one is possible, and the advisory is
published afterwards, crediting you if you want.
