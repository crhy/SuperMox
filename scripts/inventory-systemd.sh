#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

COMPONENTS=(
  pve-manager
  pve-cluster
  pve-common
  qemu-server
  pve-container
  pve-storage
  pve-access-control
  pve-ha-manager
  pve-firewall
  pve-http-server
  pve-guest-common
  proxmox-ve
)
PAT='systemctl|sd_notify|libsystemd|systemd-run|journalctl|(^|[[:space:]])dh_installsystemd|dh-sequence-systemd|systemd-sysv|PVE::Systemd|org\.freedesktop\.systemd1|enter_systemd_scope'

OUT="docs/systemd-inventory.md"
UNITS_TSV="build/inventory-units.tsv"
CODE_TSV="build/inventory-code.tsv"
CTRL_TSV="build/inventory-ctrl.tsv"

cleanup() { rm -f "$UNITS_TSV" "$CODE_TSV" "$CTRL_TSV"; }
trap cleanup EXIT

mkdir -p docs build

# Truncate raw text to n chars, then escape pipes for markdown.
cell() {
  local s="$1" n="$2"
  printf '%s' "${s:0:n}" | sed 's/|/\\|/g'
}

# --- Units ---
: > "$UNITS_TSV"
for c in "${COMPONENTS[@]}"; do
  base="upstream/pxvirt/packages/$c/$c"
  [ -d "$base" ] || continue
  while IFS= read -r f; do
    rel="${f#"$base"/}"
    type="$(grep -m1 '^Type=' "$f" | sed 's/^Type=//' || true)"
    exec="$(grep -m1 '^ExecStart=' "$f" | sed 's/^ExecStart=//' || true)"
    req="$(grep -E '^(Requires|After)=' "$f" | sed -E 's/^(Requires|After)=//' | tr '\n' ' ' | tr -s ' ' || true)"
    req="${req# }"
    req="${req% }"
    printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\n' \
      "$c" "$rel" "$(cell "$type" 80)" "$(cell "$exec" 80)" "$(cell "$req" 200)" >> "$UNITS_TSV"
  done < <(find "$base" -name .git -prune -o -type f \
    \( -name '*.service' -o -name '*.socket' -o -name '*.timer' -o -name '*.target' \) -print)
done

# --- Code references ---
: > "$CODE_TSV"
for c in "${COMPONENTS[@]}"; do
  base="upstream/pxvirt/packages/$c/$c"
  [ -d "$base" ] || continue
  { grep -rnIE "$PAT" "$base" --exclude-dir=.git || true; } | while IFS=: read -r path lineno content; do
    [ -n "${path:-}" ] || continue
    case "$path" in
      */debian/changelog) continue ;;
    esac
    case "$path" in
      *.service|*.socket|*.timer|*.target) continue ;;
    esac
    rel="${path#"$base"/}"
    content="${content#"${content%%[![:space:]]*}"}"
    content="${content%"${content##*[![:space:]]}"}"
    printf '%s\x1f%s\x1f%s\x1f%s\n' "$c" "$rel" "$lineno" "$(cell "$content" 100)" >> "$CODE_TSV"
  done
done

# --- Package dependencies ---
: > "$CTRL_TSV"
for c in "${COMPONENTS[@]}"; do
  base="upstream/pxvirt/packages/$c/$c"
  ctrl="$base/debian/control"
  [ -f "$ctrl" ] || continue
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    printf '%s\x1f%s\n' "$c" "$(cell "$line" 200)" >> "$CTRL_TSV"
  done < <(grep -nE 'systemd' "$ctrl" | sed -E 's/^[0-9]+://')
done

# --- Totals ---
n_units="$(wc -l < "$UNITS_TSV")"
n_code="$(wc -l < "$CODE_TSV")"
n_ctrl="$(wc -l < "$CTRL_TSV")"

# --- Emit markdown ---
{
  printf '# systemd inventory\n\n'
  printf 'Totals: units=%s, code references=%s, control lines=%s\n\n' "$n_units" "$n_code" "$n_ctrl"

  printf '## Units\n\n'
  printf '| Component | Unit file | Type= | ExecStart= | Requires/After= |\n'
  printf '| --- | --- | --- | --- | --- |\n'
  LC_ALL=C sort -t$'\x1f' -k1,1 -k2,2 "$UNITS_TSV" | while IFS=$'\x1f' read -r comp rel type exec req; do
    printf '| %s | %s | %s | %s | %s |\n' "$comp" "$rel" "$type" "$exec" "$req"
  done

  printf '\n## Code references\n\n'
  printf '| Component | File | Line | Match |\n'
  printf '| --- | --- | --- | --- |\n'
  LC_ALL=C sort -t$'\x1f' -k1,1 -k2,2 -k3,3n "$CODE_TSV" | while IFS=$'\x1f' read -r comp rel lineno match; do
    printf '| %s | %s | %s | %s |\n' "$comp" "$rel" "$lineno" "$match"
  done

  printf '\n## Package dependencies\n\n'
  printf '| Component | Field line |\n'
  printf '| --- | --- |\n'
  LC_ALL=C sort -t$'\x1f' -k1,1 -k2,2 "$CTRL_TSV" | while IFS=$'\x1f' read -r comp field; do
    printf '| %s | %s |\n' "$comp" "$field"
  done
} > "$OUT"

printf 'Wrote %s (units=%s, code references=%s, control lines=%s)\n' "$OUT" "$n_units" "$n_code" "$n_ctrl"
