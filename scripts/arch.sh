#!/usr/bin/env bash
# Sourced by build-rootfs.sh, vm-start.sh and vm-stop.sh.
#
# One architecture setting for the whole project: SUPERMOX_ARCH, a Debian arch name.
# It defaults to the build host's arch but may be set to any architecture SuperMox targets.
# amd64 is only the first test target; SuperMox is architecture-neutral (arm64, armhf,
# riscv64, loong64, ...). This file is the single place that maps a Debian arch to the
# kernel package, QEMU binary, its process comm, the serial console and the QEMU machine
# options. Unknown architectures are a hard error (exit 2).

: "${SUPERMOX_ARCH:=$(dpkg --print-architecture)}"

supermox_arch_known() {
  case "$SUPERMOX_ARCH" in
    amd64 | arm64 | armhf | riscv64 | loong64) return 0 ;;
    *)
      printf 'ERROR: unknown SUPERMOX_ARCH=%s (known: amd64 arm64 armhf riscv64 loong64)\n' "$SUPERMOX_ARCH" >&2
      return 2
      ;;
  esac
}

# Debian arch -> kernel package that provides /boot/vmlinuz-* and /boot/initrd.img-*.
supermox_kernel_pkg() {
  case "$SUPERMOX_ARCH" in
    amd64)   printf 'linux-image-amd64\n' ;;
    arm64)   printf 'linux-image-arm64\n' ;;
    armhf)   printf 'linux-image-armmp-lpae\n' ;;
    riscv64) printf 'linux-image-riscv64\n' ;;
    loong64) printf 'linux-image-loong64\n' ;;
    *) supermox_arch_known ;;
  esac
}

# Debian arch -> QEMU emulator binary.
supermox_qemu_bin() {
  case "$SUPERMOX_ARCH" in
    amd64)   printf 'qemu-system-x86_64\n' ;;
    arm64)   printf 'qemu-system-aarch64\n' ;;
    armhf)   printf 'qemu-system-arm\n' ;;
    riscv64) printf 'qemu-system-riscv64\n' ;;
    loong64) printf 'qemu-system-loongarch64\n' ;;
    *) supermox_arch_known ;;
  esac
}

# The process name /proc/<pid>/comm reports for that QEMU binary: the kernel truncates
# comm to 15 characters, so it is the first 15 characters of the binary name.
supermox_qemu_comm() {
  local bin
  bin="$(supermox_qemu_bin)" || return 2
  printf '%s\n' "${bin:0:15}"
}

# Debian arch -> serial console the guest kernel uses for its console= line.
supermox_console() {
  case "$SUPERMOX_ARCH" in
    amd64 | loong64) printf 'ttyS0\n' ;;
    arm64 | armhf)   printf 'ttyAMA0\n' ;;
    riscv64)         printf 'ttyS0\n' ;;
    *) supermox_arch_known ;;
  esac
}

# Debian arch -> QEMU machine options. amd64 uses the default machine; the others need
# "-M virt". Prints nothing for amd64, "-M virt" for the rest (one line each).
supermox_machine_opts() {
  case "$SUPERMOX_ARCH" in
    amd64) printf '' ;;
    arm64 | armhf | riscv64 | loong64) printf -- '-M virt\n' ;;
    *) supermox_arch_known ;;
  esac
}
