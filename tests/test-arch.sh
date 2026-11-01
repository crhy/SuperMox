#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

fail=0

arch_run() {
  local arch="$1" fn="$2"
  SUPERMOX_ARCH="$arch" bash -c 'source scripts/arch.sh; "$1"' _ "$fn"
}

expect() {
  local desc="$1" want="$2" got="$3"
  if [ "$want" != "$got" ]; then
    echo "FAIL: $desc: want [$want] got [$got]"
    fail=1
  fi
}

expect_map() {
  local arch="$1" kernel="$2" bin="$3" comm="$4" console="$5" mach="$6" binfmt="$7"
  expect "$arch kernel" "$kernel" "$(arch_run "$arch" supermox_kernel_pkg)"
  expect "$arch qemu_bin" "$bin" "$(arch_run "$arch" supermox_qemu_bin)"
  expect "$arch qemu_comm" "$comm" "$(arch_run "$arch" supermox_qemu_comm)"
  expect "$arch console" "$console" "$(arch_run "$arch" supermox_console)"
  expect "$arch machine_opts" "$mach" "$(arch_run "$arch" supermox_machine_opts)"
  expect "$arch binfmt_name" "$binfmt" "$(arch_run "$arch" supermox_binfmt_name)"
}

expect_map amd64 linux-image-amd64 qemu-system-x86_64 qemu-system-x86 ttyS0 '' x86_64
expect_map arm64 linux-image-arm64 qemu-system-aarch64 qemu-system-aar ttyAMA0 '-M virt' aarch64
expect_map armhf linux-image-armmp-lpae qemu-system-arm qemu-system-arm ttyAMA0 '-M virt' arm
expect_map riscv64 linux-image-riscv64 qemu-system-riscv64 qemu-system-ris ttyS0 '-M virt' riscv64
expect_map loong64 linux-image-loong64 qemu-system-loongarch64 qemu-system-loo ttyS0 '-M virt' loongarch64

rc=0
SUPERMOX_ARCH=bogus bash -c 'source scripts/arch.sh; supermox_binfmt_name' >/dev/null 2>&1 || rc=$?
if [ "$rc" -ne 2 ]; then
  echo "FAIL: unknown SUPERMOX_ARCH must exit 2 from supermox_binfmt_name, got $rc"
  fail=1
fi

# build-rootfs.sh must probe the binfmt entry by its QEMU name: qemu-arm64 and qemu-armhf
# never exist, so the old qemu-$SUPERMOX_ARCH probe rejected a perfectly emulatable host.
if ! grep -q 'supermox_binfmt_name' scripts/build-rootfs.sh; then
  echo "FAIL: build-rootfs.sh does not use supermox_binfmt_name"
  fail=1
fi
if grep -q 'binfmt_misc/qemu-\$SUPERMOX_ARCH' scripts/build-rootfs.sh; then
  echo "FAIL: build-rootfs.sh still probes binfmt_misc/qemu-\$SUPERMOX_ARCH"
  fail=1
fi

rc=0
SUPERMOX_ARCH=bogus bash -c 'source scripts/arch.sh; supermox_kernel_pkg' >/dev/null 2>&1 || rc=$?
if [ "$rc" -ne 2 ]; then
  echo "FAIL: unknown SUPERMOX_ARCH must exit 2, got $rc"
  fail=1
fi

out="$(SUPERMOX_ARCH=arm64 bash scripts/vm-start.sh --dry-run)"
missing=0
for pat in 'qemu-system-aarch64' '-M virt' 'console=ttyAMA0' '-cpu max'; do
  if ! printf '%s\n' "$out" | grep -qF -- "$pat"; then
    echo "FAIL: vm-start.sh arm64 --dry-run missing: $pat"
    missing=1
  fi
done
if [ "$missing" -ne 0 ]; then
  fail=1
fi

out="$(SUPERMOX_ARCH=arm64 bash scripts/build-rootfs.sh --dry-run)"
missing=0
for pat in '--architectures=arm64' 'linux-image-arm64'; do
  if ! printf '%s\n' "$out" | grep -qF -- "$pat"; then
    echo "FAIL: build-rootfs.sh arm64 --dry-run missing: $pat"
    missing=1
  fi
done
if [ "$missing" -ne 0 ]; then
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "OK: arch.sh maps all 5 arches (kernel, qemu bin/comm, console, machine opts, binfmt name), unknown arch exits 2, and vm-start/build-rootfs honor SUPERMOX_ARCH=arm64"
