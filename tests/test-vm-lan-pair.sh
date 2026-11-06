#!/usr/bin/env bash
# Offline gate test for the two-node LAN pair harness (scripts/vm-lan-pair.sh).
#
# It never boots the pair: this PC cannot hold Strata plus two VMs, so the gate
# asserts the WIRING from --dry-run output instead. Everything that decides whether
# two real nodes can see each other is visible there: the qcow2 overlays and their
# read-only base, the shared mcast netdev on BOTH VMs, distinct MACs, distinct ssh
# forwards, the RAM budget, and the KVM choice. What --dry-run cannot prove (packets
# crossing the LAN) is scripts/lan-pair-check.sh's job on a machine that can run the
# pair.
set -euo pipefail

cd "$(dirname "$0")/.."

# The assertions below are about the script's own defaults, so the caller's
# SUPERMOX_* environment must not leak in (config/local.env points SUPERMOX_TEST_DIR
# at a data disk on some machines). Unset every SUPERMOX_* variable first, the way
# tests/test-vm-scripts.sh and tests/test-local-env.sh do.
while IFS= read -r _smx_var; do
  unset "$_smx_var"
done < <(compgen -e | grep -E '^SUPERMOX_[A-Za-z_][A-Za-z0-9_]*$')
unset _smx_var

# A scratch test dir inside build/: nothing is created by --dry-run, and the one
# command that could touch a running qemu (`stop`) is pointed here, so a live pair
# elsewhere can never be stopped by this test.
TEST_DIR="$PWD/build/test-lan-pair"
export SUPERMOX_TEST_DIR="$TEST_DIR"

pair="scripts/vm-lan-pair.sh"
status="scripts/vm-status.sh"
check="scripts/lan-pair-check.sh"

fail=0
ok() { printf 'OK: %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1" >&2; fail=1; }

for f in "$pair" "$status" "$check"; do
  if [ ! -f "$f" ]; then
    bad "$f does not exist"
    exit 1
  fi
done

# --- dry-run of start ---------------------------------------------------------
out="$(SUPERMOX_ARCH=amd64 bash "$pair" --dry-run start)"

# Two qemu command lines and two overlay creations: one pair, not one VM.
qemu_lines="$(printf '%s\n' "$out" | grep -c '^[[:space:]]*qemu-system-')"
[ "$qemu_lines" -eq 2 ] || bad "expected 2 qemu command lines, got $qemu_lines"
ovl_lines="$(printf '%s\n' "$out" | grep -c 'qemu-img create -f qcow2 -b ')"
[ "$ovl_lines" -eq 2 ] || bad "expected 2 overlay creations, got $ovl_lines"

line_a="$(printf '%s\n' "$out" | grep 'qemu-system-' | sed -n 1p)"
line_b="$(printf '%s\n' "$out" | grep 'qemu-system-' | sed -n 2p)"

# The base image is the installed test rootfs; it must only ever appear as the
# -b base of an overlay, never as a -drive. Otherwise both VMs would write to the
# image vm-test-install.sh built and the second node would start from the first
# node's changes.
if printf '%s\n' "$out" | grep -qF -- "-drive file=$TEST_DIR/rootfs.img"; then
  bad "the base test image is mounted writable by a VM"
fi
for side in a b; do
  if ! printf '%s\n' "$out" | grep -qF -- \
    "qemu-img create -f qcow2 -b $TEST_DIR/rootfs.img -F raw $TEST_DIR/lan-pair/smx-$side.img"; then
    bad "no 'qemu-img create -f qcow2 -b <base> -F raw' overlay for smx-$side"
  fi
  if ! printf '%s\n' "$out" | grep -qF -- \
    "-drive file=$TEST_DIR/lan-pair/smx-$side.img,format=qcow2,if=virtio"; then
    bad "smx-$side overlay is not mounted as a qcow2 virtio drive"
  fi
done

# NIC 2: one shared user-LAN on BOTH VMs. A second -nic user= would give each VM
# its own private 10.0.2.x net, which is exactly the fake join-e2e.sh avoids by
# using namespaces; mcast is what makes the two VMs neighbours.
for line in "$line_a" "$line_b"; do
  printf '%s\n' "$line" | grep -qF -- '-netdev socket,id=lan,mcast=230.0.0.1:12345' \
    || bad 'a VM is missing "-netdev socket,id=lan,mcast=230.0.0.1:12345"'
  printf '%s\n' "$line" | grep -qF -- '-device virtio-net-pci,netdev=lan,mac=' \
    || bad 'a VM has no guest device attached to the lan netdev'
  # NIC 1 keeps the ssh forward on the user stack.
  printf '%s\n' "$line" | grep -qF -- '-nic user,model=virtio-net-pci,hostfwd=' \
    || bad 'a VM is missing the user-net NIC with a hostfwd'
done

ok 'both VMs attach a guest device to one shared mcast netdev and keep a user-net ssh NIC'

# Distinct MACs, and the two the task asks for. Both nodes sit on one LAN, so
# duplicate MACs would make the second node's link-local and DHCP state collide.
printf '%s\n' "$line_a" | grep -qF -- 'mac=52:54:00:12:00:0A' || bad 'A does not use MAC ...:0A'
printf '%s\n' "$line_b" | grep -qF -- 'mac=52:54:00:12:00:0B' || bad 'B does not use MAC ...:0B'
for line in "$line_a" "$line_b"; do
  macs="$(printf '%s\n' "$line" | grep -o 'mac=[0-9:]*' | sort -u | wc -l)"
  [ "$macs" -eq 1 ] || bad "a VM line carries $macs different MACs"
done

ok 'the two nodes use distinct MACs ...:0A and ...:0B'

# Distinct ssh forwards: one port per node, and neither node's port reused.
printf '%s\n' "$line_a" | grep -qF -- 'hostfwd=tcp:127.0.0.1:2231-:22' || bad 'A does not forward 2231'
printf '%s\n' "$line_b" | grep -qF -- 'hostfwd=tcp:127.0.0.1:2232-:22' || bad 'B does not forward 2232'
if printf '%s\n' "$line_a" | grep -qF -- '2232-:22'; then
  bad 'A also forwards B'\''s port'
fi
if printf '%s\n' "$line_b" | grep -qF -- '2231-:22'; then
  bad 'B also forwards A'\''s port'
fi
# The pair must not sit on the single test VM's port either: two forwards on one
# host port means one node's sshd answers for both, and a join test then reads one
# node twice while believing it read two.
if printf '%s\n' "$out" | grep -qF -- 'hostfwd=tcp:127.0.0.1:2224-:22'; then
  bad 'the pair reuses the test VM ssh port 2224'
fi

ok 'the nodes forward distinct ssh ports 2231 and 2232, and not the test VM port 2224'

# RAM: two VMs at vm-start.sh's 4096 MB do not fit beside Strata, so the pair
# defaults to 1536 and the knob is SUPERMOX_LAN_RAM.
for line in "$line_a" "$line_b"; do
  printf '%s\n' "$line" | grep -qF -- '-m 1536' || bad 'a VM is not at the 1536 MB default'
done
small="$(SUPERMOX_LAN_RAM=512 bash "$pair" --dry-run start)"
printf '%s\n' "$small" | grep -qF -- '-m 512' || bad 'SUPERMOX_LAN_RAM=512 did not change -m'
if printf '%s\n' "$small" | grep -qF -- '-m 1536'; then
  bad 'SUPERMOX_LAN_RAM=512 still printed 1536'
fi
ok 'both VMs default to 1536 MB and SUPERMOX_LAN_RAM changes it'

# KVM, the same way vm-start.sh decides: native arch plus /dev/kvm means
# -enable-kvm -cpu host, anything else means -cpu max (TCG emulation).
host_arch="$(dpkg --print-architecture)"
if [ "$host_arch" = amd64 ] && [ -e /dev/kvm ]; then
  for line in "$line_a" "$line_b"; do
    printf '%s\n' "$line" | grep -qF -- '-enable-kvm -cpu host' \
      || bad 'amd64 pair on a KVM host is not using -enable-kvm -cpu host'
  done
else
  printf 'NOTE: no native KVM for amd64 on this %s host: checking the emulated path instead.\n' "$host_arch"
fi
# SuperMox is architecture-neutral: the pair has to work for arm64 too, which
# needs the virt machine, the aarch64 emulator and no KVM.
arm_out="$(SUPERMOX_ARCH=arm64 bash "$pair" --dry-run start)"
printf '%s\n' "$arm_out" | grep -qF -- 'qemu-system-aarch64 -M virt' \
  || bad 'the arm64 pair does not use qemu-system-aarch64 -M virt'
if printf '%s\n' "$arm_out" | grep -qF -- '"-M virt"'; then
  bad 'the arm64 pair passes -M virt as one argv entry (qemu: invalid option)'
fi
printf '%s\n' "$arm_out" | grep -qF -- '-cpu max' || bad 'the arm64 pair does not use -cpu max'
if printf '%s\n' "$arm_out" | grep -qF -- '-enable-kvm'; then
  bad 'the arm64 pair enables KVM on an amd64 host'
fi
printf '%s\n' "$arm_out" | grep -qF -- 'console=ttyAMA0' || bad 'the arm64 pair uses the amd64 console'
ok 'the arm64 pair uses qemu-system-aarch64 -M virt -cpu max with no KVM'

# pidfiles under the pair dir: `stop` finds the processes through these paths,
# and vm-status.sh reports the pair from them.
for side in a b; do
  printf '%s\n' "$out" | grep -qF -- "-pidfile $TEST_DIR/lan-pair/qemu-$side.pid" \
    || bad "no pidfile under lan-pair/ for smx-$side"
done
ok 'both VMs keep their pidfile under the pair dir'

ok 'two qcow2 overlays are created from the test rootfs and only the overlays are mounted'

# Hostnames and LAN addresses: two nodes called "supermox" are indistinguishable
# to pmxcfs, to the join protocol and to a log reader.
printf '%s\n' "$out" | grep -qF -- 'smx-a=192.168.77.10' || bad 'no smx-a -> 192.168.77.10 mapping'
printf '%s\n' "$out" | grep -qF -- 'smx-b=192.168.77.11' || bad 'no smx-b -> 192.168.77.11 mapping'

# --dry-run must create nothing: no pair dir, no overlay.
if [ -e "$TEST_DIR/lan-pair" ]; then
  bad "--dry-run created $TEST_DIR/lan-pair"
fi
ok '--dry-run boots nothing and creates nothing'

# --- subcommands --------------------------------------------------------------
usage="$(bash "$pair" --help 2>&1)"
for word in start configure status ssh stop; do
  printf '%s\n' "$usage" | grep -qF -- "$word" || bad "usage does not document $word"
done
if bash "$pair" bogus >/dev/null 2>&1; then
  bad 'an unknown command exits 0'
fi
if bash "$pair" ssh >/dev/null 2>&1; then
  bad 'ssh without a side exits 0'
fi
if bash "$pair" ssh C true >/dev/null 2>&1; then
  bad 'ssh accepts a side that is not A or B'
fi

# stop with nothing running: exits 0 and reports BOTH sides, because a half-stopped
# pair holds its RAM and keeps the mcast socket bound for nobody. SUPERMOX_TEST_DIR
# points at build/test-lan-pair, so this cannot stop a live pair elsewhere.
stop_out="$(bash "$pair" stop 2>&1)"
printf '%s\n' "$stop_out" | grep -qF 'A VM: not running' || bad 'stop does not report side A'
printf '%s\n' "$stop_out" | grep -qF 'B VM: not running' || bad 'stop does not report side B'
ok 'stop reports both sides, so a half-stopped pair cannot keep its RAM'

# --- vm-status.sh sees the pair (rule 7 needs it) -----------------------------
# No VM may be booted by the gate, so this is a static check of the branches: the
# pair's command line contains the test dir, so without a branch of its own the
# pair is reported as the single test VM with the wrong ssh port.
for pat in 'lan-pair A' 'lan-pair B' 'SUPERMOX_LAN_SSH_A' 'SUPERMOX_LAN_SSH_B'; do
  grep -qF -- "$pat" "$status" || bad "vm-status.sh does not report the pair ($pat)"
done
# The pair branch must be matched before the test VM branch, or it never runs.
pair_at="$(grep -n 'lan-pair/qemu-a.pid' "$status" | cut -d: -f1 | head -n1)"
test_at="$(grep -n 'test-data' "$status" | cut -d: -f1 | head -n1)"
if [ -z "$pair_at" ] || [ -z "$test_at" ] || [ "$pair_at" -ge "$test_at" ]; then
  bad 'vm-status.sh matches the pair after the test VM'
fi
ok 'vm-status.sh reports lan-pair A and lan-pair B before the single test VM'

# --- lan-pair-check.sh agrees with the harness -------------------------------
# Two files that disagree about an address or a port make the check ping a node
# that does not exist, and a failed LAN then looks like a working one.
for var in SUPERMOX_LAN_SSH_A SUPERMOX_LAN_SSH_B SUPERMOX_LAN_IP_A SUPERMOX_LAN_IP_B SUPERMOX_LAN_MCAST SUPERMOX_LAN_NET; do
  grep -qF -- "$var" "$check" || bad "lan-pair-check.sh does not read $var"
done
for def in '2231' '2232' '192.168.77.10' '192.168.77.11' '230.0.0.1:12345'; do
  grep -qF -- "$def" "$check" || bad "lan-pair-check.sh is missing the default $def"
done
# The proof itself: both directions, and the interface dump.
grep -qF -- 'ip -br a' "$check" || bad 'lan-pair-check.sh does not print ip -br a'
grep -qE -- 'ping.*\$IP_B' "$check" || bad 'lan-pair-check.sh does not ping B from A'
grep -qE -- 'ping.*\$IP_A' "$check" || bad 'lan-pair-check.sh does not ping A from B'
ok 'lan-pair-check.sh pings both directions and agrees with the harness defaults'

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "All lan-pair checks passed."
