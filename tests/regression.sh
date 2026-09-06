#!/bin/bash
# Failure paths run with synthetic files and no launchd jobs or downloads.
# shellcheck disable=SC2034,SC2317,SC2329
set -o pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d /tmp/clamctl-regression.XXXXXX)" || exit 1
trap 'rm -rf "$TMP"' EXIT
export CLAMCTL_HOME="$TMP/home" CLAMCTL_LOG_DIR="$TMP/logs"
export CLAMCTL_LAUNCH_AGENTS="$TMP/agents" CLAMCTL_LAUNCHCTL=/usr/bin/false
export CLAMCTL_NOTIFY=no CLAMCTL_NO_SYMLINK=1 NO_COLOR=1
sed '$d' "$HERE/clamctl" > "$TMP/functions.sh"
# shellcheck source=/dev/null
source "$TMP/functions.sh"
ensure_dirs
default_config > "$CONF_FILE"
load_config

PASS=0; FAIL=0
check() {
    local desc="$1"; shift
    ensure_dirs
    default_config > "$CONF_FILE"
    : > "$MANIFEST"
    rm -f "$LEDGER" "$STATE_DIR/pause"
    if ( "$@" ) > "$TMP/result" 2>&1; then
        PASS=$((PASS + 1)); printf '  ok   %s\n' "$desc"
    else
        FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$desc"; cat "$TMP/result"
    fi
}
rejects() { ! ( "$@" ) >/dev/null 2>&1; }

decimal_config() {
    SCAN_MINUTE=08; UPDATE_INTERVAL_HOURS=08
    validate_config && [ "$SCAN_MINUTE" = 8 ] && [ "$UPDATE_INTERVAL_HOURS" = 8 ]
}
bad_size() { MAX_FILESIZE=4MM; rejects validate_config; }
bad_category() { PUA_CATEGORIES=('Osx bad'); rejects validate_config; }
quoted_parentheses() {
    parse_config_stream test <<'EOF'
WATCH_DIRS=("/tmp/folder (draft" "/tmp/other")
MODE=daemon
EOF
    [ "${WATCH_DIRS[0]}" = '/tmp/folder (draft' ] && [ "$MODE" = daemon ]
}
private_logs() { [ "$(stat -f %Lp "$LOG_DIR")" = 700 ]; }
load_failure() { rejects agent_load scan; }
apply_failure() {
    build_runner() { :; }; install_script_copy() { :; }
    rejects cmd_apply
}
purge_keeps_records() {
    printf 'synthetic quarantine record\n' > "$MANIFEST"
    rejects cmd_uninstall --purge && test -s "$MANIFEST"
}
pause_decimal() { cmd_pause 08 && [ "$(paused_until)" -gt "$(now)" ]; }
pause_rejects_overflow() { rejects cmd_pause 999999999999999999999999h; }
pause_rejects_missing_number() { rejects cmd_pause h; }
unsafe_purge() {
    rejects validate_purge_dir "$TMP/.." && rejects validate_purge_dir / && rejects validate_purge_dir "$HOME"
}
chmod_failure() {
    printf 'synthetic\n' > "$TMP/chmod-file"
    chmod() { return 1; }
    rejects quarantine_file "$TMP/chmod-file" manual && test -f "$TMP/chmod-file" && test ! -s "$MANIFEST"
}
manifest_failure() {
    printf 'synthetic\n' > "$TMP/manifest-file"
    MANIFEST="$TMP"
    rejects quarantine_file "$TMP/manifest-file" manual && test -r "$TMP/manifest-file"
}
failed_delete_keeps_record() {
    local id=20260907-010203-abcd target="$TMP/blocked$QUARANTINE_SUFFIX"
    mkdir "$target"
    printf '%s\ttime\tmanual\t600\t%s\t%s\n' "$id" "$TMP/blocked" "$target" > "$MANIFEST"
    rejects cmd_quarantine delete "$id" && test -s "$MANIFEST" &&
        rejects cmd_quarantine purge && test -s "$MANIFEST"
}
restore_dangling_symlink() {
    local id
    printf 'synthetic\n' > "$TMP/restore-file"
    id="$(quarantine_file "$TMP/restore-file" manual)" || return 1
    ln -s "$TMP/missing" "$TMP/restore-file"
    rejects cmd_quarantine restore "$id" && test -L "$TMP/restore-file" && test -s "$MANIFEST"
}
tab_path() {
    local path="$TMP/tab"$'\t'"file"
    printf 'synthetic\n' > "$path"
    rejects quarantine_file "$path" manual && test -f "$path"
}
quarantine_collision() {
    local id
    printf 'synthetic\n' > "$TMP/collision-file"
    manifest_line() {
        if [ ! -f "$TMP/first-id" ]; then
            printf '%s' "$1" > "$TMP/first-id"
            printf 'occupied\n'
        fi
    }
    id="$(quarantine_file "$TMP/collision-file" manual)" || return 1
    [ "$id" != "$(cat "$TMP/first-id")" ] && grep -q "^$id" "$MANIFEST"
}

check 'configuration accepts decimal leading zeroes' decimal_config
check 'configuration rejects malformed size units' bad_size
check 'configuration rejects invalid PUA categories' bad_category
check 'quoted parentheses do not corrupt list parsing' quoted_parentheses
check 'scan logs are private to the user' private_logs
check 'launchd load failure is propagated' load_failure
check 'apply fails when jobs cannot load' apply_failure
check 'uninstall purge preserves outstanding quarantine records' purge_keeps_records
check 'pause accepts decimal leading zeroes' pause_decimal
check 'pause rejects arithmetic overflow' pause_rejects_overflow
check 'pause requires a number before its unit' pause_rejects_missing_number
check 'purge refuses unsafe directories before deletion' unsafe_purge
check 'quarantine rolls back on chmod failure' chmod_failure
check 'quarantine rolls back on manifest failure' manifest_failure
check 'failed delete and purge keep recovery records' failed_delete_keeps_record
check 'restore never overwrites a dangling symlink' restore_dangling_symlink
check 'quarantine rejects unrepresentable paths' tab_path
check 'quarantine retries an occupied record identifier' quarantine_collision

verified_snapshot() {
    local pid i rc
    {
        printf 'printf ready > "%s/ready"\n/bin/sleep 1\n' "$TMP"
        printf '%131072s\n' ''
        printf 'printf verified > "%s/snapshot-result"\n' "$TMP"
    } > "$INSTALLED_SCRIPT"
    build_runner || return 1
    "$RUNNER" scan &
    pid=$!
    for ((i=0; i<100; i++)); do
        [ -f "$TMP/ready" ] && break
        /bin/sleep 0.05
    done
    printf 'exit 99\n' > "$INSTALLED_SCRIPT"
    wait "$pid"; rc=$?
    [ "$rc" = 0 ] && [ "$(cat "$TMP/snapshot-result")" = verified ] && rejects "$RUNNER" scan
}
check 'helper executes verified bytes despite concurrent script edits' verified_snapshot

export FAKE_ARGS="$TMP/scanner.args" FAKE_OUTPUT="$TMP/scanner.out" FAKE_EXIT=0
cat > "$TMP/scanner" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$FAKE_ARGS"
cat "$FAKE_OUTPUT"
exit "$FAKE_EXIT"
EOF
chmod +x "$TMP/scanner"
CLAMSCAN="$TMP/scanner"
PRIORITY=normal
priority_prefix() { PRI_CMD=(); }
ensure_runner_context() { :; }
db_present() { return 0; }
sleep() { :; }

scan_failure() {
    local rc
    printf 'SCAN SUMMARY\nKnown viruses: 1\n' > "$FAKE_OUTPUT"
    FAKE_EXIT=2
    scan_paths manual report "$TMP"; rc=$?
    [ "$rc" = 2 ] && [ "$(state_get last_manual status)" = failed ]
}
partial_detection() {
    local rc
    printf '%s: Synthetic.Signature FOUND\nSCAN SUMMARY\n' "$TMP/synthetic" > "$FAKE_OUTPUT"
    FAKE_EXIT=2
    scan_paths manual report "$TMP"; rc=$?
    [ "$rc" = 2 ] && [ "$SCAN_RESULT_THREATS" = 1 ] && [ "$(state_get last_manual status)" = failed ]
}
scan_log_failure() {
    local rc
    rm -f "$LOG_DIR/scan-manual.log"
    mkdir "$LOG_DIR/scan-manual.log"
    scan_paths manual report "$TMP"; rc=$?
    rmdir "$LOG_DIR/scan-manual.log"
    [ "$rc" = 2 ]
}
spaced_root() {
    local root="$TMP/space root"
    EXTRA_EXCLUDE_DIRS=("$root")
    printf 'SCAN SUMMARY\nKnown viruses: 1\n' > "$FAKE_OUTPUT"
    FAKE_EXIT=0
    scan_paths manual report "$root/sub" &&
        ! grep -F -- '--exclude-dir=^'"$TMP/space" "$FAKE_ARGS" && grep -Fx "$root/sub" "$FAKE_ARGS"
}
background_override() {
    rejects cmd_scan --quick --background --report-only && test ! -e "$STATE_DIR/force_quick"
}
forced_quick() {
    QUICK_SCAN_PATHS=("$TMP")
    : > "$STATE_DIR/force_quick"
    printf 'SCAN SUMMARY\nKnown viruses: 1\n' > "$FAKE_OUTPUT"
    cmd_scan --auto && test ! -e "$STATE_DIR/force_quick" && [ "$(state_get last_quick status)" = clean ]
}
watch_filtering() {
    local root="$TMP/watch" rc
    WATCH_DIRS=("$root")
    FIND_DATALESS=()
    mkdir -p "$root/node_modules" "$root/sub dir" "$root/ongoing.download"
    printf 'clean\n' > "$root/sub dir/settled"
    printf 'partial\n' > "$root/unfinished.part"
    printf 'excluded\n' > "$root/node_modules/hidden"
    printf 'download\n' > "$root/ongoing.download/payload"
    touch -t 202601010000 "$root/sub dir/settled" "$root/unfinished.part" "$root/node_modules/hidden" "$root/ongoing.download/payload"
    printf 'SCAN SUMMARY\nKnown viruses: 1\n' > "$FAKE_OUTPUT"
    cmd_scan_new || { cat "$LOG_DIR/scan-watch.log"; return 1; }
    grep -F -- '--file-list=' "$FAKE_ARGS" && grep -F '/sub dir/settled' "$LEDGER" || return 1
    if grep -E 'unfinished|node_modules|ongoing' "$LEDGER"; then return 1; fi
    printf 'new\n' > "$root/sub dir/new"
    touch -t 202601010000 "$root/sub dir/new"
    FAKE_EXIT=2
    cmd_scan_new; rc=$?
    [ "$rc" = 2 ] && ! grep -F '/sub dir/new' "$LEDGER" || return 1
    FAKE_EXIT=0
    cmd_scan_new && grep -F '/sub dir/new' "$LEDGER"
}
watch_control_path() {
    local root="$TMP/control"$'\n'"directory"
    mkdir -p "$root"; printf 'synthetic\n' > "$root/file"
    WATCH_DIRS=("$root"); FIND_DATALESS=()
    rejects watch_candidates
}
shared_lock() {
    /bin/bash -c 'sleep 10' &
    local pid=$! rc
    mkdir -p "$RUN_DIR/scan.lock"
    printf '%s\n' "$pid" > "$RUN_DIR/scan.lock/pid"
    rejects acquire_lock && cmd_scan_new && test ! -f "$LEDGER"; rc=$?
    kill "$pid"; wait "$pid" 2>/dev/null
    rm -f "$RUN_DIR/scan.lock/pid"
    return "$rc"
}
check 'scanner exit 2 is never reported clean' scan_failure
check 'partial detections retain failed status and exit 2' partial_detection
check 'scan log write failure cannot report success' scan_log_failure
check 'explicit roots retain spaces when applying exclusions' spaced_root
check 'background report-only is rejected before scheduling' background_override
check 'forced quick request survives automatic scan selection' forced_quick
check 'watch filters first scan and retries failed incremental scan' watch_filtering
check 'watch rejects control characters in parent directories' watch_control_path
check 'watch and manual scans respect the same live lock' shared_lock

printf '\npassed: %s  failed: %s\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
