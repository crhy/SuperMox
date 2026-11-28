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

# The SuperMox_* paths and their portable defaults (never a machine's own disk).
# shellcheck disable=SC1091
source "$repo_root/scripts/local-env.sh"

# name|command|kind   (kind: offline | vm). Order is the run order.
STEPS=(
  'upstream-pins|bash scripts/check-overrides.sh|offline'
  'no-systemd|bash scripts/check-no-systemd.sh --source .|offline'
  'python-tests|bash tests/test-python.sh|offline'
  'init-scripts|bash tests/test-init-scripts.sh|offline'
  # f289: the init-scripts step above is only a LINT (sh -n, LSB header fields,
  # start/stop cases, no bare systemd text). The behavioural init-* steps below
  # actually exercise each service script's behaviour offline against fake
  # helpers under build/, so a whole month cannot drift while a service script
  # regresses. The three environment FAILs (test-build-iso.sh,
  # test-init-sync.sh, test-supermox-ve.sh) stay out until their build
  # prerequisites exist; test-init-sync.sh is not test-init-sync-flags.sh.
  'init-cgroups|bash tests/test-init-cgroups.sh|offline'
  'init-corosync|bash tests/test-init-corosync.sh|offline'
  'init-hosts|bash tests/test-init-hosts.sh|offline'
  'init-joind|bash tests/test-init-joind.sh|offline'
  'init-networking|bash tests/test-init-networking.sh|offline'
  'init-pve-cluster|bash tests/test-init-pve-cluster.sh|offline'
  'init-waydroid|bash tests/test-init-waydroid.sh|offline'
  'init-wg|bash tests/test-init-wg.sh|offline'
  'init-sync-flags|bash tests/test-init-sync-flags.sh|offline'
  'repo-layout|bash tests/test-repo-layout.sh|offline'
  'iso-prepare|bash scripts/build-iso.sh --prepare-only|offline'
  # f250: the newer 11.26 offline checks, every offline tests/test-*.sh that a
  # step above does not already run.
  'android-setup|bash tests/test-android-setup.sh|offline'
  'waydroid-session|bash tests/test-waydroid-session.sh|offline'
  'apt-repo|bash tests/test-apt-repo.sh|offline'
  'arch|bash tests/test-arch.sh|offline'
  'branding|bash tests/test-branding.sh|offline'
  'build-deps-report|bash tests/test-build-deps-report.sh|offline'
  'build-rootfs|bash tests/test-build-rootfs.sh|offline'
  'check-services|bash tests/test-check-services.sh|offline'
  'check-sh|bash tests/test-check-sh.sh|offline'
  'dhcp-client-port|bash tests/test-dhcp-client-port.sh|offline'
  'fetch-upstream|bash tests/test-fetch-upstream.sh|offline'
  'firewall-rules|bash tests/test-firewall-rules.sh|offline'
  'install-checkout|bash tests/test-install-checkout.sh|offline'
  'uninstall-checkout|bash tests/test-uninstall-checkout.sh|offline'
  'update-checkout|bash tests/test-update-checkout.sh|offline'
  'join-e2e|bash tests/test-join-e2e.sh|offline'
  'lan-cluster-e2e|bash tests/test-lan-cluster-e2e.sh|offline'
  'local-env|bash tests/test-local-env.sh|offline'
  'monthly-build-selftest|bash tests/test-monthly-build.sh|offline'
  'node-caps|bash tests/test-node-caps.sh|offline'
  'patches|bash tests/test-patches.sh|offline'
  'proxmox-systemd-crate|bash tests/test-proxmox-systemd-crate.sh|offline'
  'proxmox-systemd-pkg|bash tests/test-proxmox-systemd-pkg.sh|offline'
  'pve-manager-sources|bash tests/test-pve-manager-sources.sh|offline'
  'reap-orphans|bash tests/test-reap-orphans.sh|offline'
  'release-check|bash tests/test-release-check.sh|offline'
  'supermox-binfmt|bash tests/test-supermox-binfmt.sh|offline'
  'supermox-dhcp-client|bash tests/test-supermox-dhcp-client.sh|offline'
  'supermox-manager|bash tests/test-supermox-manager.sh|offline'
  'supermox-tmpfiles|bash tests/test-supermox-tmpfiles.sh|offline'
  'sync-live|bash tests/test-sync-live.sh|offline'
  'sysvservice|bash tests/test-sysvservice.sh|offline'
  'check-overrides|bash tests/test-check-overrides.sh|offline'
  'drift-sync|bash tests/test-drift-sync.sh|offline'
  'upstream-drift-check|bash tests/test-upstream-drift-check.sh|offline'
  'vm-boot-iso|bash tests/test-vm-boot-iso.sh|offline'
  'vm-build-tooling|bash tests/test-vm-build-tooling.sh|offline'
  'vm-lan-pair|bash tests/test-vm-lan-pair.sh|offline'
  'vm-scripts|bash tests/test-vm-scripts.sh|offline'
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

# f289: the behavioural init-* steps run each service script offline against fake
# helpers under build/, so each probe just succeeds (offline, like the other
# offline probes); the recorded line stays whatever the test really measured.
prereq_init_cgroups() { return 0; }
prereq_init_corosync() { return 0; }
prereq_init_hosts() { return 0; }
prereq_init_joind() { return 0; }
prereq_init_networking() { return 0; }
prereq_init_pve_cluster() { return 0; }
prereq_init_waydroid() { return 0; }
prereq_init_wg() { return 0; }
prereq_init_sync_flags() { return 0; }
prereq_repo_layout() { return 0; }

# The f250 offline checks need nothing beyond the checkout: each test skips
# honestly inside when its own extra prerequisite is missing (no upstream
# tree, no xorriso, no syncthing, no VM), so the probe succeeds and the
# recorded line stays whatever the test really measured.
prereq_android_setup() { return 0; }
prereq_waydroid_session() { return 0; }
prereq_apt_repo() { return 0; }
prereq_arch() { return 0; }
prereq_branding() { return 0; }
prereq_build_deps_report() { return 0; }
prereq_build_rootfs() { return 0; }
prereq_check_services() { return 0; }
prereq_check_sh() { return 0; }
prereq_dhcp_client_port() { return 0; }
prereq_fetch_upstream() { return 0; }
prereq_firewall_rules() { return 0; }
prereq_install_checkout() { return 0; }
prereq_join_e2e() { return 0; }
prereq_lan_cluster_e2e() { return 0; }
prereq_local_env() { return 0; }
prereq_monthly_build_selftest() { return 0; }
prereq_node_caps() { return 0; }
prereq_patches() { return 0; }
prereq_proxmox_systemd_crate() { return 0; }
prereq_proxmox_systemd_pkg() { return 0; }
prereq_pve_manager_sources() { return 0; }
prereq_reap_orphans() { return 0; }
prereq_release_check() { return 0; }
prereq_supermox_binfmt() { return 0; }
prereq_supermox_dhcp_client() { return 0; }
prereq_supermox_manager() { return 0; }
prereq_supermox_tmpfiles() { return 0; }
prereq_sync_live() { return 0; }
prereq_sysvservice() { return 0; }
prereq_uninstall_checkout() { return 0; }
prereq_update_checkout() { return 0; }
prereq_check_overrides() { return 0; }
prereq_drift_sync() { return 0; }
prereq_upstream_drift_check() { return 0; }
prereq_vm_boot_iso() { return 0; }
prereq_vm_build_tooling() { return 0; }
prereq_vm_lan_pair() { return 0; }
prereq_vm_scripts() { return 0; }

# SUPERMOX_SPACED_REPO and SUPERMOX_TEST_DIR come from scripts/local-env.sh
# (exported value > config/local.env > the portable default under build/), the
# same three levels every other script here uses.
prereq_iso_prepare() {
  if [ ! -d "$SUPERMOX_SPACED_REPO" ]; then
    printf 'SUPERMOX_SPACED_REPO is not a checkout: %s\n' "$SUPERMOX_SPACED_REPO"
    return 1
  fi
  return 0
}

prereq_vm_install() {
  if ! command -v sshpass >/dev/null 2>&1; then
    printf 'sshpass not installed\n'
    return 1
  fi
  if [ ! -d "$SUPERMOX_TEST_DIR" ]; then
    printf 'SUPERMOX_TEST_DIR absent: %s\n' "$SUPERMOX_TEST_DIR"
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
