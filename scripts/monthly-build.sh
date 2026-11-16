#!/usr/bin/env bash
# One monthly SuperMox build run: every build check that works offline here, in order,
# each one recorded, and the steps that need a VM reported as SKIP with the reason.
#
#   * steps run in registry order; offline steps first, the VM-dependent ones last
#   * a step that fails is recorded as FAIL <exit code> and the run continues
#   * a step whose prerequisite is missing is recorded as SKIP <reason>, never OK
#   * the exit status is non-zero only after every selected step was attempted
#   * every step's output is kept under the state dir, plus manifest.txt, so a failed
#     month leaves enough evidence to reproduce it (SuperMox#3: "a failed test must
#     block release and leave enough evidence to reproduce it")
#
# Nothing is invented here: each step calls a script or test that already exists.
# The nested-KVM install, the web/API VM lifecycle and the hardware matrix stay open
# behind SuperMox#2; this script reports them instead of pretending they passed.
# Everything runs under sysvinit; no service manager is called from here.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

# name|command|kind   (kind: offline | vm). Order is the run order.
STEPS=(
  'upstream-pins|bash scripts/check-overrides.sh|offline'
  'no-systemd|bash scripts/check-no-systemd.sh --source .|offline'
  'python-tests|bash tests/test-python.sh|offline'
  'init-scripts|bash tests/test-init-scripts.sh|offline'
  'repo-layout|bash tests/test-repo-layout.sh|offline'
  'iso-prepare|bash scripts/build-iso.sh --prepare-only|offline'
  'vm-install|bash scripts/vm-test-install.sh|vm'
  'web-admin|bash tests/manager-live.sh|vm'
  'hardware-matrix|bash scripts/supermox-node-caps.sh|vm'
)

STEP_TIMEOUT="${SUPERMOX_MONTHLY_STEP_TIMEOUT:-900}"

# --- month line -------------------------------------------------------------
# AGENTS.md: the line is named for the month and two-digit year it opens in
# (10.26 = October 2026); the number before the dot is a month, so after 12.26
# comes 1.27.
month_line() {
  local d="${1//\//}"
  d="${d//-/}"
  d="${d//:}"
  local y m
  y="${d:0:4}"
  m="${d:4:2}"
  case "$y$m" in
    '' | *[!0-9]*)
      printf 'ERROR: cannot read a year and month from: %s\n' "$1" >&2
      return 2
      ;;
  esac
  printf '%d.%s\n' "$((10#$m))" "${y: -2}"
}

# --- prerequisite probes ----------------------------------------------------
# Each prints the concrete missing prerequisite and returns non-zero; the step is
# then recorded SKIP, never OK.
prereq_upstream_pins() { return 0; }
prereq_no_systemd() { return 0; }
prereq_python_tests() { return 0; }
prereq_init_scripts() { return 0; }
prereq_repo_layout() { return 0; }

prereq_iso_prepare() {
  local spaced="${SUPERMOX_SPACED_REPO:-/home/rhy/spaced-10.26}"
  if [ ! -d "$spaced" ]; then
    printf 'SUPERMOX_SPACED_REPO is not a checkout: %s\n' "$spaced"
    return 1
  fi
  return 0
}

prereq_vm_install() {
  local test_dir="${SUPERMOX_TEST_DIR:-/media/rhy/data/supermox-test}"
  if ! command -v sshpass >/dev/null 2>&1; then
    printf 'sshpass not installed\n'
    return 1
  fi
  if [ ! -d "$test_dir" ]; then
    printf 'SUPERMOX_TEST_DIR absent: %s\n' "$test_dir"
    return 1
  fi
  # The step boots a clean nested-KVM test VM itself, so it only runs when the
  # operator asks for it: one VM at a time, and this is still open behind #2.
  if [ "${SUPERMOX_MONTHLY_VM:-0}" != "1" ]; then
    printf 'nested-KVM test VM not requested (set SUPERMOX_MONTHLY_VM=1)\n'
    return 1
  fi
  return 0
}

prereq_web_admin() {
  local st
  st="$(bash scripts/vm-status.sh 2>&1 || true)"
  if [ "$st" = "no SuperMox VM running" ]; then
    printf 'scripts/vm-status.sh: no SuperMox VM running\n'
    return 1
  fi
  return 0
}

# The hardware matrix has no offline half yet: the step only reports what it would
# run, so the month records the gap instead of a green light.
prereq_hardware_matrix() {
  printf 'no hardware matrix here yet: this step would run scripts/build-rootfs.sh and scripts/vm-test-install.sh per arch profile (amd64, arm64, armhf, riscv64, loong64), then scripts/supermox-node-caps.sh plus the physical-host checklist in docs/any-hardware.md on each; open behind SuperMox#2\n'
  return 1
}

# --- registry helpers -------------------------------------------------------
step_field() {
  awk -v s="$1" 'BEGIN { FS = "|" } { print $s }' <<< "$2"
}

step_name() { step_field 1 "$1"; }
step_cmd() { step_field 2 "$1"; }
step_kind() { step_field 3 "$1"; }

fn_of() {
  local n="${1//-/_}"
  printf '%s' "$n"
}

is_step() {
  local e s
  for e in "${STEPS[@]}"; do
    s="$(step_name "$e")"
    [ "$s" = "$1" ] && return 0
  done
  return 1
}

selected=()

add_only() {
  local rest="$1" part
  while [ -n "$rest" ]; do
    part="${rest%%,*}"
    if [ "$part" = "$rest" ]; then
      rest=""
    else
      rest="${rest#*,}"
    fi
    [ -n "$part" ] || continue
    if ! is_step "$part"; then
      printf 'ERROR: unknown step: %s\n' "$part" >&2
      return 2
    fi
    selected+=("$part")
  done
  return 0
}

# selected holds names given by --only; run_entries holds the registry entries,
# always in registry order so a subset cannot reorder the run.
run_entries=()

select_only() {
  local n want e
  n="${#selected[@]}"
  for e in "${STEPS[@]}"; do
    want="$(step_name "$e")"
    if [ "$n" -eq 0 ]; then
      run_entries+=("$e")
      continue
    fi
    if printf '%s\n' "${selected[@]}" | grep -qxF -- "$want"; then
      run_entries+=("$e")
    fi
  done
}

usage() {
  printf 'usage: %s [--list] [--only STEP[,STEP...]] [--dry-run] [--state-dir DIR] [--line NAME] [--date YYYY-MM-DD]\n' "${0##*/}"
  printf 'steps: %s\n' "$(
    for e in "${STEPS[@]}"; do
      printf '%s ' "$(step_name "$e")"
    done
    printf '\n'
  )"
  printf 'env: SUPERMOX_MONTHLY_VM=1 to let the VM steps run, SUPERMOX_MONTHLY_STEP_TIMEOUT, SUPERMOX_SPACED_REPO, SUPERMOX_TEST_DIR\n'
}

# --- main -----------------------------------------------------------------
line=""
state_dir=""
day=""
list=0
dry=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --list) list=1; shift ;;
    --dry-run) dry=1; shift ;;
    --only)
      if [ "$#" -lt 2 ]; then
        usage
        exit 2
      fi
      if ! add_only "$2"; then
        usage
        exit 2
      fi
      shift 2
      ;;
    --state-dir)
      if [ "$#" -lt 2 ]; then
        usage
        exit 2
      fi
      state_dir="$2"
      shift 2
      ;;
    --line)
      if [ "$#" -lt 2 ]; then
        usage
        exit 2
      fi
      line="$2"
      shift 2
      ;;
    --date)
      if [ "$#" -lt 2 ]; then
        usage
        exit 2
      fi
      day="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      printf 'ERROR: unknown argument: %s\n' "$1" >&2
      usage
      exit 2
      ;;
  esac
done

if [ -z "$line" ]; then
  if [ -n "$day" ]; then
    line="$(month_line "$day")"
  else
    line="$(month_line "${SUPERMOX_MONTHLY_DATE:-$(date -u +%Y-%m-%d)}")"
  fi
fi
if [ -z "$state_dir" ]; then
  state_dir="build/monthly/$line"
fi

if [ "$list" -eq 1 ]; then
  select_only
  for e in "${run_entries[@]}"; do
    printf '%s %s %s\n' "$(step_name "$e")" "$(step_kind "$e")" "$(step_cmd "$e")"
  done
  exit 0
fi

if [ "$dry" -eq 1 ]; then
  # Plan only: no step runs, no state dir is created, nothing is touched.
  select_only
  for e in "${run_entries[@]}"; do
    printf 'DRY-RUN %s (%s): %s\n' "$(step_name "$e")" "$(step_kind "$e")" "$(step_cmd "$e")"
  done
  printf 'DRY-RUN line %s state dir %s: nothing run, nothing written\n' "$line" "$state_dir"
  exit 0
fi

cd "$repo_root"
mkdir -p "$state_dir"

pxvirt_commit="$(sed -n 's/^PXVIRT_COMMIT=//p' scripts/fetch-upstream.sh | head -1)"
stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
manifest="$state_dir/manifest.txt"

printf 'line %s\n' "$line" > "$manifest"
printf 'pxvirt %s\n' "${pxvirt_commit:-unknown}" >> "$manifest"
printf 'timestamp %s\n' "$stamp" >> "$manifest"

select_only

if [ "${#run_entries[@]}" -eq 0 ]; then
  printf 'ERROR: no step selected\n' >&2
  exit 2
fi

ran=0
failed=0
skipped=0

for e in "${run_entries[@]}"; do
  name="$(step_name "$e")"
  cmd="$(step_cmd "$e")"
  kind="$(step_kind "$e")"
  log="$state_dir/$name.log"
  fn="$(fn_of "$name")"

  printf '== %s (%s) ==\n' "$name" "$kind"
  ran=$((ran + 1))

  # The probe prints the reason and fails, or succeeds with no output.
  rc=0
  out=""
  if reason="$(prereq_"$fn" 2>/dev/null)"; then
    out="$(timeout "$STEP_TIMEOUT" bash -c "$cmd" 2>&1)" || rc=$?
    printf '%s\n' "$out" > "$log"
    printf '%s\n' "$out"
    if [ "$rc" -ne 0 ]; then
      printf 'FAIL %s rc=%s log=%s\n' "$name" "$rc" "$log"
      printf '%s FAIL %s %s\n' "$name" "$rc" "$log" >> "$manifest"
      failed=$((failed + 1))
      continue
    fi
    printf 'OK %s log=%s\n' "$name" "$log"
    printf '%s OK %s\n' "$name" "$log" >> "$manifest"
  else
    printf 'SKIP %s %s\n' "$name" "$reason"
    printf '%s\n' "$reason" > "$log"
    printf '%s SKIP %s %s\n' "$name" "$reason" "$log" >> "$manifest"
    skipped=$((skipped + 1))
  fi
done

printf 'monthly-build: line %s, %s steps attempted, %s failed, %s skipped\n' "$line" "$ran" "$failed" "$skipped"
printf 'monthly-build: manifest %s\n' "$manifest"

if [ "$failed" -ne 0 ]; then
  exit 1
fi
exit 0
