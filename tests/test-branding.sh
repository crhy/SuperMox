#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -d upstream/pxvirt/packages/pve-manager ]; then
  echo "SKIP"
  exit 0
fi

fail=0
out=build/branding-apply
allowlist=config/branding-allowlist.txt

rm -rf "$out"
if ! bash scripts/apply-patches.sh "$out" >/dev/null; then
  echo "FAIL: apply-patches.sh failed"
  exit 1
fi

www="$out/pve-manager/pve-manager/www/manager6"

# 1. the old Proxmox logo widget must not be referenced anywhere in the web UI.
#    There is no allow-list for the logo: it must be replaced in every theme,
#    so the reference has to be gone from the JS, not recolored by one theme's CSS.
if grep -rn 'proxmoxLogoSvg\|proxmoxlogo\|proxmox_logo' "$www"; then
  echo "FAIL: old Proxmox logo reference still present in the patched web UI"
  fail=1
fi

# 2. every user-visible "Proxmox VE" / "Proxmox Virtual Environment" string must
#    be allow-listed (comment, console.log, or an upstream-docs attribution).
while IFS= read -r line; do
  content="${line#*:*:}"
  allowed=0
  while IFS= read -r entry; do
    case "$entry" in
      ''|\#*) continue ;;
    esac
    frag="${entry%%  #*}"
    if [[ "$content" == *"$frag"* ]]; then
      allowed=1
      break
    fi
  done < "$allowlist"
  if [ "$allowed" -eq 0 ]; then
    echo "FAIL: un-branded product name in web UI: $line"
    fail=1
  fi
done < <(grep -rn 'Proxmox VE\|Proxmox Virtual Environment' "$www")

rm -rf "$out"

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "OK: no user-visible Proxmox product name or logo in the patched web UI"
