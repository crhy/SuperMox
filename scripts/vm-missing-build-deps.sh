#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
vm_ssh="$repo_root/scripts/vm-ssh.sh"

component="${1:-}"
if [ -z "$component" ]; then
  printf 'usage: %s <component>\n' "${0##*/}" >&2
  exit 2
fi

case "$component" in
  *[!a-z0-9-]*)
    printf 'ERROR: invalid component name: %s\n' "$component" >&2
    exit 2
    ;;
esac

# Ensure the source tree is present in the VM. If it is not, copy it once; the
# build will fail at mk-build-deps, which is expected and fine.
if ! bash "$vm_ssh" "test -d /root/build/$component"; then
  bash "$repo_root/scripts/vm-build-pkg.sh" "$component" >/dev/null 2>&1 || true
fi

# In the VM: read debian/control (top-level, else the first subdir's), pull the
# Build-Depends / -Indep / -Arch fields, split on commas, drop entries marked
# <!nocheck>, strip version/arch/profile parts, then probe each name with
# `apt-get install -s`. Print MISSING for each name apt cannot satisfy.
if ! bash "$vm_ssh" "bash -s -- $component" <<'REMOTE'
set -e
comp="$1"
cd "/root/build/$comp"
if [ -f debian/control ]; then
  ctl=debian/control
else
  ctl="$(find . -mindepth 2 -maxdepth 3 -type f -path '*/debian/control' | LC_ALL=C sort | head -n1)"
fi
if [ -z "$ctl" ]; then
  echo "ERROR: no debian/control under /root/build/$comp" >&2
  exit 2
fi
while IFS= read -r dep; do
  [ -n "$dep" ] || continue
  if out="$(apt-get install -s "$dep" 2>&1)"; then
    :
  else
    reason="$(printf '%s\n' "$out" | tail -n2 | tr '\n' ' ')"
    printf 'MISSING %s: %s\n' "$dep" "$reason"
  fi
done < <(
  awk '
    function emit(value,   n, i, part, m, j, a) {
      n = split(value, parts, ",")
      for (i = 1; i <= n; i++) {
        part = parts[i]
        if (part ~ /<!nocheck>/) continue
        gsub(/\([^)]*\)/, "", part)
        gsub(/\[[^]]*\]/, "", part)
        gsub(/<[^>]*>/, "", part)
        m = split(part, alts, "|")
        for (j = 1; j <= m; j++) {
          a = alts[j]
          gsub(/^[ \t]+/, "", a)
          gsub(/[ \t]+$/, "", a)
          if (a == "") continue
          if (a ~ /\$/) continue
          print a
        }
      }
    }
    /^[A-Za-z][-A-Za-z0-9]*:/ {
      if (field ~ /^Build-Depends/) emit(val)
      ci = index($0, ":")
      field = substr($0, 1, ci - 1)
      val = substr($0, ci + 1)
      gsub(/^[ \t]+/, "", val)
      next
    }
    /^[ \t]/ {
      if (field ~ /^Build-Depends/) { t = $0; gsub(/^[ \t]+/, "", t); val = val " " t }
      next
    }
    { if (field ~ /^Build-Depends/) emit(val); field = ""; val = "" }
    END { if (field ~ /^Build-Depends/) emit(val) }
  ' "$ctl" | LC_ALL=C sort -u
)
REMOTE
then
  printf 'FAIL: missing-deps probe for %s\n' "$component" >&2
  exit 1
fi
