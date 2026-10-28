#!/usr/bin/env bash
# Build and unit-test our libsystemd-free proxmox-systemd crate inside the milestone 1 VM.
# Skips (exit 0) when the VM is not reachable, so the gate still runs without it.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
crate="$repo_root/packaging/librust-proxmox-systemd-dev/crate"

if ! timeout 15 bash "$repo_root/scripts/vm-ssh.sh" true >/dev/null 2>&1; then
  echo "SKIP: VM not reachable, proxmox-systemd crate not tested"
  exit 0
fi

out="$(tar -C "$crate" -cf - . | bash "$repo_root/scripts/vm-ssh.sh" '
  set -e
  export LC_ALL=C DEBIAN_FRONTEND=noninteractive
  dpkg -s cargo librust-libc-dev >/dev/null 2>&1 ||
    apt-get install -y -qq --no-install-recommends cargo librust-libc-dev >/dev/null
  rm -rf /root/psd-test && mkdir -p /root/psd-test && tar -C /root/psd-test -xf -
  mkdir -p /root/.cargo-supermox
  printf "[source.crates-io]\nreplace-with = \"debian\"\n\n[source.debian]\ndirectory = \"/usr/share/cargo/registry\"\n" \
    > /root/.cargo-supermox/config.toml
  cd /root/psd-test && CARGO_HOME=/root/.cargo-supermox cargo test --offline 2>&1
' 2>&1)" || {
  printf '%s\n' "$out" | grep -E '^(error|warning: unused)|-->' | head -40
  echo "FAIL: proxmox-systemd crate does not build or its tests fail"
  exit 1
}

if printf '%s\n' "$out" | grep -q 'test result: ok'; then
  echo "OK: proxmox-systemd crate builds and its tests pass"
else
  printf '%s\n' "$out" | tail -20
  echo "FAIL: no passing test result from cargo test"
  exit 1
fi
