# systemd inventory

Totals: units=30, code references=96, control lines=4

## Units

| Component | Unit file | Type= | ExecStart= | Requires/After= |
| --- | --- | --- | --- | --- |
| pve-cluster | debian/pve-cluster.service | forking | /usr/bin/pmxcfs | network.target sys-fs-fuse-connections.mount time-sync.target rrdcached.service |
| pve-container | src/pve-container-debug@.service | simple | /usr/bin/lxc-start -F -n %i -o /dev/stderr -l DEBUG | lxc.service |
| pve-container | src/pve-container@.service | simple | /usr/bin/lxc-start -F -n %i | lxc.service |
| pve-container | src/test/test-opensuse-001/usr/lib/systemd/system/container-getty@.service | idle | -/sbin/agetty --noclear --keep-baud lxc/tty%I 115200,38400,9600 $TERM | systemd-user-sessions.service plymouth-quit-wait.service rc-local.service |
| pve-container | src/test/test-opensuse-003/usr/lib/systemd/system/container-getty@.service | idle | -/sbin/agetty --noclear --keep-baud lxc/tty%I 115200,38400,9600 $TERM | systemd-user-sessions.service plymouth-quit-wait.service rc-local.service |
| pve-container | src/test/test-opensuse-004/usr/lib/systemd/system/container-getty@.service | idle | -/sbin/agetty -o '-p -- \\u' --noclear --keep-baud pts/%I 115200,38400,9600 $TER | systemd-user-sessions.service plymouth-quit-wait.service rc-local.service |
| pve-container | src/test/test-opensuse-005/usr/lib/systemd/system/container-getty@.service | idle | -/sbin/agetty -o '-p -- \\u' --noclear --keep-baud pts/%I 115200,38400,9600 $TER | systemd-user-sessions.service plymouth-quit-wait.service rc-local.service |
| pve-container | src/test/test-opensuse-slowroll-001/usr/lib/systemd/system/container-getty@.service | idle | -/sbin/agetty --noclear --keep-baud lxc/tty%I 115200,38400,9600 $TERM | systemd-user-sessions.service plymouth-quit-wait.service rc-local.service |
| pve-firewall | debian/pve-firewall.service | forking | /usr/sbin/pve-firewall start | pvefw-logger.service pve-cluster.service network.target systemd-modules-load.service |
| pve-firewall | debian/pvefw-logger.service | forking | /usr/sbin/pvefw-logger | local-fs.target |
| pve-ha-manager | debian/pve-ha-crm.service | forking | /usr/sbin/pve-ha-crm start | pve-cluster.service corosync.service pvedaemon.service watchdog-mux.service syslog.service |
| pve-ha-manager | debian/pve-ha-lrm.service | forking | /usr/sbin/pve-ha-lrm start | corosync.service lxc.service pve-cluster.service pve-ha-crm.service pve-storage.target pvedaemon.service pveproxy.service ssh.service syslog.service watchdog-mux.service |
| pve-ha-manager | debian/watchdog-mux.service |  | /usr/sbin/watchdog-mux |  |
| pve-manager | services/pve-daily-update.service | oneshot | /usr/bin/pveupdate | network-online.target pve-cluster.service |
| pve-manager | services/pve-daily-update.timer |  |  |  |
| pve-manager | services/pve-firewall-commit.service | oneshot | /usr/share/pve-manager/helpers/pve-firewall-commit | corosync.service |
| pve-manager | services/pve-guests.service | oneshot | /usr/bin/pvesh --nooutput create /nodes/localhost/startall | pveproxy.service pvestatd.service spiceproxy.service pve-firewall.service lxc.service pve-ha-crm.service pve-ha-lrm.service |
| pve-manager | services/pve-query-machine-info.service | oneshot | /usr/bin/query-machine-info |  |
| pve-manager | services/pve-sdn-commit.service | oneshot | /usr/share/pve-manager/helpers/pve-sdn-commit | frr.service network.target corosync.service |
| pve-manager | services/pve-storage.target |  |  | remote-fs.target ceph.target ceph-mon.target ceph-osd.target ceph-mds.target ceph-mgr.target glusterd.service open-iscsi.service |
| pve-manager | services/pvebanner.service | oneshot | /usr/bin/pvebanner | local-fs.target |
| pve-manager | services/pvedaemon.service | forking | /usr/bin/pvedaemon start | corosync.service pve-cluster.service |
| pve-manager | services/pvenetcommit.service | oneshot | sh -c 'if [ -f ${FN}.new ]; then mv ${FN}.new ${FN}; fi' | local-fs.target |
| pve-manager | services/pveproxy.service | forking | /usr/bin/pveproxy start | pve-storage.target pve-cluster.service pvedaemon.service ssh.service |
| pve-manager | services/pvescheduler.service | forking | /usr/bin/pvescheduler start | pve-cluster.service pve-guests.service pve-storage.target |
| pve-manager | services/pvestatd.service | forking | /usr/bin/pvestatd start | pve-cluster.service pvenetcommit.service |
| pve-manager | services/spiceproxy.service | forking | /usr/bin/spiceproxy start | pveproxy.service |
| qemu-server | src/qmeventd/qmeventd.service | forking | /usr/sbin/qmeventd /var/run/qmeventd.sock |  |
| qemu-server | src/query-machine-capabilities/pve-query-machine-capabilities.service | oneshot | /usr/libexec/qemu-server/query-machine-capabilities |  |
| qemu-server | src/usr/pve-dbus-vmstate@.service | simple | /usr/libexec/qemu-server/dbus-vmstate %i | dbus.socket dbus.socket |

## Code references

| Component | File | Line | Match |
| --- | --- | --- | --- |
| proxmox-ve | debian/control | 21 | systemd-sysv, |
| pve-cluster | src/PVE/API2/ClusterConfig.pm | 231 | PVE::Tools::run_command('systemctl restart corosync pve-cluster'); |
| pve-cluster | src/PVE/CLI/pvecm.pm | 279 | [@$ssh_cluster_cmd, '--', 'systemctl', 'start', 'corosync-qdevice'], |
| pve-cluster | src/PVE/CLI/pvecm.pm | 283 | [@$ssh_cluster_cmd, '--', 'systemctl', 'enable', 'corosync-qdevice'], |
| pve-cluster | src/PVE/CLI/pvecm.pm | 343 | run_command([@$ssh_cluster_cmd, '--', 'systemctl', 'stop', 'corosync-qdevice']); |
| pve-cluster | src/PVE/CLI/pvecm.pm | 344 | run_command([@$ssh_cluster_cmd, '--', 'systemctl', 'disable', 'corosync-qdevice']); |
| pve-cluster | src/PVE/Cluster/Setup.pm | 155 | PVE::Tools::run_command(['systemctl', 'reload-or-restart', 'sshd']); |
| pve-cluster | src/PVE/Cluster/Setup.pm | 815 | my $cmd = ['systemctl', 'stop', 'pve-cluster']; |
| pve-cluster | src/PVE/Cluster/Setup.pm | 821 | $cmd = ['systemctl', 'start', 'corosync', 'pve-cluster']; |
| pve-cluster | src/PVE/Cluster/Setup.pm | 840 | PVE::Tools::run_command(['systemctl', 'reload-or-restart', 'pvedaemon', 'pveproxy']); |
| pve-common | README.dev | 72 | libsystemd-dev libreadline-gplv2-dev libio-multiplex-perl \ |
| pve-common | src/PVE/Daemon.pm | 659 | PVE::Tools::run_command(['systemctl', 'start', $self->{name}]); |
| pve-common | src/PVE/Daemon.pm | 711 | ['systemctl', $use_hup ? 'reload-or-restart' : 'restart', $self->{name}]); |
| pve-common | src/PVE/Daemon.pm | 767 | PVE::Tools::run_command(['systemctl', 'stop', $self->{name}]); |
| pve-common | src/PVE/Systemd.pm | 1 | package PVE::Systemd; |
| pve-common | src/PVE/Systemd.pm | 51 | my $service = $bus->get_service('org.freedesktop.systemd1'); |
| pve-common | src/PVE/Systemd.pm | 52 | my $if = $service->get_object('/org/freedesktop/systemd1', 'org.freedesktop.systemd1.Manager'); |
| pve-common | src/PVE/Systemd.pm | 103 | sub enter_systemd_scope { |
| pve-common | src/PVE/Systemd.pm | 204 | my $service = $bus->get_service('org.freedesktop.systemd1'); |
| pve-common | src/PVE/Systemd.pm | 205 | my $if = $service->get_object('/org/freedesktop/systemd1', 'org.freedesktop.systemd1.Manager'); |
| pve-common | src/PVE/Systemd.pm | 209 | $if = $service->get_object($unit_path, 'org.freedesktop.systemd1.Unit') |
| pve-common | src/PVE/Tools.pm | 1466 | my $cmd = ['journalctl', '-o', 'short', '--no-pager']; |
| pve-container | debian/rules | 16 | dh_installsystemd -ppve-container --no-start --no-enable --no-restart-after-upgrade -r 'system-pve\x |
| pve-container | src/PVE/LXC.pm | 2968 | my $cmd = ['systemctl', 'start', "$base_unit\@$vmid"]; |
| pve-container | src/PVE/LXC/Setup/ArchLinux.pm | 41 | # 'systemctl enable systemd-networkd', since that's what we're configuring |
| pve-container | src/PVE/LXC/Setup/Base.pm | 602 | # libsystemd-shared<version>.so linked with /sbin/init |
| pve-container | src/PVE/LXC/Setup/Base.pm | 611 | if ($line =~ /libsystemd-shared-(\d+)(?:[-_.][a-zA-Z0-9]+)*\.so:?$/) { |
| pve-container | src/pve-container-stop-wrapper | 13 | exec {'systemctl'} 'systemctl', '--no-block', 'restart', "pve-container\@${vmid}.service"; |
| pve-container | src/pve-container-stop-wrapper | 15 | # stop if called via "systemctl stop lxc@ID" |
| pve-firewall | debian/postinst | 10 | systemctl --system daemon-reload >/dev/null \|\| true |
| pve-firewall | debian/rules | 10 | dh_installsystemd --name pvefw-logger pvefw-logger.service |
| pve-firewall | debian/rules | 11 | dh_installsystemd --name pve-firewall --no-stop-on-upgrade --no-restart-after-upgrade pve-firewall.s |
| pve-firewall | src/PVE/Firewall.pm | 5208 | run_command([qw(systemctl try-reload-or-restart pvefw-logger.service)]); |
| pve-ha-manager | debian/lintian-overrides | 2 | pve-ha-manager: maintainer-script-calls-systemctl * |
| pve-ha-manager | debian/pve-ha-manager.postinst | 8 | if systemctl --quiet is-active pve-ha-lrm.service; then |
| pve-ha-manager | debian/pve-ha-manager.postinst | 12 | if systemctl --quiet is-active pve-ha-crm.service; then |
| pve-ha-manager | debian/rules | 35 | dh_installsystemd -ppve-ha-manager --name watchdog-mux --no-restart-after-upgrade --no-stop-on-upgra |
| pve-ha-manager | debian/rules | 37 | dh_installsystemd -ppve-ha-manager --name pve-ha-lrm pve-ha-lrm.service |
| pve-ha-manager | debian/rules | 38 | dh_installsystemd -ppve-ha-manager --name pve-ha-crm pve-ha-crm.service |
| pve-ha-manager | src/PVE/HA/Env/PVE2.pm | 110 | my $cmd = ['/bin/systemctl', '--full', 'list-jobs']; |
| pve-ha-manager | src/watchdog-mux.c | 31 | #define JOURNALCTL_BIN "/bin/journalctl" |
| pve-manager | PVE/API2/ACME.pm | 220 | PVE::Tools::run_command(['systemctl', 'reload-or-restart', 'pveproxy']); |
| pve-manager | PVE/API2/ACME.pm | 303 | PVE::Tools::run_command(['systemctl', 'reload-or-restart', 'pveproxy']); |
| pve-manager | PVE/API2/ACME.pm | 378 | PVE::Tools::run_command(['systemctl', 'reload-or-restart', 'pveproxy']); |
| pve-manager | PVE/API2/Ceph/OSD.pm | 772 | '/bin/systemctl', 'show', "ceph-osd\@${osdid}.service", '--property', 'MainPID', |
| pve-manager | PVE/API2/Certificates.pm | 152 | PVE::Tools::run_command(['systemctl', 'reload-or-restart', 'pveproxy']); |
| pve-manager | PVE/API2/Certificates.pm | 201 | PVE::Tools::run_command(['systemctl', 'reload-or-restart', 'pveproxy']); |
| pve-manager | PVE/API2/Services.pm | 68 | PVE::Tools::run_command(['systemctl', 'show', $service], outfunc => $parser); |
| pve-manager | PVE/API2/Services.pm | 111 | PVE::Tools::run_command(['systemctl', $cmd, $service]); |
| pve-manager | PVE/CLI/pve8to9.pm | 140 | run_command(['systemctl', 'is-enabled', "$unit"], %extra); |
| pve-manager | PVE/CLI/pve8to9.pm | 142 | run_command(['systemctl', 'is-active', "$unit"], %extra); |
| pve-manager | PVE/CLI/pveceph.pm | 256 | 'systemctl', 'try-reload-or-restart', 'pvedaemon.service', 'pveproxy.service', |
| pve-manager | PVE/Ceph/Services.pm | 123 | run_command(['/bin/systemctl', $action, $service]); |
| pve-manager | bin/pveupdate | 122 | PVE::Tools::run_command(['systemctl', 'reload-or-restart', 'pveproxy']); |
| pve-manager | configs/pve.logrotate | 11 | /bin/systemctl try-reload-or-restart pveproxy.service |
| pve-manager | configs/pve.logrotate | 12 | /bin/systemctl try-reload-or-restart spiceproxy.service |
| pve-manager | debian/postinst | 101 | if systemctl -q is-enabled "$UNIT" 2> /dev/null; then |
| pve-manager | debian/postinst | 178 | systemctl --system daemon-reload >/dev/null \|\| true |
| pve-manager | debian/postinst | 226 | if systemctl -q is-enabled "$unit"; then |
| pve-storage | src/PVE/API2/Disks/Directory.pm | 12 | use PVE::Systemd; |
| pve-storage | src/PVE/API2/Disks/Directory.pm | 147 | $storid = PVE::Systemd::unescape_unit($storid); |
| pve-storage | src/PVE/API2/Disks/Directory.pm | 216 | my $mountunitname = PVE::Systemd::escape_unit($path, 1) . ".mount"; |
| pve-storage | src/PVE/API2/Disks/Directory.pm | 318 | run_command(['systemctl', 'daemon-reload']); |
| pve-storage | src/PVE/API2/Disks/Directory.pm | 319 | run_command(['systemctl', 'enable', $mountunitname]); |
| pve-storage | src/PVE/API2/Disks/Directory.pm | 320 | run_command(['systemctl', 'start', $mountunitname]); |
| pve-storage | src/PVE/API2/Disks/Directory.pm | 381 | my $mountunitname = PVE::Systemd::escape_unit($path, 1) . ".mount"; |
| pve-storage | src/PVE/API2/Disks/Directory.pm | 400 | run_command(['systemctl', 'stop', $mountunitname]); |
| pve-storage | src/PVE/API2/Disks/Directory.pm | 401 | run_command(['systemctl', 'disable', $mountunitname]); |
| pve-storage | src/PVE/API2/Disks/ZFS.pm | 8 | use PVE::Systemd; |
| pve-storage | src/PVE/API2/Disks/ZFS.pm | 513 | 'zfs-import@' . PVE::Systemd::escape_unit($name, undef) . '.service'; |
| pve-storage | src/PVE/API2/Disks/ZFS.pm | 514 | $cmd = ['systemctl', 'enable', $importunit]; |
| pve-storage | src/PVE/API2/Disks/ZFS.pm | 624 | 'zfs-import@' . PVE::Systemd::escape_unit($name) . '.service'; |
| pve-storage | src/PVE/API2/Disks/ZFS.pm | 625 | run_command(['systemctl', 'disable', $importunit]); |
| pve-storage | src/PVE/Storage/CephFSPlugin.pm | 14 | use PVE::Systemd; |
| pve-storage | src/PVE/Storage/CephFSPlugin.pm | 67 | my $unit_fn = PVE::Systemd::escape_unit($where, 1) . ".mount"; |
| pve-storage | src/PVE/Storage/CephFSPlugin.pm | 73 | run_command(['systemctl', 'daemon-reload'], errmsg => "daemon-reload error") |
| pve-storage | src/PVE/Storage/CephFSPlugin.pm | 75 | run_command(['systemctl', 'start', $unit_fn], errmsg => "mount error"); |
| pve-storage | src/PVE/Storage/ESXiPlugin.pm | 13 | use PVE::Systemd; |
| pve-storage | src/PVE/Storage/ESXiPlugin.pm | 172 | return "pve-esxi-fuse-" . PVE::Systemd::escape_unit($storeid); |
| pve-storage | src/PVE/Storage/ESXiPlugin.pm | 179 | return PVE::Systemd::is_unit_active($scope_name_base . '.scope'); |
| pve-storage | src/PVE/Storage/ESXiPlugin.pm | 225 | PVE::Systemd::enter_systemd_scope( |
| pve-storage | src/PVE/Storage/ESXiPlugin.pm | 278 | eval { run_command(['/bin/systemctl', 'reset-failed', $scope], %silence_std_outs) }; |
| pve-storage | src/PVE/Storage/ESXiPlugin.pm | 279 | eval { run_command(['/bin/systemctl', 'stop', $scope], %silence_std_outs) }; |
| qemu-server | src/PVE/QemuServer.pm | 48 | use PVE::Systemd; |
| qemu-server | src/PVE/QemuServer.pm | 5940 | eval { run_command(['/bin/systemctl', 'reset-failed', "$vmid.scope"], %silence_std_outs) }; |
| qemu-server | src/PVE/QemuServer.pm | 5941 | eval { run_command(['/bin/systemctl', 'stop', "$vmid.scope"], %silence_std_outs) }; |
| qemu-server | src/PVE/QemuServer.pm | 5944 | PVE::Systemd::wait_for_unit_removed("$vmid.scope", 20); |
| qemu-server | src/PVE/QemuServer.pm | 5981 | PVE::Systemd::enter_systemd_scope($vmid, "Proxmox VE VM $vmid", |
| qemu-server | src/PVE/QemuServer/CGroup.pm | 8 | use PVE::Systemd; |
| qemu-server | src/PVE/QemuServer/CGroup.pm | 25 | PVE::Systemd::systemd_call(sub { |
| qemu-server | src/PVE/QemuServer/CPUConfig.pm | 925 | . "systemctl status query-machine-capabilities\n"; |
| qemu-server | src/PVE/QemuServer/DBusVMState.pm | 7 | use PVE::Systemd; |
| qemu-server | src/PVE/QemuServer/DBusVMState.pm | 53 | eval { PVE::Tools::run_command(['systemctl', 'start', "pve-dbus-vmstate\@$vmid"]) }; |
| qemu-server | src/test/MigrationTest/QmMock.pm | 135 | if ($cmd eq '/bin/systemctl') { |
| qemu-server | src/test/MigrationTest/Shared.pm | 221 | our $systemd_module = Test::MockModule->new("PVE::Systemd"); |
| qemu-server | src/test/MigrationTest/Shared.pm | 226 | enter_systemd_scope => sub { |

## Package dependencies

| Component | Field line |
| --- | --- |
| proxmox-ve | systemd-sysv, |
| pve-cluster | systemd, |
| pve-ha-manager | systemd, |
| pve-manager | systemd, |
