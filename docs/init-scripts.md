# init.d scripts

Sysvinit service scripts under `init.d/`, translated from the upstream
PXVIRT systemd units. POSIX `/bin/sh`, LSB headers, `start-stop-daemon`.
No `systemctl`/`systemd`/`sd_notify`/`journalctl` in any script.

| Script | From unit | Required-Start | Pidfile | Notes |
| --- | --- | --- | --- | --- |
| pve-cluster | pve-cluster/debian/pve-cluster.service | `$network $time rrdcached` | /run/pve-cluster.pid | `mkdir -p /etc/pve` before start; `start-stop-daemon --start --exec /usr/bin/pmxcfs`; stop uses `--retry TERM/10/KILL/5` (unit TimeoutStopSec=10). Dropped `sys-fs-fuse-connections.mount`. |
| pvedaemon | pve-manager/services/pvedaemon.service | `corosync pve-cluster` | /run/pvedaemon.pid | start/stop/reload call `/usr/bin/pvedaemon start|stop|restart` exactly; `status` uses `start-stop-daemon --status --pidfile`. |
| pveproxy | pve-manager/services/pveproxy.service | `pve-cluster pvedaemon ssh` | /run/pveproxy/pveproxy.pid | start runs ExecStartPre `/usr/bin/pvecm updatecerts --silent` and ExecStartPost `[ ! -e /var/log/pveam.log ] && /usr/bin/pveupdate` (both error-tolerant, matching the `-` prefix); start/stop/reload call `/usr/bin/pveproxy start|stop|restart`. Dropped `pve-storage.target` (PVE meta-target, no sysvinit service). |
| spiceproxy | pve-manager/services/spiceproxy.service | `pveproxy` | /run/pveproxy/spiceproxy.pid | start/stop/reload call `/usr/bin/spiceproxy start|stop|restart` exactly; `status` uses `start-stop-daemon --status --pidfile`. Dropped `Wants=pveproxy.service` (Wants is not a hard ordering dep). |
| pvestatd | pve-manager/services/pvestatd.service | `pve-cluster pvenetcommit` | /run/pvestatd.pid | start/stop/reload call `/usr/bin/pvestatd start|stop|restart` exactly. Dropped `Wants=pve-cluster.service`. |
| pvescheduler | pve-manager/services/pvescheduler.service | `pve-cluster pve-guests` | /run/pvescheduler.pid | start/stop/reload call `/usr/bin/pvescheduler start|stop|restart` exactly. Dropped `Wants=pve-cluster.service` and `pve-storage.target` (PVE meta-target). `KillMode=process` noted (only the main pid is signalled, which `--pidfile` already does). |
| qmeventd | qemu-server/src/qmeventd/qmeventd.service | `$localfs` | /run/qmeventd.pid | does not fork itself: start uses `start-stop-daemon --start --background --make-pidfile --exec /usr/sbin/qmeventd -- /var/run/qmeventd.sock`; stop uses `--stop --pidfile`. `Before=` deps not carried; `RequiresMountsFor=/var/run` -> `$localfs`. |
| pvefw-logger | pve-firewall/debian/pvefw-logger.service | `$localfs` | /run/pvefw-logger.pid | Type=forking, no ExecStop: stop uses `start-stop-daemon --stop --retry TERM/5/KILL/5 --pidfile` (unit TimeoutStopSec=5). `After=local-fs.target` -> `$localfs`. Dropped `DefaultDependencies=no`, `Before=shutdown.target`, `Conflicts=shutdown.target`. |
| pve-firewall | pve-firewall/debian/pve-firewall.service | `pvefw-logger pve-cluster $network kmod` | /run/pve-firewall.pid | start runs three ExecStartPre `update-alternatives --set` commands (error-tolerant, matching `-` prefix); start/stop/reload call `/usr/sbin/pve-firewall start|stop|restart`. `systemd-modules-load.service` -> `kmod`. Dropped `Wants=`, `DefaultDependencies=no`, `Before=shutdown.target`, `Conflicts=shutdown.target`. |
| watchdog-mux | pve-ha-manager/debian/watchdog-mux.service | `$localfs` | /run/watchdog-mux.pid | does not fork itself: start uses `start-stop-daemon --start --background --make-pidfile --exec /usr/sbin/watchdog-mux`; stop uses `--stop --pidfile`. No After/Requires deps in unit. `OOMScoreAdjust=-1000` not expressible in sysvinit. `Restart=no` noted. `EnvironmentFile=-/etc/default/pve-ha-manager` not carried. |
| pve-ha-crm | pve-ha-manager/debian/pve-ha-crm.service | `corosync pve-cluster pvedaemon watchdog-mux syslog` | /run/pve-ha-crm.pid | start/stop call `/usr/sbin/pve-ha-crm start|stop` exactly. `TimeoutStopSec=65` noted. Dropped `Wants=pve-cluster.service`, `Wants=watchdog-mux.service`, `Wants=pvedaemon.service`. |
| pve-ha-lrm | pve-ha-manager/debian/pve-ha-lrm.service | `corosync lxc pve-cluster pve-ha-crm pvedaemon pveproxy ssh syslog watchdog-mux` | /run/pve-ha-lrm.pid | start/stop call `/usr/sbin/pve-ha-lrm start|stop` exactly. `TimeoutStopSec=infinity` noted (no timeout on stop). `KillMode=process` noted (only main pid signalled, which `--pidfile` already does). Dropped `Wants=` entries and `pve-storage.target` (PVE meta-target). |

## Translation rules applied

- `After=`/`Requires=` become `Required-Start:` (and mirrored into `Required-Stop:`).
- `network.target` -> `$network`, `time-sync.target` -> `$time`; `*.mount` and
  `systemd-*` entries dropped; other `X.service` -> `X`. `RequiresMountsFor=/path`
  -> `$localfs` (local filesystems must be mounted).
- `Wants=`, `Before=`, `Conflicts=`, `DefaultDependencies=` are not hard ordering
  deps and are not carried into `Required-Start:`.
- Pidfile taken from each unit's `PIDFile=` (matches `PVE::Daemon` default
  `/var/run/${name}.pid`; `/run` is the modern path).
