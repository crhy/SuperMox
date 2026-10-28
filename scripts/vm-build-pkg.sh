#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
vm_ssh="$repo_root/scripts/vm-ssh.sh"
VM_DIR="${SUPERMOX_VM_DIR:-/media/rhy/data/supermox-vm}"
VM_SSH_PORT="${SUPERMOX_VM_SSH_PORT:-2223}"

ssh_opts=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=10
)

dry_run=0
component=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=1 ;;
    *) component="$arg" ;;
  esac
done

if [ -z "$component" ]; then
  printf 'usage: %s [--dry-run] <component>\n' "${0##*/}" >&2
  exit 2
fi

remote() {
  bash "$vm_ssh" "$@"
}

read_subdirs() {
  local comp="$1"
  local file="$repo_root/config/build-subdirs.txt"
  local line rest
  local -a words
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    if [ "${line%% *}" = "$comp" ]; then
      rest="${line#* }"
      [ "$rest" = "$line" ] && continue
      read -ra words <<< "$rest"
      for _w in "${words[@]}"; do
        printf '%s\n' "$_w"
      done
    fi
  done < "$file"
}

subdirs=()
while IFS= read -r _s; do
  [ -n "$_s" ] && subdirs+=("$_s")
done < <(read_subdirs "$component")

build_dirs=()
if [ "${#subdirs[@]}" -gt 0 ]; then
  for _s in "${subdirs[@]}"; do
    build_dirs+=("$component/$_s")
  done
else
  build_dirs=("$component")
fi

copy_debs_back() {
  mkdir -p "$VM_DIR/debs"
  while IFS= read -r deb; do
    [ -n "$deb" ] || continue
    sshpass -p supermox scp -P "$VM_SSH_PORT" "${ssh_opts[@]}" \
      "root@127.0.0.1:$deb" "$VM_DIR/debs/"
  done < <(remote "find /root/localrepo -maxdepth 1 -type f -name '*.deb'")
}

if [ "$dry_run" -eq 1 ]; then
  printf 'DRY-RUN: build %s (no VM changes)\n' "$component"
  printf '  rm -rf build/patched && scripts/apply-patches.sh build/patched\n'
  printf '  tar -C build/patched/%s/%s -cf - . | scripts/vm-ssh.sh "rm -rf /root/build/%s && mkdir -p /root/build/%s && tar -C /root/build/%s -xf -"\n' "$component" "$component" "$component" "$component" "$component"
  if [ "${#subdirs[@]}" -gt 0 ]; then
    for _s in "${subdirs[@]}"; do
      printf '  in VM /root/build/%s/%s: apt-get update\n' "$component" "$_s"
      printf '  in VM /root/build/%s/%s: mk-build-deps --install --remove --tool "apt-get -y --no-install-recommends" debian/control\n' "$component" "$_s"
      printf '  in VM /root/build/%s/%s: make deb (if Makefile has deb: target) else dpkg-buildpackage -b -us -uc\n' "$component" "$_s"
      printf '  copy *.deb to /root/localrepo, dpkg-scanpackages . > Packages, apt-get update\n'
    done
  else
    printf '  in VM /root/build/%s: apt-get update\n' "$component"
    printf '  in VM /root/build/%s: mk-build-deps --install --remove --tool "apt-get -y --no-install-recommends" debian/control\n' "$component"
    printf '  in VM /root/build/%s: make deb (if Makefile has deb: target) else dpkg-buildpackage -b -us -uc\n' "$component"
    printf '  copy *.deb to /root/localrepo and run dpkg-scanpackages . > Packages\n'
  fi
  printf '  scp new *.deb from /root/localrepo to %s/debs/\n' "$VM_DIR"
  printf '  log to build/logs/%s.log\n' "$component"
  exit 0
fi

if ! command -v sshpass >/dev/null 2>&1; then
  printf 'ERROR: sshpass is not installed\n' >&2
  exit 1
fi

src_dir="$repo_root/build/patched/$component/$component"
log="$repo_root/build/logs/$component.log"
mkdir -p "$repo_root/build/logs"

rm -rf "$repo_root/build/patched"
if ! "$repo_root/scripts/apply-patches.sh" "$repo_root/build/patched" >"$log" 2>&1; then
  printf 'FAIL: apply-patches.sh\n' >&2
  tail -n 30 "$log" >&2
  exit 1
fi

if [ ! -d "$src_dir" ]; then
  printf 'ERROR: no patched source for component: %s\n' "$component" >&2
  exit 1
fi

if ! {
  printf '\n=== copy source to VM ===\n'
  tar -C "$repo_root/build/patched/$component/$component" -cf - . |
    bash "$vm_ssh" "rm -rf /root/build/$component && mkdir -p /root/build/$component && tar -C /root/build/$component -xf -"

  printf '\n=== build in VM ===\n'
  {
    printf 'dirs=('
    for _d in "${build_dirs[@]}"; do
      printf '%q ' "$_d"
    done
    printf ')\n'
    cat <<'REMOTE'
set -e
export DEBIAN_FRONTEND=noninteractive DEBEMAIL='root@localhost' DEBFULLNAME='SuperMox'
for p in $(dpkg -l '*-build-deps' 2>/dev/null | awk '/^i/{print $2}'); do
  dpkg --remove --force-remove-reinstreq "$p" 2>/dev/null || true
done
apt-get -y -f install >/dev/null 2>&1 || true
for d in "${dirs[@]}"; do
  apt-get update >/dev/null 2>&1 || true
  cd "/root/build/$d"
  mk-build-deps --install --remove --tool 'apt-get -y --no-install-recommends' debian/control
  if grep -qE '^deb:' Makefile; then
    make deb || true
  else
    dpkg-buildpackage -b -us -uc
  fi
  if ! ls ./*.deb .././*.deb >/dev/null 2>&1; then
    echo "ERROR: no .deb produced in $d" >&2
    exit 1
  fi
  cp ./*.deb /root/localrepo/ 2>/dev/null || true
  cp .././*.deb /root/localrepo/ 2>/dev/null || true
  cd /root/localrepo && dpkg-scanpackages . > Packages 2>/dev/null
  apt-get update >/dev/null 2>&1 || true
done
chmod o+x /root 2>/dev/null || true
chmod 644 /root/localrepo/*.deb 2>/dev/null || true
chmod 644 /root/localrepo/Packages 2>/dev/null || true
REMOTE
  } | bash "$vm_ssh" "bash -s"
} >>"$log" 2>&1; then
  printf 'FAIL: build %s\n' "$component" >&2
  tail -n 30 "$log" >&2
  exit 1
fi

if ! copy_debs_back; then
  printf 'FAIL: copy debs back for %s\n' "$component" >&2
  tail -n 30 "$log" >&2
  exit 1
fi

printf 'OK: built %s; debs in %s/debs/ and /root/localrepo\n' "$component" "$VM_DIR"
