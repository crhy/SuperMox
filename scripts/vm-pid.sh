#!/usr/bin/env bash
# Sourced by vm-start.sh and vm-stop.sh; never run directly.
#
# Which qemu process belongs to a VM_DIR, found from its command line.
#
# The pidfile cannot be trusted on its own: QEMU unlinks its -pidfile when it exits,
# so an instance that is still shutting down deletes the pidfile a NEW instance with
# the same VM_DIR has just written. vm-stop.sh then saw "No pidfile" and did nothing
# while a VM kept running (observed 3 times on 2026-11-04; two VMs at once pushed this
# PC into swap). vm-status.sh already finds VMs by command line; this file is the
# shared version of that idea.
#
# vm-start.sh always passes "-pidfile <VM_DIR>/qemu.pid" with VM_DIR canonicalised to
# an absolute path, so matching that exact string identifies the process of one VM_DIR
# and never the other VM's (a different directory cannot contain this path).
# pgrep -x keeps the comm safety check: only a process whose /proc/<pid>/comm is
# exactly supermox_qemu_comm for SUPERMOX_ARCH is ever a candidate.

# Canonical absolute path of a file, for matching against a cmdline argument.
# readlink -f fails (prints nothing) when a path component does not exist, which
# happens for a VM_DIR that was never created or a pidfile QEMU already unlinked,
# so fall back to readlink -m: same canonicalisation, nothing has to exist.
supermox_canon_path() {
  local p canon
  p="$1"
  canon="$(readlink -f -- "$p" 2>/dev/null || true)"
  if [ -z "$canon" ]; then
    canon="$(readlink -m -- "$p")"
  fi
  printf '%s\n' "$canon"
}

# Print the pid of the qemu process whose command line contains "-pidfile <want>"
# (or "-pidfile=<want>"), else print nothing and return 1.
# Args: $1 canonical pidfile path, $2 expected process comm.
supermox_find_qemu_pid() {
  local want="$1" comm="$2" pid cmd
  while IFS= read -r pid; do
    [ -r "/proc/$pid/cmdline" ] || continue
    # NUL -> space, plus a trailing space so the path match is bounded on both sides.
    cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline") "
    case "$cmd" in
      *" -pidfile $want "* | *" -pidfile=$want "*)
        printf '%s\n' "$pid"
        return 0
        ;;
    esac
  done < <(pgrep -x "$comm" || true)
  return 1
}
