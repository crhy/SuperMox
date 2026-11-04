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

# --- fuzz/offset must be visible: apply-patches.sh must WARN, not swallow it ---
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
assert_rc 0
assert_has "WARN"
assert_has "offset"
if ! grep -qF 'line6 edited' build/test-patch/fuzzy/out/pve-firewall/pve-firewall/fuzzme.txt 2>/dev/null; then
  echo "FAIL: fuzzy patch did not reach the output tree"
  fail=1
fi
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
