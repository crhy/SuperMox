# Cluster core join — facts

Task `c02-cluster-core-join-facts`. This document records what is *known* about
turning a joined LAN node into a real PVE (corosync) cluster member: what the
live test VM actually does today, how upstream performs the join, what SuperMox
has already changed, and where the gap is. It is facts plus design constraints,
not an implementation plan.

"Core member" means: the node appears in `/etc/corosync/corosync.conf`'s
`nodelist`, shares the cluster's corosync authentication key and cluster name,
and therefore shares `/etc/pve` through `pmxcfs`. Anything less (today's LAN
join) is an *edge* node: it knows about the cluster through SuperMox's own
join protocol but has its own, private `/etc/pve`.

---

## 1. Live VM evidence

Reproduce with:

```
SUPERMOX_VM_DIR=build/test-data SUPERMOX_VM_SSH_PORT=2224 \
  bash scripts/vm-start.sh --background
SUPERMOX_VM_DIR=build/test-data SUPERMOX_VM_SSH_PORT=2224 \
  bash scripts/vm-ssh.sh -q -o StrictHostKeyChecking=no '<commands>'
```

The VM disk under `build/test-data` persists across stop/start, so some artefacts
below were created by an earlier session.

### 1.1 Identity and package versions

```
hostname                       -> supermox
dpkg -l corosync pve-cluster   -> corosync 3.1.10-5
                               pve-cluster 9.1.7+supermox2
dpkg -l supermox-ve            -> supermox-ve 0.1.19
```

The tree is at `supermox-ve 0.1.23` (`packaging/supermox-ve/debian/changelog`),
so **the test VM image predates f34**: `supermox-corosync` is not installed there.

```
invoke-rc.d supermox-corosync status
  -> invoke-rc.d: unknown initscript, /etc/init.d/supermox-corosync not found.
     (rc=4)
dpkg -L supermox-ve | grep init.d
  -> /etc/init.d/{networking,supermox-binfmt,supermox-cgroups,supermox-hosts,
     supermox-joind,supermox-sync,supermox-wg}
```

`packaging/supermox-ve/debian/rules:68` does ship `dh_installinit --name=supermox-corosync`;
the VM simply has an older build. So every corosync fact below comes from the
**old** path: `patches/pve-cluster/0005-single-node-corosync.patch`'s
`setup_single_node_cluster()` in the pve-cluster postinst, not from the boot script.

### 1.2 The single-node corosync config

`/etc/corosync/corosync.conf` (as written by the patched postinst at install time):

- `cluster_name: supermox`, one node, `name: supermox`, `nodeid: 1`
- `ring0_addr: 10.0.2.15` — the DHCP address of the VM at *install* time
- `secauth: off`
- `mcastport: 5405`

Live confirmation from corosync's own config map:

```
corosync-cmapctl | grep -E 'nodelist|cluster.name|mcastport'
  nodelist.local_node_pos (u32) = 0
  nodelist.node.0.name (str) = supermox
  nodelist.node.0.nodeid (u32) = 1
  nodelist.node.0.quorum_votes (u32) = 1
  nodelist.node.0.ring0_addr (str) = 10.0.2.15
  runtime.config.totem.interface.0.mcastport (u16) = 5405
  totem.cluster_name (str) = supermox
```

`/etc/corosync/authkey` **does not exist** (checked `/etc/corosync/` and `/etc/pve/`).
A single-node SuperMox cluster therefore runs with `secauth: off` — upstream's
`PVE::Corosync::create_conf` defaults to `secauth: on` (see §2.4).

Earlier in the same VM (before the mount wedge in §1.4), `pvecm status` reported
cluster `supermox`, 1 node, quorate, `secauth: off`.

### 1.3 `pvecm` is present and sysv-patched

```
which pvecm -> /usr/bin/pvecm
pvecm       -> usage, rc=0        (pvecm --help -> rc=255, "not supported")
```

`patches/pve-cluster/0001-sysvservice-callers.patch` rewrites its `systemctl`
calls (and those in `Setup.pm`) to `PVE::SysvService`.

### 1.4 Service state is broken in this VM — and the mechanism is reproducible

Observed after a stop/start cycle:

```
ps -C pmxcfs            -> two pmxcfs processes (1800, 1802), 10:31 elapsed
ls -l /proc/1800/fd     -> fd 8 -> /dev/fuse   (both hold the FUSE mount)
findmnt /etc/pve        -> /dev/fuse on /etc/pve type fuse
cat /run/pve-cluster.pid-> No such file or directory
invoke-rc.d pve-cluster status
  -> "pve-cluster is not running ... failed!"   rc=3
timeout 20 ls /etc/pve  -> rc=124 (hangs; every /etc/pve read blocks)
timeout 20 ls /etc/pve/nodes -> rc=124
pmxcfs -l -> "resolved node name 'supermox' to '10.0.2.15'"
            "unable to acquire pmxcfs lock - trying again"
```

The mechanism, from `init.d/pve-cluster`:

```
start) ... start-stop-daemon --start --quiet --pidfile "$PIDFILE" --exec "$DAEMON"
stop)  start-stop-daemon --stop --quiet --pidfile "$PIDFILE" --retry TERM/10/KILL/5
```

`pmxcfs` daemonises itself, and the `--stop` line has no `--exec` fallback, so
`stop` can only name a process through a pidfile:

```
start-stop-daemon --stop --quiet --pidfile /run/pve-cluster.pid --retry TERM/10/KILL/5
  -> rc=1, and pgrep -c pmxcfs is still 2
```

Re-measured in the `build/test-data` VM (image 0.1.19, start-stop-daemon 1.23.11)
after the fix was written, two claims above had to be corrected and one new one
turned up:

- `pmxcfs` *does* write a pidfile. `CFS_PID_FN` is `/var/run/pve-cluster.pid`
  (`upstream/pxvirt/packages/pve-cluster/pve-cluster/src/cfs-utils.h`), and
  `/var/run` is a symlink to `/run`, so after `invoke-rc.d pve-cluster start`,
  `/run/pve-cluster.pid` exists and holds the live pid. The `No such file` line
  above was read at a moment when no pmxcfs was alive.
- `restart` does not start a second pmxcfs here: with one already running the
  old `--start` line prints `(warning)` and exits 1, and `pgrep -c pmxcfs` stays
  1. The two-instance state above was real but has not been reproduced since.
- New: `start-stop-daemon --stop` given a `--pidfile` that does not exist stops
  nothing *even when `--exec` is also given*. A fix that passes both flags does
  not work; it must match by executable alone.

What does reproduce, with the pidfile missing or stale while pmxcfs runs: `stop`
prints `failed!` (rc=1) and leaves pmxcfs running, and `status` returns 3 while
pmxcfs runs. That is the proven defect, and it is enough on its own: `PVE::SysvService::stop`
dies on a nonzero rc, so the join path aborts (see §3). Causation of the wedged
mount is inferred, not proven.

---

## 2. How upstream performs the join

All paths below are in the read-only `upstream/pxvirt` tree.

### 2.1 `pvecm add` runs on the *new* node

`packages/pve-cluster/pve-cluster/src/PVE/Cluster/Setup.pm:681` (`sub join`):

1. `remote_node_ip($nodename)` for the local address, `extract_corosync_link_args`.
2. `assert_joinable($local_ip_address, $links, $force)` (`Setup.pm:625`).
3. `setup_sshd_config / setup_rootsshconfig / setup_ssh_keys / ssh_unmerge_known_hosts`.
4. HTTPS API login to the existing cluster (`PVE::APIClient::LWP`, port 8006,
   `root@pam`, cert fingerprint or manual verification).
5. `GET /cluster/config/apiversion`, then `assert_we_can_join_cluster_version`.
6. `POST /cluster/config/nodes/<nodename>` with `link<N>`/`new_node_ip`, `nodeid`,
   `votes`, `apiversion`.
7. `finish_join($nodename, res->{corosync_conf}, res->{corosync_authkey})`.

So the *existing* cluster decides the config; the new node only receives it.

### 2.2 `assert_joinable` preconditions (`Setup.pm:625`)

Refuses (unless `force`) when:

- `/etc/corosync/authkey` already exists;
- `/etc/corosync/corosync.conf` already exists;
- the host already contains virtual guests (`get_vmlist`);
- `corosync-quorumtool -l` exits 0, i.e. corosync is already running;
- any ring IP is not present on a local interface:
  `PVE::Network::get_local_ip_from_cidr("$ip/32" or "$ip/128")` must return ≥ 1
  address (`Net::IP::ip_is_ipv6` picks the CIDR width).

The last check is the one that couples corosync membership to real, kernel-known
addresses — directly relevant to a WireGuard overlay address (§4).

### 2.3 `addnode` on the cluster side

`packages/pve-cluster/pve-cluster/src/PVE/API2/ClusterConfig.pm:230`
(`name => 'addnode'`). It returns, at `ClusterConfig.pm:456`:

```perl
corosync_authkey => PVE::Tools::file_get_contents($authfile),
corosync_conf    => PVE::Tools::file_get_contents($clusterconf),
warnings         => $vc_warnings,
```

The nodelist edit is done under a config-change lock and applied through
`PVE::Corosync::update_nodelist($conf, $nodelist)` (`Corosync.pm:235`);
`verify_conf` errors/warnings are surfaced as `error`/`warning` keys.

### 2.4 `PVE::Corosync` facts

- `create_conf` (`Corosync.pm:271`) writes `secauth: on` — SuperMox's generated
  config says `secauth: off` (§1.2).
- `verify_conf` (`Corosync.pm:335`) validates link topology and addresses.
- `resolve_hostname_like_corosync` (`Corosync.pm:475`) mirrors corosync's
  resolution order from `totem.ip_version`: `ipv4`, `ipv6`, `ipv6-4`,
  `ipv4-6` (default `ipv6-4`). IPv6 addresses are first-class: `ip_is_ipv6`
  from `Net::IP` at `Corosync.pm:8`, and `check_ip_link` (`Corosync.pm:451`)
  skips candidates whose family differs from the configured `ip_version`.

### 2.5 `finish_join` (`Setup.pm:779`)

1. `mkdir $localclusterdir`; write `$authfile` and `$localclusterconf` (the
   pre-mount copies pmxcfs picks up at start).
2. **stop pve-cluster** (upstream `systemctl stop pve-cluster`).
3. `cfs_backup_database()` then `cfs_unlink_db_unsafe()` (replace the local
   pmxcfs state DB so the new config is authoritative).
4. **start corosync and pve-cluster** (upstream `systemctl start corosync pve-cluster`).
5. Loop on `check_cfs_quorum(1)` until quorum.
6. `generate_local_files()`; `updatecerts_and_ssh(1)` — node certificate,
   merged authorized_keys, per-node known_hosts, vzdump files.
7. `reload-or-restart pvedaemon pveproxy`.

---

## 3. What SuperMox already changes on this path

- `patches/pve-cluster/0001-sysvservice-callers.patch` rewrites all four
  `systemctl` sites in `Setup.pm` (`sshd`, `stop pve-cluster`,
  `start corosync pve-cluster`, `reload-or-restart pvedaemon pveproxy`) to
  `PVE::SysvService`, and drops `corosync-qdevice` start/enable/stop/disable
  from `PVE/CLI/pvecm.pm`.
- `patches/pve-common/0001-sysvservice.patch` defines `PVE::SysvService`:
  `start`/`stop`/`restart`/`reload` invoke `/etc/init.d/<name> <action>`
  directly (`PVE_SYSV_INITD_DIR` overrides the dir); `is_running` is
  `<script> status` rc == 0; `reload_or_restart` greps the script for a
  `reload)` arm.
- **Consequence, measured:** `PVE::SysvService::stop('pve-cluster')` runs
  `init.d/pve-cluster stop`, which is a no-op returning rc=1 whenever the pidfile
  is missing or stale (§1.4). Our
  patched `finish_join` wraps that call in
  `eval { ... }; if ($@) { die "can't stop pve-cluster service" }`, and
  `PVE::Tools::run_command` dies on nonzero rc. **Upstream's join path therefore
  aborts on a SuperMox node today**, before it ever reaches the config swap.
  `is_running('pve-cluster')` is likewise wrong (rc=3 while running), so
  `try_reload_or_restart` skips a service that is up.
- Boot ordering already anticipates the cluster: `init.d/pve-cluster`'s LSB
  header says `Required-Start: $network $time corosync supermox-corosync`, and
  `init.d/supermox-hosts` orders `supermox-corosync` before `corosync`
  (changelog entries in `packaging/supermox-ve/debian/changelog`, 0.1.22).
  The test VM (0.1.19) does not have that script yet (§1.1).
- `init.d/supermox-corosync` writes the single-node config at boot and
  deliberately leaves a *foreign* (multi-node) config alone — i.e. it already
  refuses to clobber a joined cluster's `corosync.conf`.
- `secauth: off` in our generated config vs upstream `secauth: on`
  (§1.2 / §2.4). `assert_joinable` treats an existing `authkey` as "already
  joined", so a SuperMox node that later wants a keyed cluster starts from a
  different state than upstream's.

---

## 4. The gap: joined LAN node → core member

What exists today is the *edge* path only:

- `src/supermox/joind.py:812` `apply_join_ack(state, ack)` — "adopt the
  membership list from a JOIN_ACK"; the ACK MAC under `join_key` authenticates
  the sender. Nothing here touches corosync, `/etc/corosync/`, or `pmxcfs`.
- `bin/supermox-join:131/142/144` — `join_invite`/`join_phrase` then
  `apply_join_ack(st, ack)`.
- `joind.py:140` `seal_for_joiner(...)` — membership/invite sealing for joiners.
- `docs/node-join-architecture.md` — the 12-word secret / QR join design.

Facts that constrain any core-join step:

1. **Transport of trust.** Upstream moves the authkey and `corosync.conf` over
   an authenticated HTTPS API session (`root@pam`, cert fingerprint, port 8006).
   SuperMox's join channel authenticates with a 12-word secret / `join_key` MAC
   and has no PVE credentials. Whatever carries `corosync_authkey` must be
   authenticated at least as strongly as the join protocol already is.
2. **`assert_joinable` will refuse a running node.** A LAN-joined node that is
   already a single-node cluster (own `corosync.conf`, corosync running,
   guests possibly defined) fails four of its checks. Upstream's answer is
   "the new node must be empty"; that does not describe a SuperMox joiner.
3. **Restart correctness is a prerequisite.** §1.4 + §3: `pve-cluster` could
   not be stopped or reported on. Fixed in `init.d/pve-cluster` (§5 item 1);
   any core join still has to keep that property, because `finish_join` dies
   on a failed stop and a second pmxcfs wedges `/etc/pve`.
4. **Address family and interface.** corosync resolves `ringN_addr` itself,
   with family order set by `totem.ip_version` (`Corosync.pm:475`), and
   `assert_joinable` requires the address to be present on a local interface
   (`get_local_ip_from_cidr`). Whether the WireGuard overlay address is visible
   to that check, and whether corosync must be told to bind the overlay
   interface, is **not yet measured** — it is the first thing to measure before
   any design is settled.
5. **Config merge, not config handover.** Upstream's new node accepts the
   cluster's whole `corosync.conf` verbatim. A joiner that already has its own
   single-node file (and a boot script that rewrites it when hostname/DHCP
   address change) needs an explicit rule for which file wins and how
   `config_version` advances. `init.d/supermox-corosync` already has the
   "leave foreign configs alone" half of that rule.
6. **Quorum and RTT.** `finish_join` blocks on `check_cfs_quorum`; corosync's
   token timeouts are visible in the VM's syslog
   (`[TOTEM] Token has not been received in 2250 ms`,
   `Corosync main process was not scheduled ... Consider token timeout increase`)
   on a 2 GB amd64 KVM VM. A phone-class joiner is a much weaker device; the
   join protocol's sub-5 ms budget is a different budget from corosync's token
   budget, and both have to be met.

---

## 5. Open questions to settle next

1. ~~Fix and re-measure `init.d/pve-cluster`~~ **done.** `init.d/pve-cluster`
   now matches pmxcfs by executable (`--stop --exec`, no `--pidfile`), refuses
   a second start, waits for the `/etc/pve` mount, clears a mount left by a
   dead pmxcfs, and returns LSB 0 only when pmxcfs runs *and* `/etc/pve` is
   mounted. Covered by `tests/test-init-pve-cluster.sh` (offline, stubbed
   `pmxcfs`/`findmnt`/`start-stop-daemon`) and by the live runs recorded in
   `build/live-*.log`. Changelog entry 0.1.23; the script ships through
   `config/init-scripts.txt`, which makes `apply-patches.sh` copy it to
   `debian/pve-cluster.pve-cluster.init` in the pve-cluster package (verified
   byte-identical in `build/patched/`). Re-measured in the VM: three `restart`s
   in a row leave exactly one pmxcfs, `ls /etc/pve` returns, `status` is 0
   running and 3 stopped, and a fresh boot of the same disk comes up with one
   pmxcfs, a pidfile matching it, `status` 0 and `storage.cfg` visible inside
   the mount. Note for the harness: `reboot` inside the VM ends qemu
   (`scripts/vm-start.sh` passes no `-action reboot`), and `vm-start.sh` execs
   qemu in the foreground, so start it in the background and poll SSH. The
   join-path primitive that died before now works in the VM: `PVE::SysvService::stop('pve-cluster')`
   followed by `start` returns cleanly, leaves one pmxcfs and a readable
   `/etc/pve`, and `PVE::SysvService::is_running('pve-cluster')` reports 1.
2. Does `PVE::Network::get_local_ip_from_cidr` see the overlay address, and
   does corosync 3.1.10 accept an IPv6 `ring0_addr` pointing at the overlay
   (`totem.ip_version: ipv6` / `ipv4-6`)? Measure, don't assume.
3. Where does the authkey cross the join channel, and under which key?
   (`src/supermox/secret.py` / `join_key` vs corosync's 2048-bit key file.)
4. What is the intended relationship between `config_version` in
   `/etc/corosync/corosync.conf` and SuperMox's own membership state, so a
   reboot on either side cannot resurrect a stale nodelist?
5. Is a phone-class joiner ever a *core* member at all, or always an edge node
   with a read-only view of cluster state? (Decide before implementing 3–4.)
