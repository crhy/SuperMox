#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

fail=0

# Nothing of this test may be influenced by the real repo's config/local.env or by
# variables the developer happens to have exported, so start from a clean slate.
# That means every SUPERMOX_* variable, not just the four documented ones: config/local.env
# may set any of them (SUPERMOX_VM_RAM included), and an exported one would win over it
# inside the probe and make the precedence checks meaningless.
while IFS= read -r _smx_var; do
  unset "$_smx_var"
done < <(compgen -e | grep -E '^SUPERMOX_[A-Za-z_][A-Za-z0-9_]*$')
unset _smx_var

tmp="build/test-local-env.d"
rm -rf "$tmp"
mkdir -p "$tmp/repo/scripts" "$tmp/repo/config"
cp scripts/local-env.sh "$tmp/repo/scripts/local-env.sh"
copy_root="$(cd "$tmp/repo" && pwd)"

# Ask the copied local-env.sh what value a variable ends up with.
probe() {
  local var="$1"
  bash -c 'source "$1"; printf "%s\n" "${!2}"' _ "$copy_root/scripts/local-env.sh" "$var"
}

expect() {
  local desc="$1" want="$2" got="$3"
  if [ "$want" != "$got" ]; then
    echo "FAIL: $desc: want [$want] got [$got]"
    fail=1
  fi
}

# Level 3: no config/local.env, nothing exported -> portable default inside the repo's build/.
expect "default SUPERMOX_VM_DIR" "$copy_root/build/vm" "$(probe SUPERMOX_VM_DIR)"
expect "default SUPERMOX_TEST_DIR" "$copy_root/build/test-data" "$(probe SUPERMOX_TEST_DIR)"
expect "default SUPERMOX_DEBS_DIR" "$copy_root/build/vm/debs" "$(probe SUPERMOX_DEBS_DIR)"
expect "default SUPERMOX_SPACED_REPO" "$(cd "$copy_root/.." && pwd)/spaced" "$(probe SUPERMOX_SPACED_REPO)"
expect "default SUPERMOX_SPACED_WORKTREE" "$copy_root/build/spaced-iso" "$(probe SUPERMOX_SPACED_WORKTREE)"

# Level 2: config/local.env wins over the default, and may set any SUPERMOX_* variable.
cat > "$copy_root/config/local.env" <<'EOF'
SUPERMOX_VM_DIR=/local/env/vm
SUPERMOX_VM_RAM=1024
EOF
expect "local.env SUPERMOX_VM_DIR" "/local/env/vm" "$(probe SUPERMOX_VM_DIR)"
expect "local.env SUPERMOX_VM_RAM" "1024" "$(probe SUPERMOX_VM_RAM)"
# The debs default follows the VM dir that local.env chose.
expect "local.env-derived SUPERMOX_DEBS_DIR" "/local/env/vm/debs" "$(probe SUPERMOX_DEBS_DIR)"

# Level 1: an exported variable wins over config/local.env.
expect "env SUPERMOX_VM_DIR" "/from/env/vm" \
  "$(SUPERMOX_VM_DIR=/from/env/vm bash -c 'source "$1"; printf "%s\n" "$SUPERMOX_VM_DIR"' _ "$copy_root/scripts/local-env.sh")"
expect "env SUPERMOX_VM_RAM" "2048" \
  "$(SUPERMOX_VM_RAM=2048 bash -c 'source "$1"; printf "%s\n" "$SUPERMOX_VM_RAM"' _ "$copy_root/scripts/local-env.sh")"

# The maintainer's own config/local.env must never be tracked.
if git ls-files --error-unmatch config/local.env >/dev/null 2>&1; then
  echo "FAIL: config/local.env is tracked; it must be git-ignored"
  fail=1
fi
if [ ! -f config/local.env.example ]; then
  echo "FAIL: config/local.env.example is missing"
  fail=1
fi

# No machine-specific path may appear in any script, comments included.
if grep -rn '/media/\|/home/' scripts/; then
  echo "FAIL: scripts/ contains a machine-specific path"
  fail=1
fi

rm -rf "$tmp"
if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "OK: local-env.sh precedence env > config/local.env > build/ default, config/local.env ignored, no machine paths in scripts/"
