#!/usr/bin/env bash
# Offline regression guard for the REAL pin set (task f280): the real
# config/upstream-overrides.txt against tests/fixtures/upstream-drift-Packages-current,
# a committed snapshot of the last-known Proxmox trixie Packages index for every
# pinned component. Nothing else in the suite guards the pins staying in sync:
# tests/test-upstream-drift-check.sh uses synthetic fixtures, and the real drift
# check needs a live network index on a build host, so a later edit that drops a
# component below the last-known trixie version would silently pass test-python.sh
# and the monthly build.
#
#   1. the real pin set against the snapshot -> exit 0, no BEHIND line, every
#      component in-sync (a component missing from the snapshot prints UNKNOWN,
#      which fails here: the snapshot must cover the whole pin set)
#   2. the probe: one component's pin lowered to an older version the snapshot
#      holds -> BEHIND line and exit 1, the guard actually catching a down-bump
set -euo pipefail

cd "$(dirname "$0")/.."

target="scripts/upstream-drift-check.sh"
pk="tests/fixtures/upstream-drift-Packages-current"
ov="config/upstream-overrides.txt"
bins="config/upstream-source-binaries.txt"

fail=0

for f in "$target" "$pk" "$ov" "$bins"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: $f does not exist"
    exit 1
  fi
done

count_matches() {
  local pattern="$1" text="$2" n
  n="$(printf '%s\n' "$text" | grep -cE -- "$pattern")" || true
  printf '%s' "$n"
}

# The component the probe down-bumps, and the two pve-container stanzas the
# snapshot holds (older first, newest last, per the fixture's own header).
probe_comp="pve-container"
# Every Version: line of one package's stanzas in the snapshot, stanza order.
pkg_versions() {
  awk -v c="$1" '
    /^Package: / { f = ($0 == "Package: " c); next }
    f && /^Version: / { print substr($0, 10) }
  ' "$pk"
}
newest="$(pkg_versions "$probe_comp" | tail -1)"
older="$(pkg_versions "$probe_comp" | head -1)"
if [ -z "$newest" ] || [ -z "$older" ] || [ "$newest" = "$older" ]; then
  echo "FAIL: $pk must hold at least two $probe_comp stanzas (older + newest); got '$older' and '$newest'"
  exit 1
fi
older_base="${older%-*}"

# 1. the real pin set against the snapshot: exit 0, no BEHIND.
rc=0
out="$(bash "$target" --packages "$pk" --overrides "$ov" --source-binaries "$bins" 2>&1)" || rc=$?
if [ "$rc" -ne 0 ]; then
  echo "FAIL: real overrides vs the snapshot exited $rc, expected 0"
  printf '%s\n' "$out"
  fail=1
fi
if printf '%s\n' "$out" | grep -qE '^BEHIND '; then
  echo "FAIL: real overrides vs the snapshot printed a BEHIND line: the pins are below the last-known trixie versions"
  printf '%s\n' "$out"
  fail=1
fi
if printf '%s\n' "$out" | grep -qE '^UNKNOWN '; then
  echo "FAIL: a pinned component is not covered by $pk (UNKNOWN means the snapshot lost it or its source-only alias)"
  printf '%s\n' "$out"
  fail=1
fi
if printf '%s\n' "$out" | grep -qE '^AHEAD '; then
  echo "FAIL: a pinned component is above the snapshot (AHEAD): the snapshot is not the last-known trixie set"
  printf '%s\n' "$out"
  fail=1
fi
n_comp="$(count_matches '.' "$(bash "$target" --overrides "$ov" --list)")"
insync="$(count_matches '^in-sync ' "$out")"
if [ "$insync" -ne "$n_comp" ]; then
  echo "FAIL: $insync in-sync lines, expected one per pinned component ($n_comp)"
  printf '%s\n' "$out"
  fail=1
fi

# 2. the probe: a copy of the real overrides with one component's pinned version
#    lowered to an older version the snapshot holds. A real drift check must say
#    so; the same guard must not be a green light that never fires.
root="build/test-drift-sync"
rm -rf "$root"
mkdir -p "$root"
ov_probe="$root/upstream-overrides.txt"

pin="$(bash "$target" --overrides "$ov" --list | awk -v c="$probe_comp" '$1 == c { print $2 }')"
if [ -z "$pin" ] || [ "$pin" = "$older_base" ]; then
  echo "FAIL: $ov pins $probe_comp at '$pin', nothing to down-bump from to '$older_base'"
  exit 1
fi
awk -v c="$probe_comp" -v from="$pin" -v to="$older_base" '
  $1 == c {
    i = index($0, "#")
    head = substr($0, 1, i - 1)
    tail = substr($0, i)
    sub(from, to, tail)
    print head tail
    next
  }
  { print }
' "$ov" > "$ov_probe"

changed="$(diff "$ov" "$ov_probe" | grep -c '^<')" || true
if [ "$changed" -ne 1 ]; then
  echo "FAIL: the probe copy changed $changed lines, expected exactly the $probe_comp version comment"
  fail=1
fi
if ! grep -qE "^$probe_comp .*  # $older_base," "$ov_probe"; then
  echo "FAIL: the probe copy does not pin $probe_comp at $older_base"
  printf '%s\n' "$(grep "^$probe_comp " "$ov_probe")"
  fail=1
fi

rc=0
probe_out="$(bash "$target" --packages "$pk" --overrides "$ov_probe" --source-binaries "$bins" 2>&1)" || rc=$?
if [ "$rc" -ne 1 ]; then
  echo "FAIL: the down-bumped $probe_comp probe exited $rc, expected 1 (a BEHIND must be an error)"
  printf '%s\n' "$probe_out"
  fail=1
fi
want="BEHIND $probe_comp pinned $older_base but trixie ships $newest"
if ! printf '%s\n' "$probe_out" | grep -qxF -- "$want"; then
  echo "FAIL: the down-bumped probe did not print: $want"
  printf '%s\n' "$probe_out"
  fail=1
fi
behind="$(count_matches '^BEHIND ' "$probe_out")"
if [ "$behind" -ne 1 ]; then
  echo "FAIL: the probe printed $behind BEHIND lines, expected exactly 1"
  printf '%s\n' "$probe_out"
  fail=1
fi
probe_insync="$(count_matches '^in-sync ' "$probe_out")"
if [ "$probe_insync" -ne "$((n_comp - 1))" ]; then
  echo "FAIL: the probe printed $probe_insync in-sync lines, expected $((n_comp - 1)) (only the probed component moved)"
  printf '%s\n' "$probe_out"
  fail=1
fi

# The probe edits a copy only: the real overrides file keeps its pin.
if ! grep -qE "^$probe_comp .*  # $pin," "$ov"; then
  echo "FAIL: the probe edited the real $ov: $probe_comp is no longer pinned at $pin"
  fail=1
fi

# Discard the temp copy (build/ is the scratch dir; never /tmp).
rm -rf "$root"

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "OK: the real config/upstream-overrides.txt set matches $pk (exit 0, $insync in-sync lines, no BEHIND/AHEAD/UNKNOWN); the probe down-bumping $probe_comp to $older_base prints '$want' and exits 1"
