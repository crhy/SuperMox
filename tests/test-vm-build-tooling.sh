#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

target="scripts/vm-build-pkg.sh"

if [ ! -f "$target" ]; then
  echo "FAIL: $target does not exist"
  exit 1
fi

out="$(bash "$target" --dry-run pve-common)"

missing=0
for pat in 'mk-build-deps' 'localrepo'; do
  if ! printf '%s\n' "$out" | grep -qF -- "$pat"; then
    echo "FAIL: --dry-run output missing: $pat"
    missing=1
  fi
done

if [ "$missing" -ne 0 ]; then
  exit 1
fi

# Multi-subdir component: --dry-run must list each subdir, in build order.
out2="$(bash "$target" --dry-run proxmox-perl-rs)"
for pat in 'common/pkg' 'pve-rs'; do
  if ! printf '%s\n' "$out2" | grep -qF -- "$pat"; then
    echo "FAIL: --dry-run proxmox-perl-rs missing subdir: $pat"
    exit 1
  fi
done
line_cp="$(printf '%s\n' "$out2" | awk '/common\/pkg/{print NR; exit}' || true)"
line_pr="$(printf '%s\n' "$out2" | awk '/pve-rs/{print NR; exit}' || true)"
if [ -z "$line_cp" ] || [ -z "$line_pr" ] || [ "$line_cp" -ge "$line_pr" ]; then
  echo "FAIL: --dry-run proxmox-perl-rs subdirs not in order (common/pkg before pve-rs)"
  exit 1
fi

# Own packaging/<name>/ dir: --dry-run must build the pkg-<name> dir with dpkg-buildpackage.
out3="$(bash "$target" --dry-run librust-proxmox-systemd-dev)"
for pat in 'pkg-librust-proxmox-systemd-dev' 'dpkg-buildpackage'; do
  if ! printf '%s\n' "$out3" | grep -qF -- "$pat"; then
    echo "FAIL: --dry-run librust-proxmox-systemd-dev missing: $pat"
    exit 1
  fi
done

echo "OK: vm-build-pkg.sh --dry-run pve-common mentions mk-build-deps and localrepo"
echo "OK: vm-build-pkg.sh --dry-run proxmox-perl-rs lists common/pkg before pve-rs"
echo "OK: vm-build-pkg.sh --dry-run librust-proxmox-systemd-dev builds pkg- dir with dpkg-buildpackage"

# --- scripts/prune-debs.sh: keep only the newest version per (package, arch) ---
prune_dir=build/prune-debs-test
rm -rf "$prune_dir"
mkdir -p "$prune_dir/debs" "$prune_dir/src"
mkdeb() {
  local name="$1" ver="$2" arch="$3" out="$4"
  local d="$prune_dir/src/${name}-${ver}-${arch}"
  mkdir -p "$d/DEBIAN"
  cat > "$d/DEBIAN/control" <<EOF
Package: $name
Version: $ver
Architecture: $arch
Maintainer: SuperMox Test <root@localhost>
Description: test package
EOF
  dpkg-deb --build "$d" "$out" >/dev/null 2>&1
}
mkdir -p "$prune_dir/debs"
mkdeb foo 1.0 amd64 "$prune_dir/debs/foo_1.0_amd64.deb"
mkdeb foo 2.0 amd64 "$prune_dir/debs/foo_2.0_amd64.deb"
mkdeb foo 0.9 amd64 "$prune_dir/debs/foo_0.9_amd64.deb"
mkdeb foo 1.0 arm64 "$prune_dir/debs/foo_1.0_arm64.deb"
mkdeb bar 3.0 amd64 "$prune_dir/debs/bar_3.0_amd64.deb"
# dpkg version order, not string order: 1.10 > 1.9
mkdeb baz 1.9 amd64 "$prune_dir/debs/baz_1.9_amd64.deb"
mkdeb baz 1.10 amd64 "$prune_dir/debs/baz_1.10_amd64.deb"

bash scripts/prune-debs.sh "$prune_dir/debs"

for keep in foo_2.0_amd64.deb foo_1.0_arm64.deb bar_3.0_amd64.deb baz_1.10_amd64.deb; do
  if [ ! -f "$prune_dir/debs/$keep" ]; then
    echo "FAIL: prune-debs removed a deb it should keep: $keep"
    exit 1
  fi
done
for gone in foo_1.0_amd64.deb foo_0.9_amd64.deb baz_1.9_amd64.deb; do
  if [ -f "$prune_dir/debs/$gone" ]; then
    echo "FAIL: prune-debs kept a superseded deb: $gone"
    exit 1
  fi
done
# a different architecture must never be pruned against another architecture
if [ ! -f "$prune_dir/debs/foo_1.0_arm64.deb" ]; then
  echo "FAIL: prune-debs crossed architectures (foo_1.0_arm64 removed)"
  exit 1
fi

echo "OK: scripts/prune-debs.sh keeps newest version per package/arch, dpkg ordering, arch-safe"
