#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -d upstream/pxvirt/packages/pve-common ]; then
  echo "SKIP"
  exit 0
fi

fail=0
out=""
rc=0

run() {
  rc=0
  out="$(bash "$@" 2>&1)" || rc=$?
}

assert_rc() {
  local want="$1"
  if [ "$rc" -ne "$want" ]; then
    echo "FAIL: exit code $rc, expected $want"
    printf '%s\n' "$out"
    fail=1
  fi
}

assert_has() {
  local needle="$1"
  if ! printf '%s' "$out" | grep -qF -- "$needle"; then
    echo "FAIL: output missing: $needle"
    printf '%s\n' "$out"
    fail=1
  fi
}

# --- integration: apply-patches then check-no-systemd on real upstream ---
rm -rf build/patched
run scripts/apply-patches.sh build/patched
assert_rc 0
assert_has "Applied patches to build/patched"

run scripts/check-no-systemd.sh --source build/patched
assert_rc 0
baseline="$(tr -dc '0-9' < config/systemd-baseline.txt)"
assert_has "COUNT $baseline"

# --- version suffix (issue #10 part 2): every debian/changelog in the patched
# tree must gain a top entry whose version ends in +supermoxN, so a SuperMox
# .deb can never be mistaken for the same version from download.proxmox.com ---
nosuffix=0
while IFS= read -r -d '' cl; do
  ver="$(sed -n '1{s/^[^(]*(//;s/).*//p}' "$cl")"
  case "$ver" in
    *+supermox*) ;;
    *) printf 'no suffix: %s (%s)\n' "$cl" "$ver" >&2; nosuffix=1 ;;
  esac
done < <(find build/patched -name .git -prune -o -type f -path '*/debian/changelog' -print0)
if [ "$nosuffix" -ne 0 ]; then
  echo "FAIL: patched changelogs missing the +supermox version suffix"
  fail=1
fi
if find build/patched -name .git -prune -o -type f -path '*/debian/changelog' -print0 |
  xargs -0 grep -qE '\+supermox[0-9]+\+supermox'; then
  echo "FAIL: changelog version got a double +supermox suffix"
  fail=1
fi

# re-running must not stack a second entry on top of the first one
cl_top=build/patched/pve-manager/pve-manager/debian/changelog
head_before="$(sed -n '1p' "$cl_top")"
run scripts/apply-patches.sh build/patched
assert_rc 0
head_after="$(sed -n '1p' "$cl_top")"
if [ "$head_before" != "$head_after" ]; then
  echo "FAIL: re-running apply-patches.sh changed the changelog version line"
  printf '%s\n%s\n' "$head_before" "$head_after"
  fail=1
fi
if [ "$(grep -cF -- "$head_before" "$cl_top")" != 1 ]; then
  echo "FAIL: duplicate changelog entry for $head_before"
  fail=1
fi

# --- unit: patch-workspace + patch-save on a tiny fake component ---
export UPSTREAM_PACKAGES="$PWD/build/test-patch/packages"
export PATCHES_DIR="$PWD/build/test-patch/patches"
rm -rf build/test-patch build/work/fakecomp
mkdir -p "$UPSTREAM_PACKAGES/fakecomp/fakecomp"
printf 'line1\nline2\nline3\n' > "$UPSTREAM_PACKAGES/fakecomp/fakecomp/hello.txt"

run scripts/patch-workspace.sh fakecomp
assert_rc 0

printf 'line1\nLINE2 EDITED\nline3\nline4 new\n' > build/work/fakecomp/new/hello.txt

run scripts/patch-save.sh fakecomp my-slug
assert_rc 0
assert_has "Wrote"

patchfile="$PATCHES_DIR/fakecomp/0001-my-slug.patch"
if [ ! -f "$patchfile" ]; then
  echo "FAIL: patch file not created: $patchfile"
  fail=1
fi

if grep -qE '^--- a/' "$patchfile" && grep -qE '^\+\+\+ b/' "$patchfile"; then
  :
else
  echo "FAIL: patch headers not rewritten to a/ b/"
  fail=1
fi
if grep -qE '^--- orig/|^\+\+\+ new/' "$patchfile"; then
  echo "FAIL: patch still has orig/ new/ headers"
  fail=1
fi

# round-trip: apply the saved patch to a fresh copy
rm -rf build/test-patch/rt
mkdir -p build/test-patch/rt/fakecomp/fakecomp
rsync -a --exclude .git "$UPSTREAM_PACKAGES/fakecomp/fakecomp/" build/test-patch/rt/fakecomp/fakecomp/
rc=0
out="$( ( cd build/test-patch/rt/fakecomp/fakecomp && patch -p1 --forward --batch < "$patchfile" ) 2>&1 )" || rc=$?
assert_rc 0
if ! grep -qF 'LINE2 EDITED' build/test-patch/rt/fakecomp/fakecomp/hello.txt; then
  echo "FAIL: round-trip patch did not change content"
  fail=1
fi

# empty diff: re-run workspace (applies 0001 to orig+new), save again -> exit 1
rm -rf build/work/fakecomp
run scripts/patch-workspace.sh fakecomp
assert_rc 0
run scripts/patch-save.sh fakecomp should-be-empty
assert_rc 1
assert_has "nothing to save"

# never overwrite an existing patch file: new edit -> next number, 0001 intact
printf 'zzz\n' > build/work/fakecomp/new/hello.txt
run scripts/patch-save.sh fakecomp my-slug
assert_rc 0
if ! grep -qF 'LINE2 EDITED' "$patchfile"; then
  echo "FAIL: existing patch 0001 was overwritten"
  fail=1
fi

# --- unit: version suffix on fake upstream components (real component names,
# because apply-patches.sh iterates over fetch-upstream.sh --list) ---
export UPSTREAM_PACKAGES="$PWD/build/test-patch/ver/packages"
export PATCHES_DIR="$PWD/build/test-patch/ver/patches"
export INIT_SCRIPTS="$PWD/build/test-patch/ver/no-init-scripts"
rm -rf build/test-patch/ver
mkdir -p "$UPSTREAM_PACKAGES/pve-common/pve-common/debian" \
          "$UPSTREAM_PACKAGES/pve-cluster/pve-cluster/debian" \
          "$UPSTREAM_PACKAGES/pve-storage/pve-storage"
printf 'pve-common (1.2.3) unstable; urgency=low\n\n  Upstream entry.\n\n -- Upstream <a@example.com>  Mon, 02 Jan 2006 15:00:00 +0000\n' > \
  "$UPSTREAM_PACKAGES/pve-common/pve-common/debian/changelog"
printf 'pve-cluster (9.9+supermox2) unstable; urgency=low\n\n  Already forked.\n\n -- Upstream <b@example.com>  Mon, 02 Jan 2006 15:00:00 +0000\n' > \
  "$UPSTREAM_PACKAGES/pve-cluster/pve-cluster/debian/changelog"
run scripts/apply-patches.sh build/test-patch/ver/out
assert_rc 0
ver_a="$(sed -n '1{s/^[^(]*(//;s/).*//p}' build/test-patch/ver/out/pve-common/pve-common/debian/changelog)"
if [ "$ver_a" != "1.2.3+supermox1" ]; then
  echo "FAIL: pve-common changelog version is '$ver_a', expected 1.2.3+supermox1"
  fail=1
fi
if [ "$(grep -c '^pve-common (' build/test-patch/ver/out/pve-common/pve-common/debian/changelog)" != 2 ]; then
  echo "FAIL: pve-common changelog does not hold exactly the new entry above the upstream one"
  fail=1
fi
ver_b="$(sed -n '1{s/^[^(]*(//;s/).*//p}' build/test-patch/ver/out/pve-cluster/pve-cluster/debian/changelog)"
if [ "$ver_b" != "9.9+supermox2" ]; then
  echo "FAIL: already-suffixed pve-cluster was rewritten to $ver_b"
  fail=1
fi
if [ "$(grep -c '^pve-cluster (' build/test-patch/ver/out/pve-cluster/pve-cluster/debian/changelog)" != 1 ]; then
  echo "FAIL: pve-cluster gained a duplicate changelog entry"
  fail=1
fi
unset UPSTREAM_PACKAGES
unset PATCHES_DIR
unset INIT_SCRIPTS

# --- fuzz/offset must be fatal: apply-patches.sh must ERROR and exit 1 ---
export UPSTREAM_PACKAGES="$PWD/build/test-patch/fuzzy/packages"
export PATCHES_DIR="$PWD/build/test-patch/fuzzy/patches"
export INIT_SCRIPTS="$PWD/build/test-patch/fuzzy/no-init-scripts"
rm -rf build/test-patch/fuzzy
mkdir -p "$UPSTREAM_PACKAGES/pve-firewall/pve-firewall" "$PATCHES_DIR/pve-firewall"
printf 'line1\nline2\nline3\nline4\nline5\nline6\n' > "$UPSTREAM_PACKAGES/pve-firewall/pve-firewall/fuzzme.txt"
cat > "$PATCHES_DIR/pve-firewall/0001-fuzzy.patch" <<'PATCH'
--- a/fuzzme.txt
+++ b/fuzzme.txt
@@ -1,2 +1,2 @@
 line5
-line6
+line6 edited
PATCH
run scripts/apply-patches.sh build/test-patch/fuzzy/out
assert_rc 1
assert_has "ERROR"
assert_has "offset"
if [ -n "$(find build/test-patch/fuzzy/out -name '*.orig' -print -quit)" ]; then
  echo "FAIL: .orig backup left inside the patched tree"
  fail=1
fi

unset UPSTREAM_PACKAGES
unset PATCHES_DIR
unset INIT_SCRIPTS

rm -rf build/patched build/test-patch build/work/fakecomp

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "OK: patch tooling (apply-patches, patch-workspace, patch-save) behaves correctly"
