#!/usr/bin/env bash
# scripts/vm-boot-iso.sh boots the PC ISO headless in QEMU and proves the boot.
# Real QEMU is not run here: the test builds a ~1 MB fake ISO with xorriso whose
# boot/grub/grub.cfg, live/vmlinuz*, live/initrd.img* and live/filesystem.squashfs
# are exactly what the script reads, and a fake qemu named qemu-system-x86_64 that
# writes the -pidfile and the -serial file the way a booting guest would. That
# covers everything a real boot costs 10 minutes for except the guest itself: the
# kernel command line, the ISO's own root filesystem as the sysvinit proof, and
# stopping every process the script started.
set -euo pipefail

cd "$(dirname "$0")/.."

# Determinism, the way tests/test-vm-scripts.sh does it: config/local.env or a
# developer shell exporting SUPERMOX_ISO_RAM=2048 would make the assertions below
# describe the caller's machine instead of the script.
while IFS= read -r _smx_var; do
  unset "$_smx_var"
done < <(compgen -e | grep -E '^SUPERMOX_[A-Za-z_][A-Za-z0-9_]*$')
unset _smx_var

target="scripts/vm-boot-iso.sh"
if [ ! -f "$target" ]; then
  echo "FAIL: $target does not exist"
  exit 1
fi

# amd64 is forced so the fake qemu's name matches supermox_qemu_comm for amd64
# whatever host runs this test.
export SUPERMOX_ARCH=amd64

T="$PWD/build/test-vm-boot-iso"
rm -rf "$T"
mkdir -p "$T/iso" "$T/stage/boot/grub" "$T/stage/live" "$T/stage/rootfs/usr/sbin" "$T/bin"
export SUPERMOX_ISO_WORK="$T/work"

if ! command -v xorriso >/dev/null 2>&1 || ! command -v mksquashfs >/dev/null 2>&1; then
  echo "SKIP: xorriso and mksquashfs are needed to build the fake ISO"
  exit 0
fi

# grub.cfg: default=0 means the first "linux" line, and findiso=${iso_path} is what
# the script must drop (a grub variable, not a kernel argument).
cat > "$T/stage/boot/grub/grub.cfg" <<'CFG'
set timeout=1
set default=0
menuentry "SuperMox live" {
linux /boot/vmlinuz-fake root=cdr-isolated cdrom-id=FAKE quiet --noexec --autoboot findiso=${iso_path}
}
CFG
printf 'fake kernel\n' > "$T/stage/live/vmlinuz-fake"
printf 'fake initrd\n' > "$T/stage/live/initrd.img-fake"
# The live root filesystem: /sbin/init as a regular file and no systemd binary.
# This is proof B of "init is sysvinit" -- the one that works when sysvinit's banner
# never reaches the serial line, because this guest's console is the framebuffer.
printf '#!/bin/sh\nexec /lib/init.d/rc 2\n' > "$T/stage/rootfs/usr/sbin/init"
chmod 755 "$T/stage/rootfs/usr/sbin/init"
mksquashfs "$T/stage/rootfs" "$T/stage/live/filesystem.squashfs" -noappend -comp gzip >/dev/null
iso="$T/iso/supermox-fake.iso"
xorriso -as mkisofs -o "$iso" -V FAKE -quiet "$T/stage" 2>/dev/null

if [ ! -f "$iso" ]; then
  echo "FAIL: xorriso wrote no $iso"
  exit 1
fi

# The fake qemu. A script run through a shebang reports comm "bash", and the script's
# own detection needs /proc/<pid>/comm to equal supermox_qemu_comm (the kernel truncates
# a process name to 15 characters), so the fake is compiled from C and named qemu-system-x86_64.
# It parses the two arguments this script relies on (-pidfile, -serial file:...) and ignores
# the rest, which is what a real qemu does with the others.
fake_src="$T/bin/fake-qemu.c"
fake_bin="$T/bin/qemu-system-x86_64"
cat > "$fake_src" <<'C'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>

static volatile int running = 1;
static void onterm(int sig) { (void)sig; running = 0; }

int main(int argc, char **argv) {
  const char *pidfile = NULL, *serial = NULL;
  int i;
  FILE *f;
  for (i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "-pidfile") && i + 1 < argc) pidfile = argv[++i];
    else if (!strncmp(argv[i], "-serial", 7) && i + 1 < argc) {
      serial = argv[++i];
      if (strncmp(serial, "file:", 5) != 0) serial = NULL;
      else serial += 5;
    }
  }
  if (pidfile) {
    f = fopen(pidfile, "w");
    if (f) { fprintf(f, "%d\n", (int)getpid()); fclose(f); }
  }
  if (serial) {
    f = fopen(serial, "w");
    if (f) {
      fprintf(f, "Linux version 6.0.0-fake (gcc) #1 SMP x86_64\n"
                  "  Starting service a: ok\n"
                  "  Starting service b: ok\n"
                  "startpar: service(s) restarted> 2\n");
      fclose(f);
    }
  }
  signal(SIGTERM, onterm);
  signal(SIGINT, onterm);
  while (running) sleep(1);
  return 0;
}
C
if ! command -v cc >/dev/null 2>&1; then
  echo "SKIP: cc is needed to compile the fake qemu"
  exit 0
fi
if ! cc -O0 -o "$fake_bin" "$fake_src" 2>/dev/null; then
  echo "FAIL: the fake qemu did not compile"
  exit 1
fi

fail=0
expect() { # $1 description, $2 fixed string, $3 text
  if ! printf '%s\n' "$3" | grep -qF -- "$2"; then
    echo "FAIL: $1 (missing: $2)"
    fail=1
  fi
}
reject() { # $1 description, $2 fixed string that must NOT appear, $3 text
  if printf '%s\n' "$3" | grep -qF -- "$2"; then
    echo "FAIL: $1 (unexpected: $2)"
    fail=1
  fi
}

# --- --dry-run: the command line a real boot would use --------------------------
out="$(PATH="$T/bin:$PATH" bash "$target" --dry-run "$iso")"
for pat in "-cdrom $iso" '-m 3072' '-no-reboot' '-kernel' '-initrd' \
  '-nic user,model=virtio-net-pci' '-display none' '-serial file:' \
  '-qmp unix:' ',server,nowait' '-daemonize' '-pidfile'; do
  expect 'dry-run command' "$pat" "$out"
done
# The kernel command line comes from grub.cfg's default entry, with the grub
# variable dropped and console= appended.
expect 'dry-run append' '--noexec --autoboot console=ttyS0' "$out"
reject 'dry-run append' 'findiso=' "$out"

# SUPERMOX_ISO_RAM overrides the 3072 default; SUPERMOX_VM_RAM must not feed it.
ram_out="$(PATH="$T/bin:$PATH" SUPERMOX_ISO_RAM=1234 bash "$target" --dry-run "$iso")"
expect 'SUPERMOX_ISO_RAM' '-m 1234' "$ram_out"
ram_out="$(PATH="$T/bin:$PATH" SUPERMOX_VM_RAM=2048 bash "$target" --dry-run "$iso")"
expect 'SUPERMOX_VM_RAM ignored' '-m 3072' "$ram_out"

# A timeout too small to boot, and a missing ISO, are refused rather than used.
if PATH="$T/bin:$PATH" bash "$target" --timeout 30 "$iso" >/dev/null 2>&1; then
  echo "FAIL: vm-boot-iso.sh accepted --timeout 30"
  fail=1
fi
if PATH="$T/bin:$PATH" bash "$target" /no/such/file.iso >/dev/null 2>&1; then
  echo "FAIL: vm-boot-iso.sh accepted a missing ISO"
  fail=1
fi

# --- a run against the fake ISO ------------------------------------------------
# A previous run's qemu is left running on purpose, carrying -pidfile but with a
# pidfile QEMU has already unlinked (the case the pidfile alone cannot see; see
# scripts/vm-pid.sh). The script must stop it: an ISO-boot qemu nobody stops holds
# its RAM for the whole host, which is what exhausted this PC on 2026-11-22.
rm -f "$SUPERMOX_ISO_WORK/qemu.pid"
"$fake_bin" -pidfile "$SUPERMOX_ISO_WORK/qemu.pid" >/dev/null 2>&1 &
stale=$!
rm -f "$SUPERMOX_ISO_WORK/qemu.pid"
sleep 1
if ! kill -0 "$stale" 2>/dev/null; then
  echo "FAIL: the fake qemu did not start"
  exit 1
fi

out="$(PATH="$T/bin:$PATH" bash "$target" --timeout 60 "$iso" 2>&1 || true)"

expect 'previous qemu stopped' 'a previous ISO-boot qemu is still running' "$out"
if kill -0 "$stale" 2>/dev/null; then
  echo "FAIL: vm-boot-iso.sh left the previous ISO-boot qemu (pid $stale) running"
  fail=1
fi
kill "$stale" 2>/dev/null || true
wait "$stale" 2>/dev/null || true

# The three checks that do not need QMP's video console must pass; the screen check
# must fail, because this fake qemu has no QMP socket and so wrote no screendump.
expect 'kernel check' 'PASS: kernel booted' "$out"
expect 'sysvinit check' 'PASS: init is sysvinit (ISO root filesystem:' "$out"
expect 'login stage' 'PASS: boot reached the login stage' "$out"
expect 'screen check fails' 'FAIL: login screen drawn on the guest console' "$out"

# No qemu of this test may survive the script, whatever path it took.
leftover="$(pgrep -x qemu-system-x86 -a 2>/dev/null | grep -F "$SUPERMOX_ISO_WORK" || true)"
if [ -n "$leftover" ]; then
  echo "FAIL: vm-boot-iso.sh left a qemu running: $leftover"
  fail=1
fi

# --- artifacts ---------------------------------------------------------------
if [ ! -f "$SUPERMOX_ISO_WORK/serial.log" ]; then
  echo "FAIL: no serial log at $SUPERMOX_ISO_WORK/serial.log"
  fail=1
fi
if [ -f "$SUPERMOX_ISO_WORK/qemu.pid" ] &&
  kill -0 "$(tr -dc '0-9' < "$SUPERMOX_ISO_WORK/qemu.pid")" 2>/dev/null; then
  echo "FAIL: the pidfile names a process that is still running"
  fail=1
fi

# The newest ISO is the one to boot: with `sort -nr | tail -n1` the 11.26 boot test
# booted the old 10.26 image and reported its corosync failure (2026-11-06).
if ! grep -q "sort -nr | head -n1" scripts/vm-boot-iso.sh; then
  echo "FAIL: vm-boot-iso.sh does not pick the newest build/iso/supermox-*.iso"
  fail=1
fi
if ! grep -q "extracted-from" scripts/vm-boot-iso.sh; then
  echo "FAIL: the kernel/initrd cache is not tied to the ISO it came from"
  fail=1
fi
if ! grep -q "corosync and pve-cluster came up" scripts/vm-boot-iso.sh; then
  echo "FAIL: the boot test no longer checks that corosync and /etc/pve came up"
  fail=1
fi

rm -rf "$T"
if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "OK: vm-boot-iso.sh builds the qemu command from the ISO, proves sysvinit from the ISO's own root filesystem, and stops every qemu it started"
