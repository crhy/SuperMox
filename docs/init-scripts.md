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

## Translation rules applied

- `After=`/`Requires=` become `Required-Start:` (and mirrored into `Required-Stop:`).
- `network.target` -> `$network`, `time-sync.target` -> `$time`; `*.mount` and
  `systemd-*` entries dropped; other `X.service` -> `X`. `RequiresMountsFor=/path`
  -> `$localfs` (local filesystems must be mounted).
- `Wants=`, `Before=`, `Conflicts=`, `DefaultDependencies=` are not hard ordering
  deps and are not carried into `Required-Start:`.
- Pidfile taken from each unit's `PIDFile=` (matches `PVE::Daemon` default
  `/var/run/${name}.pid`; `/run` is the modern path).
