#!/usr/bin/env bash
# tests/test-release-check.sh — offline tests for scripts/release-check.sh.
#
# These drive the step logic with stub commands (RELEASE_CHECK_GATE,
# RELEASE_CHECK_VM_STATUS, RELEASE_CHECK_BOOT, ...) so no VM is needed and the
# real gate is never run twice. What they pin down:
#   * the gate step passes only on rc 0 AND output ending in "All checks passed.";
#   * vm-status refuses a VM that is already running, because the release check
#     stops the VM it booted;
#   * a SKIP of a step that applies is a failure, unless --allow-skip;
#   * --offline runs the gate step only and exits 0 when the gate passes.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
check="$root/scripts/release-check.sh"
failures=0
out=""
rc=0

run() {
    rc=0
    out="$("$@" 2>&1)" || rc=$?
}

expect_rc() {
    local desc="$1" want="$2"
    if [ "$rc" -ne "$want" ]; then
        printf 'FAIL: %s: rc %s, wanted %s\n%s\n' "$desc" "$rc" "$want" "$out" >&2
        failures=$((failures + 1))
        return
    fi
    printf 'PASS: %s\n' "$desc"
}

expect_line() {
    local desc="$1" pattern="$2"
    if printf '%s\n' "$out" | grep -qF -- "$pattern"; then
        printf 'PASS: %s\n' "$desc"
    else
        printf 'FAIL: %s: "%s" missing from output\n%s\n' "$desc" "$pattern" "$out" >&2
        failures=$((failures + 1))
    fi
}

gate_ok='printf "gate: ok\nAll checks passed.\n"'
gate_early='printf "All checks passed.\ngate stopped early\n"'
gate_fail='printf "FAIL: something\n"; exit 1'
status_running="printf 'SuperMox VM running (pid 42, ssh port 2224)\n'"
status_clean="printf 'no SuperMox VM running\n'"

# --help must document the flags and every step, so a release engineer does
# not have to read the script to remember what the command does.
run bash "$check" --help
expect_rc "--help works" 0
expect_line "--help documents the flags" "--allow-skip"
expect_line "--help documents the live steps" "manager-live"
expect_line "--help documents the overrides" "RELEASE_CHECK_SERVICES_ALLOW"

run bash "$check" --no-such-flag
expect_rc "an unknown flag is refused" 2

# --offline: the gate step alone decides.
run env RELEASE_CHECK_GATE="$gate_ok" bash "$check" --offline
expect_rc "offline, gate passes" 0
expect_line "offline records the other steps as not applicable" "SKIP (offline)"

run env RELEASE_CHECK_GATE="$gate_fail" bash "$check" --offline
expect_rc "offline, gate exits non-zero" 1
expect_line "the gate failure is recorded" "FAIL (rc 1)"

run env RELEASE_CHECK_GATE="$gate_early" bash "$check" --offline
expect_rc "offline, gate output does not end with the success line" 1
expect_line "the success-line rule is reported" \
  'FAIL (output does not end with "All checks passed.")'

# A VM already up: the release check owns the VM it stops, so it refuses to
# run, and every step that then did not run counts against it.
run env RELEASE_CHECK_GATE="$gate_ok" \
    RELEASE_CHECK_VM_STATUS="$status_running" bash "$check"
expect_rc "a VM is already running" 1
expect_line "vm-status refuses a running VM" "FAIL (a VM is already running)"
expect_line "the steps that did not run are counted" "FAIL (6 step(s) not verified)"

run env RELEASE_CHECK_GATE="$gate_ok" \
    RELEASE_CHECK_VM_STATUS="$status_running" bash "$check" --allow-skip
expect_rc "a VM is already running, --allow-skip" 1
expect_line "--allow-skip excuses the SKIPs, not the FAIL" \
  "FAIL (1 step(s) not verified)"

# Full mode, every step stubbed: the happy path wires up end to end, and one
# failing live step is reported without stopping the steps after it.
run env RELEASE_CHECK_GATE="$gate_ok" RELEASE_CHECK_VM_STATUS="$status_clean" \
    RELEASE_CHECK_BOOT=true RELEASE_CHECK_LIVE=true RELEASE_CHECK_JOIN=true \
    RELEASE_CHECK_NO_SYSTEMD=true RELEASE_CHECK_SERVICES=true \
    bash "$check"
expect_rc "all steps stubbed and passing" 0
expect_line "the summary lists the live step" "manager-live"

run env RELEASE_CHECK_GATE="$gate_ok" RELEASE_CHECK_VM_STATUS="$status_clean" \
    RELEASE_CHECK_BOOT=true RELEASE_CHECK_LIVE=false RELEASE_CHECK_JOIN=true \
    RELEASE_CHECK_NO_SYSTEMD=true RELEASE_CHECK_SERVICES=true \
    bash "$check"
expect_rc "one live step fails" 1
expect_line "the run continued past the failure" "join-e2e"

if [ "$failures" -ne 0 ]; then
    printf 'FAIL: %d test(s) failed\n' "$failures" >&2
    exit 1
fi
printf 'PASS: release-check step logic\n'
