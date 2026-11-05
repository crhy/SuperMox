#!/usr/bin/env bash
# Boot the built PC-edition ISO headless in QEMU and prove the live system comes up.
#
# Why -kernel/-initrd instead of just -cdrom: the ISO's boot sector hands control to
# the x86 BIOS, which loads grub, and grub's menuentry passes the kernel and initrd as
# host-side files that only exist in the Spaced build tree (docs/pc-edition.md, step 3).
# Inside QEMU with -cdrom alone, grub finds no such files and the boot dies. So this
# script takes /live/vmlinuz* and /live/initrd.img* out of the ISO and hands them to
# QEMU itself, and takes the kernel command line verbatim from the ISO's own
# boot/grub/grub.cfg, so the boot is the one the ISO would do.
#
# Two changes to that command line, both needed to watch the boot from the host:
#   findiso=${iso_path} is dropped  - ${iso_path} is a grub variable, meaningless here;
#                                        QEMU attaches the ISO as the guest's CDROM and
#                                        live-boot finds the medium by itself.
#   console=<serial> loglevel=6     - the serial log is this run's only output, and the
#   default entry's "quiet loglevel=3" keeps the kernel's own messages out of it.
#   The kernel applies console= and loglevel= in command-line order, so what is appended
#   wins over what the menuentry sets.
#
# Headless: -display none, -serial file:build/iso-boot/serial.log, QMP on a unix
# socket under build/iso-boot/ for screendump and power off. Never starts a second
# instance (scripts/vm-pid.sh, the vm-start.sh idea), and stops a running SuperMox
# VM first: two VMs at once push this PC into swap (see scripts/vm-stop.sh).
#
# The qemu this script starts is always stopped on the way out (EXIT/INT/TERM trap
# on our own -pidfile: QMP quit, then TERM, then KILL after 10 s). An ISO-boot qemu
# left running is worse than a VM left running: it holds its RAM for the whole host
# and keeps appending to the same serial.log, which is what exhausted this PC once.
# scripts/vm-status.sh reports it, so rule 7's one-VM check sees it too.
#
# RAM: 3072 MB, not the persistent VMs' 4096 -- 4096 plus rhY's desktop and this
# model pushes the PC into swap. SUPERMOX_ISO_RAM overrides; SUPERMOX_VM_RAM
# deliberately does not feed this (rule 8 exports it at 2048, and a 2048 MB guest
# cannot finish this boot).
#
# Where the login prompt is: the ISO's /etc/inittab respawns getty on tty1..tty6, which
# on a headless x86 guest is the QEMU video console, not the serial line. So the serial
# log carries the kernel and everything init prints (INIT's banner, every init.d service)
# and the login prompt itself lands on the framebuffer, which the QMP screendump captures.
# The checks below therefore read the boot from the serial log and the login screen from
# the screendump.
#
# Prints PASS/FAIL lines; rc 0 only when all four checks pass. A previous run's serial
# log and screendumps are moved to build/iso-boot/prev-N/ rather than overwritten.
#
# Knobs: SUPERMOX_ISO_RAM, SUPERMOX_ISO_BOOT_TIMEOUT (the --timeout default),
# SUPERMOX_ISO_DUMP_EVERY (screendump interval), SUPERMOX_ISO_WORK (where the
# artifacts live; tests/test-vm-boot-iso.sh points it at its own directory).
set -euo pipefail

# Architecture mapping: SUPERMOX_ARCH plus the QEMU binary/console/machine helpers.
source "$(dirname "$0")/arch.sh"
# Paths: environment > config/local.env > build/ default (see docs/development.md).
source "$(dirname "$0")/local-env.sh"
# Shared pidfile/command-line lookup.
source "$(dirname "$0")/vm-pid.sh"

ISO=""
dry_run=0
timeout_s="${SUPERMOX_ISO_BOOT_TIMEOUT:-600}"
# An index loop, not "for arg in "$@"": --timeout SECONDS has to consume its value,
# and a for loop would leave "60" to be read as a second ISO argument.
args=("$@")
i=0
while [ "$i" -lt "${#args[@]}" ]; do
  arg="${args[i]}"
  case "$arg" in
    --dry-run) dry_run=1 ;;
    --timeout)
      if [ "$((i + 1))" -ge "${#args[@]}" ]; then
        printf 'ERROR: --timeout wants a value: --timeout SECONDS\n' >&2
        exit 2
      fi
      timeout_s="${args[i + 1]}"
      i=$((i + 2))
      continue
      ;;
    --timeout=*)
      timeout_s="${arg#--timeout=}"
      ;;
    -h | --help)
      printf 'usage: %s [ISO] [--dry-run] [--timeout SECONDS]\n' "$(basename "$0")"
      printf '  ISO defaults to the newest build/iso/supermox-*.iso\n'
      printf '  --dry-run prints the qemu command without booting; SUPERMOX_ISO_BOOT_TIMEOUT sets the boot timeout\n'
      exit 0
      ;;
    *)
      if [ -n "$ISO" ]; then
        printf 'ERROR: more than one ISO argument: %s and %s\n' "$ISO" "$arg" >&2
        exit 2
      fi
      ISO="$arg"
      ;;
  esac
  i=$((i + 1))
done
case "$timeout_s" in
  '' | *[!0-9]*)
    printf 'ERROR: boot timeout is not a number of seconds: %s\n' "$timeout_s" >&2
    exit 2
    ;;
esac
if [ "$timeout_s" -lt 60 ]; then
  printf 'ERROR: boot timeout too small to boot: %s s\n' "$timeout_s" >&2
  exit 2
fi

# The ISO to boot: the newest build/iso/supermox-*.iso when none was given.
if [ -z "$ISO" ]; then
  ISO="$(find "$REPO/build/iso" -maxdepth 1 -type f -name 'supermox-*.iso' -printf '%T@ %p\n' 2>/dev/null |
    sort -nr | tail -n1 | cut -d' ' -f2-)"
  if [ -z "$ISO" ]; then
    printf 'ERROR: no ISO given and none found under %s (build one with scripts/build-iso.sh)\n' "$REPO/build/iso" >&2
    exit 1
  fi
fi
if [ ! -f "$ISO" ]; then
  printf 'ERROR: no such ISO: %s\n' "$ISO" >&2
  exit 1
fi

# Everything this run reads or writes lives under build/iso-boot/ unless SUPERMOX_ISO_WORK
# moves it; tests/test-vm-boot-iso.sh uses its own directory so a fake run cannot clobber
# a real one's serial log, screendumps or squashfs cache.
WORK="$(supermox_canon_path "${SUPERMOX_ISO_WORK:-$REPO/build/iso-boot}")"
KERN="$WORK/vmlinuz"
INITRD="$WORK/initrd.img"
SERIAL="$WORK/serial.log"
QMP_SOCK="$WORK/qmp.sock"
PIDFILE="$WORK/qemu.pid"
# Created here, not at the run: live_append and the ISO proof extract files under
# $WORK before --dry-run even prints, and iso_extract cannot write into a directory
# that does not exist.
mkdir -p "$WORK"

# RAM for this guest only. SUPERMOX_VM_RAM deliberately does NOT feed it: rule 8
# exports that at 2048 for the persistent VMs, and a 2048 MB guest cannot finish
# this boot (kernel + 165 MB initrd + the live rootfs stay resident). The persistent
# VMs' default of 4096, plus rhY's desktop and this model, pushes the PC into swap,
# so the ISO boot asks for 3072; SUPERMOX_ISO_RAM overrides.
ISO_RAM="${SUPERMOX_ISO_RAM:-3072}"
VM_CPUS="${SUPERMOX_VM_CPUS:-4}"
# How often to dump the screen while waiting.
ISO_DUMP_EVERY="${SUPERMOX_ISO_DUMP_EVERY:-90}"
case "$ISO_DUMP_EVERY" in
  '' | *[!0-9]*) ISO_DUMP_EVERY=90 ;;
esac
if [ "$ISO_DUMP_EVERY" -lt 10 ]; then ISO_DUMP_EVERY=10; fi

# How long to wait for QEMU to write its pidfile after the launch. -daemonize returns
# as soon as setup succeeds, so this only bounds a QEMU that never gets there. The
# daemon child writes the pidfile just around the time the launcher exits, so a
# launcher that already died gets a few more seconds before the launch is called dead.
LAUNCH_WAIT_S=60
LAUNCH_GRACE_S=5

# --- the ISO's own root filesystem -------------------------------------------
# The live system's / is live/filesystem.squashfs inside the ISO. Listing it says
# what /sbin/init is without booting anything, which is the fallback proof when
# sysvinit's banner never reaches the serial line. Cached under build/iso-boot/:
# 7 s to copy the 1.6 GB member out, 3 s for unsquashfs -ll over 248,201 entries.
iso_init_is_sysvinit() { # $1 iso; prints the evidence, rc 1 when it cannot be had
  local iso="$1" member sq hits initline sysdline
  member="$(iso_list "$iso" 'filesystem.squashfs' | head -n1)"
  [ -n "$member" ] || return 1
  sq="$WORK/filesystem.squashfs"
  if [ ! -f "$sq" ] || [ "$iso" -nt "$sq" ]; then
    iso_extract "$iso" "$member" "$sq" || return 1
  fi
  [ -f "$sq" ] || return 1
  # unsquashfs -ll prints "<type+perms> <uid>/<gid> <size> <date> <path>" per
  # entry, so a symlink line reads "lrwxrwxrwx ... path -> target". The ISO's
  # /sbin is itself a symlink to usr/sbin, so match both spellings of init.
  hits="$(unsquashfs -ll "$sq" 2>/dev/null |
    grep -E '(^|/)(usr/)?sbin/init([[:space:]]|$| ->)|(^|/)(usr/)?lib/systemd/systemd([[:space:]]|$| ->)' || true)"
  initline="$(printf '%s\n' "$hits" | grep -m1 -E '(^|/)(usr/)?sbin/init' || true)"
  sysdline="$(printf '%s\n' "$hits" | grep -m1 -E '(^|/)(usr/)?lib/systemd/systemd' || true)"
  [ -n "$initline" ] || return 1
  case "$initline" in
  l*) return 1 ;; # /sbin/init is a symlink: not sysvinit's own binary
  *systemd*) return 1 ;; # ... or it points at systemd
  esac
  [ -z "$sysdline" ] || return 1 # the systemd binary itself is present
  printf '%s; no lib/systemd/systemd in the ISO root filesystem\n' "$initline"
}

# --- ISO readers ---------------------------------------------------------------
# 7z is the primary reader; xorriso is the fallback, so the script does not depend
# on one tool being installed.
iso_list() { # $1 iso, $2 fixed string to match in member paths; prints matches
  local iso="$1" want="$2"
  if command -v 7z >/dev/null 2>&1; then
    7z l -- "$iso" 2>/dev/null | awk '{ print $NF }' | grep -F -- "$want" || true
  elif command -v xorriso >/dev/null 2>&1; then
    xorriso -indev "$iso" -find / -print 2>/dev/null | grep -F -- "$want" || true
  else
    printf 'ERROR: need 7z or xorriso to read the ISO\n' >&2
    return 2
  fi
}

iso_extract() { # $1 iso, $2 member path, $3 destination file
  local iso="$1" path="$2" dest="$3" tmp
  tmp="$dest.part"
  if command -v 7z >/dev/null 2>&1; then
    # 7z e writes the member under its basename in the work dir; move it to $dest.
    7z e -y "-o$WORK" -- "$iso" "$path" >/dev/null 2>&1 || true
    if [ -f "$WORK/$(basename "$path")" ]; then
      mv -f "$WORK/$(basename "$path")" "$tmp"
    fi
  elif command -v xorriso >/dev/null 2>&1; then
    xorriso -indev "$iso" -osirrox:on -extract "$path" "$tmp" >/dev/null 2>&1 || true
  else
    printf 'ERROR: need 7z or xorriso to read the ISO\n' >&2
    return 2
  fi
  if [ ! -s "$tmp" ]; then
    printf 'ERROR: could not extract %s from %s\n' "$path" "$iso" >&2
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$dest"
}

# --- the kernel command line the ISO's own grub would use ----------------------
# grub.cfg's default entry (set default=N, so the (N+1)-th "linux" line) is
# "linux <kernel> <args...>". Keep everything after the kernel path, drop
# findiso=${iso_path} (a grub variable) and add console= and loglevel=.
live_append() { # $1 iso; prints the -append string
  local iso="$1" cfg line n
  cfg="$WORK/grub.cfg"
  iso_extract "$iso" "boot/grub/grub.cfg" "$cfg" || return 1
  n="$(sed -n 's/^[[:space:]]*set[[:space:]]\+default=\([0-9][0-9]*\).*/\1/p' "$cfg" | head -n1)"
  : "${n:=0}"
  line="$(grep -E '^[[:space:]]*linux[[:space:]]' "$cfg" | sed -n "$((n + 1))p")"
  if [ -z "$line" ]; then
    printf 'ERROR: no linux line for default=%s in %s/boot/grub/grub.cfg\n' "$n" "$iso" >&2
    return 1
  fi
  line="${line#*linux }" # drop "linux"
  line="${line#* }"      # drop the kernel path: the rest are the arguments
  # ${iso_path} is literal text in grub.cfg, so sed, not a bash substitution: ${...}
  # inside a ${var//.../} pattern would be expanded by bash before matching.
  line="$(printf '%s\n' "$line" | sed -E 's/[[:space:]]*findiso=\$\{iso_path\}//g')"
  printf '%s console=%s loglevel=6\n' "$line" "$(supermox_console)"
}

# --- QMP ----------------------------------------------------------------------
# QMP speaks JSON lines over the -qmp socket: read the greeting, send the commands
# in order, print each reply. One python3 call per burst.
qmp_cmd() { # $1 socket path, rest: JSON commands, in order
  local sock="$1"
  shift
  python3 - "$sock" "$@" <<'PY'
import json, socket, sys

path, *cmds = sys.argv[1:]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(20)
s.connect(path)
buf = ''
dec = json.JSONDecoder()

def recv():
    global buf
    while True:
        buf = buf.lstrip()
        if buf:
            try:
                obj, idx = dec.raw_decode(buf)
                buf = buf[idx:]
                return obj
            except json.JSONDecodeError:
                pass
        chunk = s.recv(4096)
        if not chunk:
            raise SystemExit('qmp: connection closed')
        buf += chunk.decode(errors='replace')

recv()  # the greeting
for c in cmds:
    s.sendall(c.encode() + b'\n')
    print(json.dumps(recv()))
s.close()
PY
}

# --- screendump: PPM from QMP, kept as screen-<n>.png --------------------------
dump_n=0
dump_screen() {
  local n ppm png
  n=$((dump_n + 1))
  dump_n=$n
  ppm="$WORK/screen-$n.ppm"
  png="$WORK/screen-$n.png"
  # QMP's key is "arguments": with "argument" the call gets no filename, QEMU
  # replies an error, and no screen-*.png is ever written.
  if ! qmp_cmd "$QMP_SOCK" "{\"command\":\"screendump\",\"arguments\":{\"filename\":\"$ppm\"}}" >/dev/null; then
    printf 'WARN: QMP screendump failed\n' >&2
    return 1
  fi
  if [ ! -f "$ppm" ]; then
    printf 'WARN: QMP screendump wrote no %s\n' "$ppm" >&2
    return 1
  fi
  if command -v convert >/dev/null 2>&1; then
    convert "$ppm" "$png" && rm -f "$ppm"
  elif ! python3 - "$ppm" "$png" <<'PY'
from PIL import Image
Image.open(sys.argv[1]).save(sys.argv[2])
PY
  then
    printf 'WARN: no convert or PIL to turn %s into a PNG\n' "$ppm" >&2
    return 1
  fi
  rm -f "$ppm"
  printf '%s\n' "$png"
}

# Distinct colours in an image: PIL when available; otherwise the PNG size, since
# a uniform-colour screen compresses to a tiny file and any drawn screen does not.
image_colour_count() { # $1 png; prints a count, "many", or "unreadable"
  local png="$1" n
  if [ ! -f "$png" ]; then
    printf 'unreadable\n'
    return 0
  fi
  if n="$(python3 - "$png" <<'PY' 2>/dev/null
from PIL import Image
im = Image.open(sys.argv[1]).convert('RGB')
colors = im.getcolors(maxcolors=1 << 24)
print(len(colors) if colors else -1)
PY
)"; then
    printf '%s\n' "$n"
    return 0
  fi
  if [ "$(wc -c < "$png")" -lt 2048 ]; then
    printf '1\n'
  else
    printf 'many\n'
  fi
}

# --- stopping the qemu this script started ------------------------------------
# Rule 7 is ONE VM AT A TIME, and an ISO-boot qemu that is never stopped is worse
# than a VM that is: it holds its RAM for the whole host and keeps appending to
# the same serial.log. An earlier run of this script sent power_off and quit, saw
# the process alive after 30 s, sent TERM, and finished without checking that the
# TERM worked -- the next run then read a serial log that was still being written
# while the leftover qemu still held 4 GB. So the process named by our own -pidfile
# is always stopped on the way out: QMP quit first (clean, and it flushes the
# -serial file:), TERM if it is still there, KILL after 10 s of that.
qemu_pid=""
launcher_pid=""

qemu_alive() { [ -d "/proc/${1:-}" ]; }

# A launcher job the shell has not reaped yet is a zombie, and /proc still lists a
# zombie, so "the launcher is still working" has to exclude state Z.
launcher_alive() { # $1 pid
  local st
  st="$(grep -m1 '^State:' "/proc/${1:-}/status" 2>/dev/null | cut -d' ' -f2)"
  [ -n "$st" ] && [ "$st" != Z ]
}

stop_qemu() { # $1 pid (default: the one this script started); idempotent
  local pid="${1:-$qemu_pid}" n
  [ -n "$pid" ] || return 0
  qemu_alive "$pid" || return 0
  if [ -S "$QMP_SOCK" ]; then
    qmp_cmd "$QMP_SOCK" '{"command":"quit"}' >/dev/null 2>&1 || true
    for n in $(seq 1 10); do
      qemu_alive "$pid" || return 0
      sleep 1
    done
  fi
  kill -TERM "$pid" 2>/dev/null || true
  for n in $(seq 1 10); do
    qemu_alive "$pid" || return 0
    sleep 1
  done
  printf 'WARN: qemu pid %s survived QMP quit and TERM; sending KILL\n' "$pid" >&2
  kill -KILL "$pid" 2>/dev/null || true
  return 0
}

cleanup() {
  trap - EXIT INT TERM
  stop_qemu
  if launcher_alive "$launcher_pid"; then
    stop_qemu "$launcher_pid"
  fi
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# --- never start a second instance, and stop a running VM first ----------------
# The pidfile is the authority, and QEMU unlinks it when it exits, so a live process
# whose pidfile is gone is found by its command line as well (the vm-pid.sh idea).
# A previous run's qemu is stopped with the same stop_qemu the EXIT trap uses, not
# left for the operator to find: that leftover process is what exhausted host RAM.
expected_comm="$(supermox_qemu_comm)"
own_pid="$(supermox_find_qemu_pid "$PIDFILE" "$expected_comm" || true)"
if [ -n "$own_pid" ]; then
  printf 'a previous ISO-boot qemu is still running (pid %s, -pidfile %s); stopping it\n' "$own_pid" "$PIDFILE" >&2
  stop_qemu "$own_pid"
  if qemu_alive "$own_pid"; then
    printf 'ERROR: could not stop pid %s; refusing to start a second qemu\n' "$own_pid" >&2
    exit 1
  fi
fi

# A persistent SuperMox VM and an ISO boot at the same time push this PC into swap
# (two 4 GB guests on a 31 GB host, observed while developing this script), and the
# ISO's live system expects QEMU user-mode networking, so stop the VM before booting.
if [ "$dry_run" -eq 0 ]; then
  vm_pid="$(supermox_find_qemu_pid "$(supermox_canon_path "$SUPERMOX_VM_DIR")/qemu.pid" "$expected_comm" || true)"
  if [ -n "$vm_pid" ]; then
    printf 'A SuperMox VM is running (pid %s); stopping it before booting the ISO.\n' "$vm_pid"
    bash "$(dirname "$0")/vm-stop.sh" || true
  fi
fi

# --- build the command ---------------------------------------------------------
qemu_bin="$(supermox_qemu_bin)"
if ! command -v "$qemu_bin" >/dev/null 2>&1; then
  printf 'ERROR: %s is not installed\n' "$qemu_bin" >&2
  exit 1
fi

mapfile -t mach_opts < <(supermox_machine_opts)
append="$(live_append "$ISO")"

# KVM only when the guest architecture is the host's and /dev/kvm is usable;
# otherwise plain QEMU emulation (same rule as scripts/vm-start.sh).
host_arch="$(dpkg --print-architecture)"
if [ "$SUPERMOX_ARCH" = "$host_arch" ] && [ -e /dev/kvm ]; then
  kvm_opts=(-enable-kvm -cpu host)
else
  printf 'NOTE: no native KVM for arch %s on this %s host: using -cpu max (slow).\n' "$SUPERMOX_ARCH" "$host_arch" >&2
  kvm_opts=(-cpu max)
fi

cmd=(
  "$qemu_bin"
  "${mach_opts[@]}"
  "${kvm_opts[@]}"
  -m "$ISO_RAM"
  -smp "$VM_CPUS"
  -no-reboot
  -cdrom "$ISO"
  -kernel "$KERN"
  -initrd "$INITRD"
  -append "$append"
  # The ISO's live system expects QEMU user-mode networking (its supermox-hosts
  # script maps the node name to 10.0.2.15). No hostfwd: nothing here is reachable.
  # The quotes keep the element as one argv word and keep shellcheck's SC2054
  # quiet: it is the comma, not the quoting, that makes a bare array element look
  # like several.
  -nic "user,model=virtio-net-pci"
  -display none
  -serial "file:$SERIAL"
  -qmp "unix:$QMP_SOCK,server,nowait"
  -daemonize
  -pidfile "$PIDFILE"
)

print_cmd() {
  local line="" a
  for a in "$@"; do
    case "$a" in
      *[[:space:]]*) line+="\"$a\" " ;;
      *) line+="$a " ;;
    esac
  done
  printf '%s\n' "$line"
}

if [ "$dry_run" -eq 1 ]; then
  printf 'ISO: %s\n' "$ISO"
  printf '# kernel and initrd come out of the ISO at run time: live/vmlinuz* -> %s, live/initrd.img* -> %s\n' "$KERN" "$INITRD"
  printf '# boot timeout: %s s; screendump every %s s; serial log: %s\n' "$timeout_s" "$ISO_DUMP_EVERY" "$SERIAL"
  print_cmd "${cmd[@]}"
  exit 0
fi

# --- run -----------------------------------------------------------------------
mkdir -p "$WORK"
# Move a previous run's artifacts aside instead of overwriting them.
prev_needed=0
if [ -e "$SERIAL" ] || ls "$WORK"/screen-*.png >/dev/null 2>&1; then
  prev_needed=1
fi
if [ "$prev_needed" -eq 1 ]; then
  prev_n=1
  while [ -e "$WORK/prev-$prev_n" ]; do prev_n=$((prev_n + 1)); done
  mkdir -p "$WORK/prev-$prev_n"
  find "$WORK" -maxdepth 1 \( -name 'serial*.log' -o -name 'screen-*.png' \) \
    -exec mv -f -- '{}' "$WORK/prev-$prev_n/" \; 2>/dev/null || true
  printf 'Archived the previous run under %s/prev-%s\n' "$WORK" "$prev_n"
fi
rm -f "$QMP_SOCK"

# Extract the kernel and initrd unless a previous run already extracted them from
# this same ISO (the ISO is 1.8 GB, so re-extracting is worth avoiding).
kern_member="$(iso_list "$ISO" "live/vmlinuz" | head -n1)"
initrd_member="$(iso_list "$ISO" "live/initrd.img" | head -n1)"
if [ -z "$kern_member" ] || [ -z "$initrd_member" ]; then
  printf 'ERROR: the ISO has no live/vmlinuz or live/initrd.img: %s\n' "$ISO" >&2
  exit 1
fi
printf 'ISO kernel: %s\nISO initrd: %s\n' "$kern_member" "$initrd_member"
for pair in "$kern_member:$KERN" "$initrd_member:$INITRD"; do
  member="${pair%%:*}"
  dest="${pair#*:}"
  if [ -f "$dest" ] && [ "$dest" -nt "$ISO" ]; then
    printf 'Reusing %s (newer than the ISO)\n' "$dest"
  else
    iso_extract "$ISO" "$member" "$dest"
    printf 'Extracted %s -> %s\n' "$member" "$dest"
  fi
done

printf 'Starting headless ISO boot (timeout %s s, serial log %s)\n' "$timeout_s" "$SERIAL"
print_cmd "${cmd[@]}"
# -daemonize makes QEMU fork once its setup succeeds, so the command below returns
# by itself -- but only if QEMU honours it. Run it as a job: a QEMU that stays in
# the foreground, or blocks in setup, then cannot hold this script past its own
# timeout, and the EXIT trap can still stop it. When QEMU does daemonise the pidfile
# names the real process; when it does not, the job's own pid does.
"${cmd[@]}" &
launcher_pid=$!
qemu_pid="$launcher_pid"
pid=""
n=0
grace=0
while [ "$n" -lt "$LAUNCH_WAIT_S" ]; do
  if [ -f "$PIDFILE" ]; then
    pid="$(tr -dc '0-9' < "$PIDFILE" 2>/dev/null || true)"
    if [ -n "$pid" ]; then break; fi
  fi
  if launcher_alive "$launcher_pid"; then
    grace=0
  else
    grace=$((grace + 1))
    if [ "$grace" -gt "$LAUNCH_GRACE_S" ]; then break; fi
  fi
  sleep 1
  n=$((n + 1))
done
if [ -z "$pid" ]; then
  if launcher_alive "$launcher_pid"; then
    printf 'ERROR: qemu ran %s s without writing %s\n' "$LAUNCH_WAIT_S" "$PIDFILE" >&2
    stop_qemu "$launcher_pid"
  else
    printf 'ERROR: qemu failed to start: it exited without writing %s\n' "$PIDFILE" >&2
  fi
  wait "$launcher_pid" 2>/dev/null || true
  exit 1
fi
printf 'qemu pid: %s\n' "$pid"

# The end of the multi-user boot: the ISO's last rc2.d services, sysvinit's
# startpar summary, or a login prompt on the serial line (only if an inittab ever
# puts a getty on the serial console).
BOOT_DONE_RE='startpar: service|Starting pvescheduler|Starting pve-guests|Starting spiceproxy|Starting pve-ha-lrm|login:'
# Fallback for a changed service set: the boot is over once the serial log has
# stopped growing for a while and enough services have started.
SETTLE_S=30
MIN_SERVICE_STARTS=10

t0=$SECONDS
elapsed=0
done_reason=""
size=0
quiet_since=$SECONDS
dump_at=$ISO_DUMP_EVERY
while :; do
  sleep 5
  elapsed=$((SECONDS - t0))
  if [ ! -d "/proc/$pid" ]; then
    done_reason="qemu exited on its own after $elapsed s"
    break
  fi
  if [ "$elapsed" -ge "$timeout_s" ]; then
    done_reason="no completed boot within $timeout_s s"
    break
  fi
  if [ "$elapsed" -lt "$timeout_s" ] && [ "$elapsed" -ge "$dump_at" ]; then
    dump_at=$((dump_at + ISO_DUMP_EVERY))
    dump_screen || true
  fi
  if grep -qE "$BOOT_DONE_RE" "$SERIAL" 2>/dev/null; then
    done_reason="the multi-user boot finished"
    break
  fi
  new_size="$(wc -c < "$SERIAL" 2>/dev/null || printf '0\n')"
  if [ "$new_size" != "$size" ]; then
    size="$new_size"
    quiet_since=$SECONDS
  elif [ $((SECONDS - quiet_since)) -ge "$SETTLE_S" ] &&
    [ "$(grep -cE '^[[:space:]]*Starting ' "$SERIAL" 2>/dev/null || true)" -ge "$MIN_SERVICE_STARTS" ]; then
    done_reason="the serial log stopped growing after $SETTLE_S s"
    break
  fi
done
printf '%s\n' "${done_reason:-wait ended}"

# The last screendump shows the screen at the moment the decision was made.
dump_screen || true

# Power off through QMP, then stop the process for good with stop_qemu (quit, TERM,
# KILL after 10 s) and wait for it to exit: the checks below must read a serial log
# that is finished being written, and nothing may survive this script.
qmp_cmd "$QMP_SOCK" '{"command":"power_off"}' >/dev/null 2>&1 || true
qemu_pid="$pid"
stop_qemu "$pid"
# Nothing of this run may survive: when QEMU did not daemonise the job above IS the
# process (already stopped by now), when it did the launcher exited at once and only
# needs reaping.
if launcher_alive "$launcher_pid"; then
  stop_qemu "$launcher_pid"
fi
wait "$launcher_pid" 2>/dev/null || true

# --- checks -------------------------------------------------------------------
fail=0
report() { # $1 name, $2 0 = pass, $3 detail
  if [ "$2" -eq 0 ]; then
    printf 'PASS: %s (%s)\n' "$1" "$3"
  else
    printf 'FAIL: %s (%s)\n' "$1" "$3"
    fail=$((fail + 1))
  fi
}

# 1. the kernel booted.
kline="$(grep -m1 -F 'Linux version ' "$SERIAL" 2>/dev/null || true)"
if [ -n "$kline" ]; then
  report 'kernel booted' 0 "$kline"
else
  report 'kernel booted' 1 "no \"Linux version\" line in $SERIAL"
fi

# 2. init is sysvinit. Two proofs, and the report says which one was used.
#   A: the serial banner. Devuan's sysvinit prints "INIT: version ..." on
#   /dev/console, and this guest's console is the QEMU framebuffer rather than
#   the serial line, so proof A is usually absent from the serial log.
#   B: the ISO's own root filesystem: /sbin/init inside live/filesystem.squashfs
#   is a regular file rather than a symlink into systemd, and lib/systemd/systemd
#   does not exist there, so init cannot be systemd. Cost: 7 s to copy the 1.6 GB
#   member out into build/iso-boot/ (cached, reused when newer than the ISO) and
#   3 s for unsquashfs -ll over its 248,201 entries.
# systemd-tmpfiles appears in this boot as a helper binary SuperMox ships; that is
# not systemd running the system, so it must not fail this check.
initline="$(grep -m1 -E 'INIT:[[:space:]]+version' "$SERIAL" 2>/dev/null || true)"
sysdline="$(grep -m1 -E 'systemd\[1\]|Welcome to systemd|Running systemd' "$SERIAL" 2>/dev/null || true)"
if [ -n "$initline" ] && [ -z "$sysdline" ]; then
  report 'init is sysvinit' 0 "serial banner: $initline"
else
  iso_proof="$(iso_init_is_sysvinit "$ISO")" || iso_proof=""
  if [ -n "$iso_proof" ] && [ -z "$sysdline" ]; then
    report 'init is sysvinit' 0 "ISO root filesystem: $iso_proof"
  else
    report 'init is sysvinit' 1 "init banner: ${initline:-none}; ISO proof: ${iso_proof:-not available}"
  fi
fi

# 3. the boot reached the login stage: every init.d service of runlevel 2 ran.
ready="$(grep -m1 -E "$BOOT_DONE_RE" "$SERIAL" 2>/dev/null || true)"
starts="$(grep -cE '^[[:space:]]*Starting ' "$SERIAL" 2>/dev/null || true)"
if [ -n "$ready" ] || [ "$starts" -ge "$MIN_SERVICE_STARTS" ]; then
  if [ -n "$ready" ]; then
    report 'boot reached the login stage' 0 "$starts services started; last: $ready"
  else
    report 'boot reached the login stage' 0 "$starts services started, serial log settled"
  fi
else
  report 'boot reached the login stage' 1 "only $starts service starts in $SERIAL"
fi

# 4. the last screendump is not one uniform colour: a black screen means nothing drew.
last_png=""
for f in "$WORK"/screen-*.png; do
  if [ -f "$f" ]; then
    last_png="$f"
  fi
done
if [ -z "$last_png" ]; then
  report 'login screen drawn on the guest console' 1 "no $WORK/screen-*.png"
else
  colours="$(image_colour_count "$last_png")"
  case "$colours" in
    many) report 'login screen drawn on the guest console' 0 "$last_png has many colours" ;;
    '' | 0 | 1 | unreadable) report 'login screen drawn on the guest console' 1 "$last_png is one colour ($colours)" ;;
    *) report 'login screen drawn on the guest console' 0 "$last_png has $colours distinct colours" ;;
  esac
fi

printf 'Elapsed: %s s\nSerial log: %s\nScreendumps: %s\n' "$elapsed" "$SERIAL" "$WORK"
if [ "$fail" -ne 0 ]; then
  printf 'Last 20 lines of %s:\n' "$SERIAL"
  tail -n 20 "$SERIAL" || true
  exit 1
fi
exit 0
