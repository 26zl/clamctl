#!/bin/bash
# Isolated EICAR test with stubbed launchctl; requires downloaded Homebrew signatures.
# --quick skips daemon mode.
set -o pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
CLAMCTL="$HERE/clamctl"
BREW_PREFIX="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
QUICK=""; [ "${1:-}" = "--quick" ] && QUICK=1
Q=".clamctl-quarantined"

# Unix socket paths are limited to 104 bytes, so keep the test root short.
TMP="$(mktemp -d /tmp/clamctl-test.XXXXXX)" || exit 1
CLAMD_PID=""
cleanup() {
    [ -n "$CLAMD_PID" ] && kill "$CLAMD_PID" 2>/dev/null
    [ -f "$TMP/home/run/clamd.pid" ] && kill "$(cat "$TMP/home/run/clamd.pid")" 2>/dev/null
    rm -rf "$TMP"
}
trap cleanup EXIT

export CLAMCTL_HOME="$TMP/home"
export CLAMCTL_LOG_DIR="$TMP/logs"
export CLAMCTL_LAUNCH_AGENTS="$TMP/agents"
export CLAMCTL_LAUNCHCTL="$TMP/launchctl"
export CLAMCTL_NOTIFY=no
export CLAMCTL_NO_SYMLINK=1
export NO_COLOR=1
RUNNER="$CLAMCTL_HOME/bin/clamctl-agent"

cat > "$TMP/launchctl" <<'EOF'
#!/bin/bash
# launchctl stub: records calls, reports every job as loaded.
printf '%s\n' "$*" >> "$(dirname "$0")/launchctl.log"
exit 0
EOF
chmod +x "$TMP/launchctl"

PASS=0; FAIL=0
check() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then PASS=$((PASS + 1)); printf '  ok   %s\n' "$desc"
    else FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$desc"; fi
}
check_fails() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then FAIL=$((FAIL + 1)); printf '  FAIL %s (unexpectedly succeeded)\n' "$desc"
    else PASS=$((PASS + 1)); printf '  ok   %s\n' "$desc"; fi
}
check_exit() {
    local desc="$1" want="$2" rc; shift 2
    "$@" >/dev/null 2>&1; rc=$?
    if [ "$rc" = "$want" ]; then PASS=$((PASS + 1)); printf '  ok   %s\n' "$desc"
    else FAIL=$((FAIL + 1)); printf '  FAIL %s (exit %s, wanted %s)\n' "$desc" "$rc" "$want"; fi
}
check_output() {
    local desc="$1" pat="$2" out; shift 2
    out="$("$@" 2>&1)"
    if printf '%s' "$out" | grep -q -E -- "$pat"; then PASS=$((PASS + 1)); printf '  ok   %s\n' "$desc"
    else FAIL=$((FAIL + 1)); printf '  FAIL %s\n       expected /%s/, got:\n%s\n' "$desc" "$pat" "$(printf '%s' "$out" | sed 's/^/       | /')"; fi
}
eicar() {
    # Standard antivirus test string, split so this file is not flagged itself.
    # shellcheck disable=SC2016
    printf '%s%s' 'X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVI' 'RUS-TEST-FILE!$H+H*' > "$1"
}

echo "Test root: $TMP"
[ -x "$BREW_PREFIX/opt/clamav/bin/clamscan" ] || { echo "ClamAV is not installed (brew install clamav)"; exit 1; }
ls "$BREW_PREFIX/var/lib/clamav"/main.c[lv]d >/dev/null 2>&1 || { echo "No signatures yet; run: clamctl update"; exit 1; }

echo "== static checks"
check "bash 3.2 syntax" /bin/bash -n "$CLAMCTL"
if command -v shellcheck >/dev/null 2>&1; then check "shellcheck" shellcheck -s bash "$CLAMCTL"; fi

echo "== install (light mode)"
check "install" "$CLAMCTL" install --mode=light
check "config written" test -f "$CLAMCTL_HOME/clamctl.conf"
check "helper binary built" test -x "$RUNNER"
check "installed copy" test -x "$CLAMCTL_HOME/bin/clamctl"
check "freshclam.conf generated" grep -q "^DatabaseDirectory $BREW_PREFIX/var/lib/clamav" "$CLAMCTL_HOME/etc/freshclam.conf"
for j in update scan watch; do
    check "plist $j exists" test -f "$CLAMCTL_LAUNCH_AGENTS/local.clamctl.$j.plist"
    check "plist $j valid" plutil -lint "$CLAMCTL_LAUNCH_AGENTS/local.clamctl.$j.plist"
    check "plist $j background QoS" grep -q '<key>ProcessType</key><string>Background</string>' "$CLAMCTL_LAUNCH_AGENTS/local.clamctl.$j.plist"
    check "plist $j runs the helper" grep -q "<string>$RUNNER</string>" "$CLAMCTL_LAUNCH_AGENTS/local.clamctl.$j.plist"
done
check "no clamd job in light mode" test ! -f "$CLAMCTL_LAUNCH_AGENTS/local.clamctl.clamd.plist"
check_output "launchctl bootstrap called for watch job" 'bootstrap gui/[0-9]+ .*local.clamctl.watch.plist' cat "$TMP/launchctl.log"
check_output "status shows light mode" 'mode: light' "$CLAMCTL" status
check_output "doctor runs" 'matches the installed script' "$CLAMCTL" doctor --no-probe

echo "== configuration is data, not code"
cp "$CLAMCTL_HOME/clamctl.conf" "$TMP/conf.bak"
printf 'MODE=light; touch %s/pwned\n' "$TMP" >> "$CLAMCTL_HOME/clamctl.conf"
check_fails "command in a value is rejected" "$CLAMCTL" status
check "nothing was executed" test ! -e "$TMP/pwned"
cp "$TMP/conf.bak" "$CLAMCTL_HOME/clamctl.conf"
# shellcheck disable=SC2016
printf 'NOTIFY=$(touch %s/pwned2)\n' "$TMP" >> "$CLAMCTL_HOME/clamctl.conf"
check_fails "command substitution is rejected" "$CLAMCTL" status
check "nothing was executed either" test ! -e "$TMP/pwned2"
cp "$TMP/conf.bak" "$CLAMCTL_HOME/clamctl.conf"
printf 'NO_SUCH_SETTING=1\n' >> "$CLAMCTL_HOME/clamctl.conf"
check_output "unknown setting is reported" 'unknown setting NO_SUCH_SETTING' "$CLAMCTL" status
cp "$TMP/conf.bak" "$CLAMCTL_HOME/clamctl.conf"
printf 'SCAN_HOUR=25\n' >> "$CLAMCTL_HOME/clamctl.conf"
check_output "out-of-range value is reported" 'SCAN_HOUR must be between' "$CLAMCTL" status
cp "$TMP/conf.bak" "$CLAMCTL_HOME/clamctl.conf"
# shellcheck disable=SC2016
printf 'EXTRA_EXCLUDE_DIRS=(\n  "$HOME/Some Folder"\n  ~/Other\n)\n' >> "$CLAMCTL_HOME/clamctl.conf"
check_output "multi-line list with quotes and tilde" "ExcludePath \\^$HOME/Other" sh -c "'$CLAMCTL' apply >/dev/null && cat '$CLAMCTL_HOME/etc/clamd.conf'"
check "space inside quoted value kept" grep -q "Some\[\[:space:\]\]Folder" "$CLAMCTL_HOME/etc/clamd.conf"
cp "$TMP/conf.bak" "$CLAMCTL_HOME/clamctl.conf"

echo "== watched folder scan (first run scans everything, excluded names skipped)"
mkdir -p "$TMP/watch/node_modules" "$TMP/watch/sub dir"
eicar "$TMP/watch/eicar.com"
eicar "$TMP/watch/node_modules/hidden.com"
eicar "$TMP/watch/sub dir/nested.com"
printf 'hello\n' > "$TMP/watch/clean.txt"
printf '\nWATCH_DIRS=("%s")\nFULL_SCAN_PATHS=("%s")\n' "$TMP/watch" "$TMP/watch" >> "$CLAMCTL_HOME/clamctl.conf"
check "apply after config edit" "$CLAMCTL" apply
check "watch plist lists folder" grep -q "<string>$TMP/watch</string>" "$CLAMCTL_LAUNCH_AGENTS/local.clamctl.watch.plist"
check "scan-new (first run)" "$CLAMCTL" scan-new
check "eicar quarantined in place" test -f "$TMP/watch/eicar.com$Q"
check "original name gone" test ! -e "$TMP/watch/eicar.com"
check "quarantined file unreadable" test ! -r "$TMP/watch/eicar.com$Q"
check "nested eicar quarantined" test -f "$TMP/watch/sub dir/nested.com$Q"
check "excluded node_modules untouched" test -f "$TMP/watch/node_modules/hidden.com"
check "clean file untouched" test -f "$TMP/watch/clean.txt"
check "manifest has two entries" test "$(grep -c . "$CLAMCTL_HOME/quarantine/manifest.tsv")" = 2
check "ledger written" test -s "$CLAMCTL_HOME/state/watch.ledger"
check_output "quarantine list" '(EICAR|Eicar)' "$CLAMCTL" quarantine list
check_output "threats log" 'watch.*(EICAR|Eicar).*quarantined' "$CLAMCTL" threats

echo "== restore, report-only and full-scan defaults"
ID="$(awk -F'\t' '$5 ~ /\/eicar.com$/ { print $1 }' "$CLAMCTL_HOME/quarantine/manifest.tsv")"
check_fails "restore rejects a bad id" "$CLAMCTL" quarantine restore "../../etc"
"$CLAMCTL" scan --report-only --low "$TMP/watch" >/dev/null 2>&1 &
SCAN_PID=$!
i=0; while [ $i -lt 30 ] && [ ! -f "$CLAMCTL_HOME/state/running" ]; do sleep 1; i=$((i + 1)); done
check_output "status shows the running scan" 'Running now: manual scan' "$CLAMCTL" status
check "scan --stop stops it" "$CLAMCTL" scan --stop
wait "$SCAN_PID" 2>/dev/null
check "running marker cleared" test ! -f "$CLAMCTL_HOME/state/running"
check "lock released after stop" "$CLAMCTL" quarantine list
check "restore by id" "$CLAMCTL" quarantine restore "$ID"
check "file is back" test -f "$TMP/watch/eicar.com"
check "file readable again" test -r "$TMP/watch/eicar.com"
"$CLAMCTL" scan --report-only --low "$TMP/watch" > "$TMP/scan.out" 2>&1; RC=$?
check "manual scan exits 1 on detection" test "$RC" = 1
check_output "manual scan summary" '1 threat' cat "$TMP/scan.out"
check_output "manual scan counted files" 'Files scanned +2' cat "$TMP/scan.out"
check "report-only leaves file" test -f "$TMP/watch/eicar.com"
check "quarantined file not rescanned" test "$(grep -c "$Q.*FOUND" "$CLAMCTL_LOG_DIR/scan-manual.log")" = 0
check_output "scan log names engine" 'scan manual started \(clamscan' cat "$CLAMCTL_LOG_DIR/clamctl.log"
check_exit "explicit path overrides name exclusion" 1 "$CLAMCTL" scan --report-only --low "$TMP/watch/node_modules"
check_exit "full scan finds but only reports by default" 1 "$CLAMCTL" scan --full --low
check "full scan left the file in place" test -f "$TMP/watch/eicar.com"
check_output "full scan recorded as reported" 'full.*reported' "$CLAMCTL" threats
check "manual quarantine add" "$CLAMCTL" quarantine add "$TMP/watch/eicar.com"
check "manually quarantined in place" test -f "$TMP/watch/eicar.com$Q"

echo "== incremental watch scan"
eicar "$TMP/watch/later.com"
check "scan-new (incremental)" "$CLAMCTL" scan-new
check_output "only new files scanned" 'watch: 1 new file' cat "$CLAMCTL_LOG_DIR/clamctl.log"
check "new file quarantined" test -f "$TMP/watch/later.com$Q"

echo "== helper binary boundaries"
check_exit "helper refuses other subcommands" 64 "$RUNNER" quarantine list
check_exit "helper refuses arbitrary probe output" 64 "$RUNNER" probe "$TMP/probe.result"
check_exit "helper runs an allowed subcommand" 0 "$RUNNER" scan-new
eicar "$TMP/watch/env.com"
check "helper ignores hostile environment" env CLAMCTL_HOME=/nonexistent PATH=/nonexistent BASH_ENV="$TMP/nope" "$RUNNER" scan-new
check "file scanned through helper" test -f "$TMP/watch/env.com$Q"
printf '# tampered\n' >> "$CLAMCTL_HOME/bin/clamctl"
check_exit "helper refuses a modified script" 78 "$RUNNER" scan-new
check_output "doctor notices the mismatch" 'out of date' "$CLAMCTL" doctor --no-probe
check "apply rebuilds the helper" "$CLAMCTL" apply
check_exit "helper accepts the reinstalled script" 0 "$RUNNER" scan-new

echo "== pause / resume"
check "pause" "$CLAMCTL" pause 5
eicar "$TMP/watch/paused.com"
check "scan-new while paused" "$CLAMCTL" scan-new
check "nothing scanned while paused" test -f "$TMP/watch/paused.com"
check "resume" "$CLAMCTL" resume
check "scan-new after resume" "$CLAMCTL" scan-new
check "file scanned after resume" test -f "$TMP/watch/paused.com$Q"

if [ -z "$QUICK" ]; then
    echo "== daemon mode (clamd started directly because launchctl is stubbed)"
    check "switch to daemon mode" "$CLAMCTL" mode daemon
    check "clamd.conf generated" test -f "$CLAMCTL_HOME/etc/clamd.conf"
    check "clamd plist valid" plutil -lint "$CLAMCTL_LAUNCH_AGENTS/local.clamctl.clamd.plist"
    check "freshclam notifies clamd" grep -q '^NotifyClamd' "$CLAMCTL_HOME/etc/freshclam.conf"
    check "exclusions in clamd.conf" grep -q '^ExcludePath /node_modules(/|\$)' "$CLAMCTL_HOME/etc/clamd.conf"
    "$BREW_PREFIX/opt/clamav/sbin/clamd" --foreground --config-file="$CLAMCTL_HOME/etc/clamd.conf" > "$TMP/clamd.out" 2>&1 &
    CLAMD_PID=$!
    i=0
    while [ $i -lt 90 ] && ! "$BREW_PREFIX/opt/clamav/bin/clamdscan" --config-file="$CLAMCTL_HOME/etc/clamd.conf" --ping 1 >/dev/null 2>&1; do sleep 1; i=$((i + 1)); done
    check "clamd answers ping" "$BREW_PREFIX/opt/clamav/bin/clamdscan" --config-file="$CLAMCTL_HOME/etc/clamd.conf" --ping 1
    check_output "status shows clamd running" 'clamd +running' "$CLAMCTL" status
    "$CLAMCTL" quarantine restore "$(awk -F'\t' '$5 ~ /\/later.com$/ { print $1 }' "$CLAMCTL_HOME/quarantine/manifest.tsv")" >/dev/null 2>&1
    "$CLAMCTL" scan --report-only "$TMP/watch" > "$TMP/scan2.out" 2>&1; RC=$?
    check "daemon scan exits 1 on detection" test "$RC" = 1
    check_output "daemon scan used clamdscan" 'scan manual started \(clamdscan' cat "$CLAMCTL_LOG_DIR/clamctl.log"
    check_output "daemon scan found eicar" 'later.com: .*(EICAR|Eicar).* FOUND' cat "$CLAMCTL_LOG_DIR/scan-manual.log"
    check "daemon scan honoured exclusions" test "$(grep -c 'node_modules/hidden.com' "$CLAMCTL_LOG_DIR/scan-manual.log")" = 0
    check "daemon scan skipped quarantined files" test "$(grep -c "$Q.*FOUND" "$CLAMCTL_LOG_DIR/scan-manual.log")" = 0
    check_exit "daemon explicit path overrides exclusion" 1 "$CLAMCTL" scan --report-only "$TMP/watch/node_modules"
    eicar "$TMP/watch/daemon-new.com"
    check "scan-new in daemon mode" "$CLAMCTL" scan-new
    check "daemon watch quarantined new file" test -f "$TMP/watch/daemon-new.com$Q"
    kill "$CLAMD_PID" 2>/dev/null; wait "$CLAMD_PID" 2>/dev/null; CLAMD_PID=""
    check "switch back to light mode" "$CLAMCTL" mode light
    check "clamd plist removed" test ! -f "$CLAMCTL_LAUNCH_AGENTS/local.clamctl.clamd.plist"
fi

echo "== uninstall"
check_fails "uninstall --purge refuses nonempty quarantine" "$CLAMCTL" uninstall --purge
check "home kept after refused purge" test -d "$CLAMCTL_HOME"
check "quarantine purge deletes files" "$CLAMCTL" quarantine purge
check "purged file gone" test ! -e "$TMP/watch/eicar.com$Q"
check "uninstall --purge" "$CLAMCTL" uninstall --purge
check "home removed" test ! -d "$CLAMCTL_HOME"
check "plists removed" test -z "$(ls "$CLAMCTL_LAUNCH_AGENTS" 2>/dev/null)"

echo ""
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" = 0 ]
