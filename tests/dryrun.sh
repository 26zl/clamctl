#!/bin/bash
# Isolated installation test with stubbed launchctl and stand-in signatures.
set -o pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
CLAMCTL="$HERE/clamctl"
TMP="$(mktemp -d /tmp/clamctl-dry.XXXXXX)" || exit 1
trap 'rm -rf "$TMP"' EXIT

export CLAMCTL_HOME="$TMP/home"
export CLAMCTL_LOG_DIR="$TMP/logs"
export CLAMCTL_LAUNCH_AGENTS="$TMP/agents"
export CLAMCTL_LAUNCHCTL="$TMP/launchctl"
export CLAMCTL_NOTIFY=no
export CLAMCTL_NO_SYMLINK=1
export NO_COLOR=1

mkdir -p "$TMP/db" "$CLAMCTL_HOME"
printf "not a database" > "$TMP/db/main.cvd"; printf "not a database" > "$TMP/db/daily.cvd"
printf 'DATABASE_DIR="%s"\n' "$TMP/db" > "$CLAMCTL_HOME/clamctl.conf"
printf '#!/bin/bash\nexit 0\n' > "$TMP/launchctl"
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

echo "== static"
check "bash 3.2 syntax" /bin/bash -n "$CLAMCTL"
check "help" "$CLAMCTL" help

echo "== install without signatures"
check "install" "$CLAMCTL" install --mode=light
check "no signature download attempted" test ! -s "$CLAMCTL_LOG_DIR/freshclam.log"
check "helper built" test -x "$CLAMCTL_HOME/bin/clamctl-agent"
check "helper stamp" test -s "$CLAMCTL_HOME/bin/clamctl-agent.stamp"
check_fails "helper refuses arbitrary probe output" "$CLAMCTL_HOME/bin/clamctl-agent" probe "$TMP/probe.result"
for j in update scan watch; do
    check "plist $j valid" plutil -lint "$CLAMCTL_LAUNCH_AGENTS/local.clamctl.$j.plist"
done
check "status" "$CLAMCTL" status
check "doctor" "$CLAMCTL" doctor --no-probe
cat > "$TMP/launchctl" <<'EOF'
#!/bin/bash
[ "$1" != print ] || echo 'last exit code = 2'
exit 0
EOF
check_fails "doctor fails when a loaded job failed" "$CLAMCTL" doctor --no-probe
printf '#!/bin/bash\nexit 0\n' > "$TMP/launchctl"
check "pause 2h" "$CLAMCTL" pause 2h
check "resume" "$CLAMCTL" resume
check_fails "pause rejects garbage" "$CLAMCTL" pause 1h30m
check_fails "scan without signatures is refused" "$CLAMCTL" scan "$TMP"
check "scan --stop with nothing running" sh -c "'$CLAMCTL' scan --stop | grep -q 'No scan is running'"

echo "== daemon mode files"
check "mode daemon" "$CLAMCTL" mode daemon
check "clamd plist valid" plutil -lint "$CLAMCTL_LAUNCH_AGENTS/local.clamctl.clamd.plist"
check "clamd.conf has socket" grep -q "^LocalSocket $CLAMCTL_HOME/run/clamd.sock" "$CLAMCTL_HOME/etc/clamd.conf"
check "clamd.conf excludes system volume" grep -q '^ExcludePath \^/System(/|\$)' "$CLAMCTL_HOME/etc/clamd.conf"
check "freshclam.conf notifies clamd" grep -q '^NotifyClamd' "$CLAMCTL_HOME/etc/freshclam.conf"
check "mode light" "$CLAMCTL" mode light
check "clamd plist removed" test ! -f "$CLAMCTL_LAUNCH_AGENTS/local.clamctl.clamd.plist"

echo "== configuration parser"
printf 'MODE=light; echo injected\n' >> "$CLAMCTL_HOME/clamctl.conf"
check_fails "rejects commands in values" "$CLAMCTL" status
sed -i '' '$d' "$CLAMCTL_HOME/clamctl.conf"
printf 'BOGUS=1\n' >> "$CLAMCTL_HOME/clamctl.conf"
check_fails "rejects unknown settings" "$CLAMCTL" status
sed -i '' '$d' "$CLAMCTL_HOME/clamctl.conf"
printf 'WATCH_DIRS=("%s/a b" ~/c)\n' "$TMP" >> "$CLAMCTL_HOME/clamctl.conf"
check "accepts quoted list values" "$CLAMCTL" apply
check "list value with space in plist" grep -q "<string>$TMP/a b</string>" "$CLAMCTL_LAUNCH_AGENTS/local.clamctl.watch.plist"
check "tilde expanded in list" grep -q "<string>$HOME/c</string>" "$CLAMCTL_LAUNCH_AGENTS/local.clamctl.watch.plist"
printf 'CODESIGN_IDENTITY="clamctl-dryrun-no-such-identity"\n' >> "$CLAMCTL_HOME/clamctl.conf"
cp "$CLAMCTL_HOME/bin/clamctl" "$TMP/installed-before"
cp "$CLAMCTL" "$TMP/update-clamctl"
printf '\n' >> "$TMP/update-clamctl"
check_fails "changed script update fails on missing identity" "$TMP/update-clamctl" apply
check "failed update restores installed script" cmp -s "$TMP/installed-before" "$CLAMCTL_HOME/bin/clamctl"
check_fails "missing signing identity fails clearly" "$CLAMCTL" apply
check "helper kept when signing fails" test -x "$CLAMCTL_HOME/bin/clamctl-agent"
sed -i '' '$d' "$CLAMCTL_HOME/clamctl.conf"
check "doctor reports ad-hoc signature" sh -c "'$CLAMCTL' doctor --no-probe | grep -q 'ad-hoc signed'"

echo "== uninstall"
check "uninstall --purge" "$CLAMCTL" uninstall --purge
check "home removed" test ! -d "$CLAMCTL_HOME"

echo ""
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" = 0 ]
