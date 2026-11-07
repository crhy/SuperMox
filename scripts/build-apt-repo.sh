#!/usr/bin/env bash
# Publish SuperMox packages into a signed apt repository.
#
# Our packages are published as their own suite `supermox` inside the existing
# signed Spaced apt repository clone (https://crhy.github.io/spaced-apt), signed
# with the existing Spaced archive key. This mirrors .strata/ref/build-apt-repo.sh
# and .strata/ref/publish-apt-package.sh: same index generator (apt-ftparchive),
# same Filename rewrite (relative to the repository root), same pinned key, same
# InRelease/Release.gpg signing. It touches nothing outside pool/supermox/ and
# dists/supermox/, so Spaced's own suites in the same clone stay byte-identical.
#
# Usage: bash scripts/build-apt-repo.sh DEB_DIR APT_REPO_DIR
#   DEB_DIR      the directory of built .deb files (SUPERMOX_DEBS_DIR / build/<vm>/debs)
#   APT_REPO_DIR a clone of crhy/spaced-apt (its dists/ and pool/ trees)
#
# Package selection follows the staging loop in scripts/build-iso.sh: newest
# version per package, skipping *-dbgsym_* and *-build-deps_*.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

DEB_DIR="${1:?Usage: build-apt-repo.sh DEB_DIR APT_REPO_DIR}"
APT_REPO_DIR="${2:?Usage: build-apt-repo.sh DEB_DIR APT_REPO_DIR}"

DIST=supermox
COMP=main
# The pinned Spaced archive key and the keyring shipped in supermox-ve.
SIGNING_KEY=${SUPERMOX_APT_SIGNING_KEY:-6C16F77C2DAE19D262CFD9F0CC05F885576EBB05}
KEYRING=${SUPERMOX_APT_KEYRING:-$repo_root/packaging/supermox-ve/usr/share/keyrings/supermox-archive-keyring.gpg}

die() {
  printf 'build-apt-repo: %s\n' "$*" >&2
  exit 1
}

[ -d "$DEB_DIR" ] || die "no deb dir: $DEB_DIR"
[ -f "$KEYRING" ] || die "no keyring: $KEYRING"

# Refuse a substituted signing identity before touching repository metadata.
key_fingerprint=$(gpg --batch --show-keys --with-colons "$KEYRING" \
  | awk -F: '$1 == "fpr" {print $10; exit}')
[ "$SIGNING_KEY" = "$key_fingerprint" ] ||
  die "signing key does not match the shipped archive key"
gpg --batch --list-secret-keys "$SIGNING_KEY" >/dev/null ||
  die "no secret key $SIGNING_KEY available for signing"

APT_REPO_DIR=$(cd "$APT_REPO_DIR" && pwd)
pool_root="$APT_REPO_DIR/pool/$DIST"
dist_root="$APT_REPO_DIR/dists/$DIST"
mkdir -p "$pool_root" "$dist_root/$COMP"

work=$(mktemp -d "$repo_root/build/apt-repo.XXXXXX")
cleanup() { rm -rf -- "$work"; }
trap cleanup EXIT HUP INT TERM
mkdir -p "$work/verify-key"
chmod 0700 "$work/verify-key"

# --- Select the newest version of each package (build-iso.sh rules) ----------
declare -A best_ver=()
declare -A best_file=()
declare -A managed=()

shopt -s nullglob
for f in "$DEB_DIR"/*.deb; do
  base="${f##*/}"
  case "$base" in
    *-dbgsym_*.deb | *-build-deps_*.deb) continue ;;
  esac
  if [[ ! "$base" =~ ^(.*)_([0-9][^_]*)_(all|[^_]+)\.deb$ ]]; then
    printf 'WARN: skipping unparseable deb name: %s\n' "$base" >&2
    continue
  fi
  name="${BASH_REMATCH[1]}"
  ver="${BASH_REMATCH[2]}"
  arch_f="${BASH_REMATCH[3]}"
  # This repository publishes amd64, arm64 and all only.
  case "$arch_f" in
    amd64 | arm64 | all) ;;
    *)
      printf 'WARN: skipping %s (arch %s not published by this suite)\n' "$base" "$arch_f" >&2
      continue
      ;;
  esac
  managed["$name"]=1
  if [ -z "${best_ver[$name]:-}" ] || dpkg --compare-versions "$ver" gt "${best_ver[$name]}"; then
    best_ver["$name"]="$ver"
    best_file["$name"]="$f"
  fi
done
shopt -u nullglob

if [ "${#managed[@]}" -eq 0 ]; then
  die "no SuperMox .debs found in $DEB_DIR"
fi

# --- Stage into pool/supermox/<first letter>/<package>/ ----------------------
# Remove every older version of each package we manage from its pool dir first,
# then copy in the newest, so the pool holds exactly one version per package.
for name in "${!managed[@]}"; do
  letter="${name:0:1}"
  pkg_dir="$pool_root/$letter/$name"
  mkdir -p "$pkg_dir"
  rm -f "$pkg_dir"/*.deb 2>/dev/null || true
done
for name in "${!best_file[@]}"; do
  letter="${name:0:1}"
  cp "${best_file[$name]}" "$pool_root/$letter/$name/"
done

# --- Generate Packages indexes (Filename relative to the repository root) ---
# apt-ftparchive run from the repository root over pool/supermox already yields
# Filename: pool/supermox/... paths, which is what apt resolves downloads from.
(cd "$APT_REPO_DIR" && apt-ftparchive packages "pool/$DIST") > "$work/Packages"

# Build the index in a clean metadata tree (like .strata/ref/build-apt-repo.sh):
# apt-ftparchive release must see only the component index files, so its
# checksums list main/binary-*/Packages and never a stale Release/InRelease.
metadata="$work/metadata"
mkdir -p "$metadata/$COMP/binary-amd64" "$metadata/$COMP/binary-arm64" "$metadata/$COMP/binary-all"

# Split the combined index by Architecture into the three binary-* dirs.
split_index() {
  local arch="$1"
  awk -v arch="$arch" '
    BEGIN { RS = ""; ORS = "\n\n" }
    { if ($0 ~ ("(^|\n)Architecture: " arch "(\n|$)")) print $0 }
  ' "$work/Packages" > "$metadata/$COMP/binary-$arch/Packages"
}

for arch in amd64 arm64 all; do
  split_index "$arch"
  gzip -n9c "$metadata/$COMP/binary-$arch/Packages" > \
    "$metadata/$COMP/binary-$arch/Packages.gz"
done

echo "Generating Release metadata…"
(cd "$metadata" && apt-ftparchive \
  -o APT::FTPArchive::Release::Origin="SuperMox" \
  -o APT::FTPArchive::Release::Label="SuperMox apt repository" \
  -o APT::FTPArchive::Release::Suite="$DIST" \
  -o APT::FTPArchive::Release::Codename="$DIST" \
  -o APT::FTPArchive::Release::Architectures="amd64 arm64 all" \
  -o APT::FTPArchive::Release::Components="$COMP" \
  release .) > "$work/Release"

gpg --batch --yes --local-user "$SIGNING_KEY" --digest-algo SHA256 \
  --clearsign --output "$work/InRelease" "$work/Release"
gpg --batch --yes --local-user "$SIGNING_KEY" --digest-algo SHA256 \
  --armor --detach-sign --output "$work/Release.gpg" "$work/Release"

# Prove the signature verifies against the keyring the package ships.
gpg --batch --homedir "$work/verify-key" --no-default-keyring \
  --keyring "$KEYRING" --verify "$work/InRelease" >/dev/null ||
  die "InRelease does not verify against the shipped keyring"

# Publish: copy the fresh indexes and signatures into the repository tree.
for arch in amd64 arm64 all; do
  mkdir -p "$dist_root/$COMP/binary-$arch"
  cp "$metadata/$COMP/binary-$arch/Packages" \
     "$metadata/$COMP/binary-$arch/Packages.gz" \
     "$dist_root/$COMP/binary-$arch/"
done
cp "$work/Release" "$work/Release.gpg" "$work/InRelease" "$dist_root/"

echo "Published ${#managed[@]} package(s) from $DEB_DIR into $dist_root"
