#!/usr/bin/env bash
# SuperMox per-node capability probe.
#
# Prints one key=value line per capability so a node can be placed in a
# capability tier (see docs/any-hardware.md):
#   arch=         Debian architecture name of this node
#   kvm=yes|no    hardware virtualisation usable by QEMU (/dev/kvm)
#   lxc=yes|no    namespaces + cgroups, i.e. LXC containers can run
#   tcg_targets=  qemu-system-* binaries present (TCG software emulation)
#   cpus=         number of CPU cores
#   mem_mb=       available memory in MiB
#
# --json prints the same data as one JSON object (tcg_targets becomes a JSON
# array, cpus and mem_mb are numbers).
#
# Runs on stock Linux and on Android/LineageOS (no dpkg, no coreutils
# guarantees): every probe is best-effort, the script never fails because a
# probe is missing. Installed as /usr/sbin/supermox-node-caps by supermox-ve.
set -euo pipefail

usage() {
  printf 'usage: %s [--json]\n' "${0##*/}" >&2
}

json=0
for arg in "$@"; do
  case "$arg" in
    --json) json=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      printf 'ERROR: unknown argument: %s\n' "$arg" >&2
      usage
      exit 2
      ;;
  esac
done

# --- arch ----------------------------------------------------------------
# dpkg knows the Debian architecture name; Android/LineageOS has no dpkg, so
# fall back to mapping `uname -m`.
arch=""
if command -v dpkg >/dev/null 2>&1; then
  arch="$(dpkg --print-architecture 2>/dev/null || true)"
fi
arch_from_uname() {
  local m
  m="$(uname -m 2>/dev/null || printf 'unknown')"
  case "$m" in
    x86_64) printf 'amd64' ;;
    aarch64) printf 'arm64' ;;
    arm*) printf 'armhf' ;;
    i*86) printf 'i386' ;;
    riscv64) printf 'riscv64' ;;
    loong*) printf 'loong64' ;;
    s390x) printf 's390x' ;;
    *) printf 'unknown' ;;
  esac
}

if [ -z "$arch" ] || [ "$arch" = unknown ]; then
  arch="$(arch_from_uname)"
fi

# --- kvm ----------------------------------------------------------------
# QEMU needs /dev/kvm (VT-x/AMD-V on x86, EL2 on ARM). qemu-server's kvm_version()
# opens /dev/kvm and issues KVM_GET_API_VERSION; a char device that cannot be
# opened read-write is no use to a VM, so require rw.
kvm=no
if [ -c /dev/kvm ]; then
  if (: <> /dev/kvm) 2>/dev/null; then
    kvm=yes
  fi
fi

# --- lxc ----------------------------------------------------------------
# LXC needs only a kernel with PID namespaces and a mounted cgroup fs.
lxc=no
if [ -e /proc/self/ns/pid ] && [ -d /sys/fs/cgroup ]; then
  lxc=yes
fi

# --- tcg_targets --------------------------------------------------------
# Every qemu-system-<arch> on PATH can run a guest under QEMU TCG (pure
# software emulation, no host virtualisation support needed), including a guest
# of a different architecture than this node.
tcg_list=()
if [ -n "${PATH:-}" ]; then
  shopt -s nullglob
  old_ifs=$IFS
  IFS=:
  for dir in $PATH; do
    [ -n "$dir" ] || dir=.
    [ -d "$dir" ] || continue
    for f in "$dir"/qemu-system-*; do
      [ -x "$f" ] || continue
      base="${f##*/}"
      tcg_list+=("$base")
    done
  done
  IFS=$old_ifs
  shopt -u nullglob
fi

# de-duplicate and sort
tcg_targets=()
if [ "${#tcg_list[@]}" -gt 0 ]; then
  while IFS= read -r t; do
    tcg_targets+=("$t")
  done < <(printf '%s\n' "${tcg_list[@]}" | LC_ALL=C sort -u)
fi

# --- cpus ---------------------------------------------------------------
cpus=0
if command -v nproc >/dev/null 2>&1; then
  cpus="$(nproc 2>/dev/null || printf 0)"
fi
case "$cpus" in '' | *[!0-9]*) cpus=0 ;; esac
if [ "$cpus" -eq 0 ] && [ -r /proc/cpuinfo ]; then
  cpus="$(grep -c -E '^processor[[:space:]]*:' /proc/cpuinfo 2>/dev/null || true)"
  case "$cpus" in '' | *[!0-9]*) cpus=0 ;; esac
fi
if [ "$cpus" -eq 0 ]; then
  cpus=1
fi

# --- mem_mb -------------------------------------------------------------
# Prefer the cgroup-aware AvailableMemory, then MemAvailable, then MemFree.
mem_mb=0
if [ -r /proc/meminfo ]; then
  mem_kb="$(awk '
    /^AvailableMemory:/ { print $2; found = 1; exit }
    /^MemAvailable:/ { v = $2 }
    /^MemFree:/ { if (v == "") v = $2 }
    END { if (found || v != "") print v }
  ' /proc/meminfo 2>/dev/null || true)"
  case "$mem_kb" in '' | *[!0-9]*) mem_kb=0 ;; esac
  mem_mb=$((mem_kb / 1024))
fi

if [ "$json" -eq 1 ]; then
  printf '{\n'
  printf '  "arch": "%s",\n' "$arch"
  printf '  "kvm": "%s",\n' "$kvm"
  printf '  "lxc": "%s",\n' "$lxc"
  printf '  "tcg_targets": ['
  first=1
  for t in ${tcg_targets[@]+"${tcg_targets[@]}"}; do
    if [ "$first" -eq 1 ]; then
      first=0
    else
      printf ', '
    fi
    printf '"%s"' "$t"
  done
  printf '],\n'
  printf '  "cpus": %s,\n' "$cpus"
  printf '  "mem_mb": %s\n' "$mem_mb"
  printf '}\n'
else
  joined=""
  for t in ${tcg_targets[@]+"${tcg_targets[@]}"}; do
    if [ -n "$joined" ]; then
      joined="$joined $t"
    else
      joined="$t"
    fi
  done
  printf 'arch=%s\n' "$arch"
  printf 'kvm=%s\n' "$kvm"
  printf 'lxc=%s\n' "$lxc"
  printf 'tcg_targets=%s\n' "$joined"
  printf 'cpus=%s\n' "$cpus"
  printf 'mem_mb=%s\n' "$mem_mb"
fi

exit 0
