#!/usr/bin/env bash
# t42: per-node capability layer (any hardware: phones, old ARM boards, VMs
# without nested virt). Checks scripts/supermox-node-caps.sh prints the six
# capability keys, that --json is valid JSON, that the probe still works where
# no external tools exist (Android/LineageOS), and that the script is really
# shipped as /usr/sbin/supermox-node-caps by supermox-ve with the repo copy as
# the single source of truth.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "FAIL: $*" >&2; exit 1; }

caps=scripts/supermox-node-caps.sh
[ -f "$caps" ] || fail "missing $caps"

keys=(arch kvm lxc tcg_targets cpus mem_mb)

out=$(bash "$caps") || fail "supermox-node-caps.sh exited non-zero"
for k in "${keys[@]}"; do
  n=$(printf '%s\n' "$out" | grep -c "^$k=" || true)
  [ "$n" -eq 1 ] || fail "key $k appears $n times in key=value output (want 1)"
done

getval() {
  local k=$1
  printf '%s\n' "$out" | sed -n "s/^$k=//p"
}

arch=$(getval arch)
[ -n "$arch" ] || fail "arch is empty"
case "$arch" in
  amd64 | arm64 | armhf | i386 | riscv64 | loong64 | s390x | unknown) ;;
  *) fail "unexpected arch value: $arch" ;;
esac

kvm=$(getval kvm)
lxc=$(getval lxc)
for v in "$kvm" "$lxc"; do
  case "$v" in
    yes | no) ;;
    *) fail "kvm/lxc must be yes or no, got '$v'" ;;
  esac
done

cpus=$(getval cpus)
case "$cpus" in
  '' | *[!0-9]*) fail "cpus not a number: '$cpus'" ;;
esac
[ "$cpus" -ge 1 ] || fail "cpus must be >= 1, got $cpus"

mem_mb=$(getval mem_mb)
case "$mem_mb" in
  '' | *[!0-9]*) fail "mem_mb not a number: '$mem_mb'" ;;
esac

tcg=$(getval tcg_targets)
for t in $tcg; do
  case "$t" in
    qemu-system-*) ;;
    *) fail "bad tcg target: $t" ;;
  esac
  command -v "$t" >/dev/null 2>&1 || fail "tcg target not on PATH: $t"
done

# The probe must be usable where there is no dpkg, no nproc, no sort: run it
# with an empty PATH and require the same six keys and a zero exit status.
deg=$(env PATH=/nonexistent /bin/bash "$caps") ||
  fail "capability probe failed with no tools on PATH"
for k in "${keys[@]}"; do
  printf '%s\n' "$deg" | grep -q "^$k=" || fail "key $k missing when PATH is empty"
done

# --json must be valid JSON with the same six keys.
json_out=$(bash "$caps" --json) || fail "--json run exited non-zero"
if command -v python3 >/dev/null 2>&1; then
  printf '%s\n' "$json_out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
want = {"arch", "kvm", "lxc", "tcg_targets", "cpus", "mem_mb"}
missing = want - set(d)
if missing:
    raise SystemExit("missing JSON keys: %s" % sorted(missing))
extra = set(d) - want
if extra:
    raise SystemExit("unexpected JSON keys: %s" % sorted(extra))
if not isinstance(d["tcg_targets"], list):
    raise SystemExit("tcg_targets must be a JSON array")
for k in ("kvm", "lxc"):
    if d[k] not in ("yes", "no"):
        raise SystemExit("%s must be yes/no, got %r" % (k, d[k]))
if not isinstance(d["cpus"], int) or d["cpus"] < 1:
    raise SystemExit("cpus must be an int >= 1, got %r" % d["cpus"])
if not isinstance(d["mem_mb"], int) or d["mem_mb"] < 0:
    raise SystemExit("mem_mb must be an int >= 0, got %r" % d["mem_mb"])
' || fail "--json output is not valid/complete JSON"
else
  printf '%s\n' "$json_out" | grep -q '"tcg_targets": \[' ||
    fail "--json output has no tcg_targets array"
  printf '%s\n' "$json_out" | grep -q '"cpus": [0-9]' ||
    fail "--json output has no numeric cpus"
fi

# Shipped as /usr/sbin/supermox-node-caps by supermox-ve, repo copy is the
# single source of truth (same rule as init scripts).
map=config/shipped-scripts.txt
[ -f "$map" ] || fail "missing $map"
grep -q '^supermox-ve scripts/supermox-node-caps.sh usr/sbin/supermox-node-caps$' \
  "$map" || fail "$map must map supermox-ve scripts/supermox-node-caps.sh -> usr/sbin/supermox-node-caps"
grep -q 'shipped-scripts.txt' scripts/vm-build-pkg.sh ||
  fail "scripts/vm-build-pkg.sh must stage $map into the packaging copy"
grep -q 'debian/supermox-ve/usr/sbin/supermox-node-caps' \
  packaging/supermox-ve/debian/rules ||
  fail "packaging/supermox-ve/debian/rules must install supermox-node-caps into /usr/sbin"
dup=$(find packaging/supermox-ve -name 'supermox-node-caps*' || true)
[ -z "$dup" ] || fail "duplicate copy of the probe under packaging/: $dup"

# The qemu-server patch that makes TCG the default must still apply to the
# pinned upstream source (patches are applied in name order by apply-patches.sh).
work=build/t42-patch-verify
rm -rf "$work"
mkdir -p "$work"
cp -r upstream/pxvirt/packages/qemu-server/qemu-server "$work/dest"
for p in patches/qemu-server/*.patch; do
  abs=$PWD/$p
  (cd "$work/dest" && patch -p1 --forward --batch < "$abs" >/dev/null) ||
    fail "$(basename "$p") does not apply to pinned qemu-server source"
done
grep -qF "defaulting VM" "$work/dest/src/PVE/QemuServer.pm" ||
  fail "qemu-server TCG default warning missing after applying patches"
rm -rf "$work"

echo "PASS: node capability probe (arch=$arch kvm=$kvm lxc=$lxc cpus=$cpus mem_mb=$mem_mb)"
exit 0
