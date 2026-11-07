#!/usr/bin/env bash
# tests/test-apt-repo.sh — offline test for scripts/build-apt-repo.sh.
#
# It generates a throwaway signing key, builds tiny .debs with dpkg-deb, and
# publishes them into a scratch repository clone. It checks: only the newest
# version of each package is published, the Release metadata is ours (Origin
# SuperMox, suite supermox, amd64/arm64/all), InRelease verifies against the
# keyring, a pre-existing Spaced suite file in the same clone is left byte-identical,
# and a substituted signing identity fails without writing anything.
set -euo pipefail

cd "$(dirname "$0")/.."

target="scripts/build-apt-repo.sh"
missing=0

if [ ! -f "$target" ]; then
  echo "FAIL: $target does not exist"
  exit 1
fi

work="$PWD/build/c14-test"
rm -rf "$work"
mkdir -p "$work"

# Isolated GNUPGHOME so the test never touches the real ~/.gnupg.
export GNUPGHOME="$work/gnupg"
mkdir -p "$GNUPGHOME"
chmod 700 "$GNUPGHOME"

if ! timeout 60 gpg --batch --passphrase '' --quick-gen-key 'SuperMox test <test@invalid>' rsa2048 sign never >/dev/null 2>&1; then
  echo "FAIL: could not generate a throwaway signing key"
  exit 1
fi
KEY="$(timeout 60 gpg --batch --with-colons --list-keys 'SuperMox test' | awk -F: '/^fpr/{print $10; exit}')"
if [ -z "$KEY" ]; then
  echo "FAIL: could not read the throwaway key fingerprint"
  exit 1
fi

# The keyring the package would ship: the public half of the throwaway key.
KEYRING="$work/keyring.gpg"
timeout 60 gpg --batch --export > "$KEYRING"

# --- Build tiny debs: two versions of one amd64 package, one arch-all package.
debs="$work/debs"
src="$work/src"
mkdir -p "$debs"

mk_deb() {
  local name="$1" ver="$2" arch="$3"
  rm -rf "$src"
  mkdir -p "$src/DEBIAN"
  {
    printf 'Package: %s\n' "$name"
    printf 'Version: %s\n' "$ver"
    printf 'Architecture: %s\n' "$arch"
    printf 'Maintainer: SuperMox test <noreply@supermox.me>\n'
    printf 'Description: fake package for the apt repo test\n'
  } > "$src/DEBIAN/control"
  dpkg-deb --build --root-owner-group "$src" "$debs/${name}_${ver}_${arch}.deb" >/dev/null
}

mk_deb dummy 1.0.0 amd64
mk_deb dummy 1.1.0 amd64
mk_deb allpkg 2.0.0 all

# A scratch repository clone with a pre-existing Spaced suite file that must
# survive untouched.
repo="$work/repo"
mkdir -p "$repo/dists/spaced"
printf 'spaced-original\n' > "$repo/dists/spaced/Release"

if ! out="$(SUPERMOX_APT_SIGNING_KEY="$KEY" SUPERMOX_APT_KEYRING="$KEYRING" timeout 120 bash "$target" "$debs" "$repo" 2>&1)"; then
  echo "FAIL: build-apt-repo.sh failed:"
  printf '%s\n' "$out"
  missing=1
fi

# Newest version only: the pool and the amd64 index must hold 1.1.0, never 1.0.0.
if [ ! -f "$repo/pool/supermox/d/dummy/dummy_1.1.0_amd64.deb" ]; then
  echo "FAIL: the newest dummy (1.1.0) is not in pool/supermox/d/dummy/"
  missing=1
fi
if [ -f "$repo/pool/supermox/d/dummy/dummy_1.0.0_amd64.deb" ]; then
  echo "FAIL: the older dummy (1.0.0) is still in the pool"
  missing=1
fi
if [ -f "$repo/pool/supermox/a/allpkg/allpkg_2.0.0_all.deb" ]; then
  :
else
  echo "FAIL: the arch-all package is not in pool/supermox/a/allpkg/"
  missing=1
fi

amd64_idx="$repo/dists/supermox/main/binary-amd64/Packages"
arm64_idx="$repo/dists/supermox/main/binary-arm64/Packages"
all_arch_idx="$repo/dists/supermox/main/binary-all/Packages"
for f in "$amd64_idx" "$arm64_idx" "$all_arch_idx"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: missing Packages index: $f"
    missing=1
  fi
done
if [ ! -f "$amd64_idx" ] || ! grep -qF -- 'Version: 1.1.0' "$amd64_idx"; then
  echo "FAIL: binary-amd64/Packages does not list the newest version"
  missing=1
fi
if [ -f "$amd64_idx" ] && grep -qF -- 'Version: 1.0.0' "$amd64_idx"; then
  echo "FAIL: binary-amd64/Packages still lists the older version"
  missing=1
fi
if [ -f "$all_arch_idx" ] && ! grep -qF -- 'Package: allpkg' "$all_arch_idx"; then
  echo "FAIL: binary-all/Packages does not list the arch-all package"
  missing=1
fi
# Filename must be relative to the repository root (apt resolves downloads there).
if [ -f "$amd64_idx" ] && ! grep -qF -- 'Filename: pool/supermox/d/dummy/dummy_1.1.0_amd64.deb' "$amd64_idx"; then
  echo "FAIL: binary-amd64/Packages Filename is not pool/supermox/... relative to the repo root"
  missing=1
fi

# Release metadata is ours, not Spaced's.
rel="$repo/dists/supermox/Release"
if [ ! -f "$rel" ]; then
  echo "FAIL: dists/supermox/Release does not exist"
  missing=1
else
  for pat in 'Origin: SuperMox' 'Codename: supermox' 'Suite: supermox' \
    'Components: main' 'Architectures: amd64 arm64 all'; do
    if ! grep -qF -- "$pat" "$rel"; then
      echo "FAIL: dists/supermox/Release is missing: $pat"
      missing=1
    fi
  done
fi

# InRelease and Release.gpg must exist and InRelease must verify against the
# keyring the package ships.
for f in "$repo/dists/supermox/InRelease" "$repo/dists/supermox/Release.gpg"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: missing signature file: $f"
    missing=1
  fi
done
if [ -f "$repo/dists/supermox/InRelease" ]; then
  vdir="$work/verify"
  mkdir -p "$vdir"
  chmod 700 "$vdir"
  if ! timeout 60 gpg --batch --homedir "$vdir" --no-default-keyring --keyring "$KEYRING" \
    --verify "$repo/dists/supermox/InRelease" >/dev/null 2>&1; then
    echo "FAIL: InRelease does not verify against the shipped keyring"
    missing=1
  fi
fi

# The pre-existing Spaced suite in the same clone must be byte-identical.
if ! cmp -s <(printf 'spaced-original\n') "$repo/dists/spaced/Release"; then
  echo "FAIL: the pre-existing dists/spaced/Release was modified"
  missing=1
fi

# A substituted signing identity must fail without writing anything.
bad="$work/repo-bad"
mkdir -p "$bad"
if SUPERMOX_APT_SIGNING_KEY="0000000000000000000000000000000000000000" \
  SUPERMOX_APT_KEYRING="$KEYRING" timeout 120 bash "$target" "$debs" "$bad" >/dev/null 2>&1; then
  echo "FAIL: build-apt-repo.sh accepted a signing key that does not match the keyring"
  missing=1
fi
if [ -e "$bad/dists/supermox" ] || [ -e "$bad/pool/supermox" ]; then
  echo "FAIL: the mismatched-key run wrote repository metadata"
  missing=1
fi

rm -rf "$work"

if [ "$missing" -ne 0 ]; then
  exit 1
fi

echo "OK: build-apt-repo.sh publishes only the newest version of each package into pool/supermox/"
echo "OK: build-apt-repo.sh writes amd64/arm64/all Packages with repo-root-relative Filenames and SuperMox Release metadata"
echo "OK: build-apt-repo.sh signs InRelease/Release.gpg so they verify against the shipped keyring, leaves other suites untouched, and fails on a substituted signing key"
