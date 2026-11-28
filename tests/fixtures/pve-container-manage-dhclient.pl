# SuperMox test fixture for tests/test-dhcp-client-port.sh.
#
# Verbatim excerpt of src/PVE/LXC.pm lines 1292-1400 of pve-container at
# ae86a25d9f58daa0f2fa316d134d88f66f804d0d (6.1.28), the pin recorded in
# config/upstream-overrides.txt. It is the region patches/pve-container/0003-
# maintained-dhcp-client.patch changes, so the patch can be applied offline.
# The test compares everything after the marker line below byte-for-byte
# against the pinned file whenever upstream/ is present: if the pin moves and
# this excerpt goes stale, the test says so instead of passing silently.
# --- excerpt of src/PVE/LXC.pm lines 1292-1400 begins ---
sub manage_dhclient {
    my ($action, $vmid, $ipversion, $eth, $rootdir) = @_;

    File::Path::make_path("/var/lib/lxc/$vmid/hook") if $action eq 'start';
    my $pidfile = "/var/lib/lxc/$vmid/hook/dhclient$ipversion-$eth.pid";
    my $leasefile = "/var/lib/lxc/$vmid/hook/dhclient$ipversion-$eth.leases";
    my $scriptfile = '/usr/share/lxc/hooks/dhclient-script';
    PVE::Tools::run_command([
        'lxc-attach',
        '-n',
        $vmid,
        '-s',
        'NETWORK|UTSNAME',
        '--',
        'aa-exec',
        '-p',
        'unconfined', # FIXME: use a profile that confines writes to /var/lib/lxc/$vmid and rootfs
        '/sbin/dhclient',
        $action eq 'start' ? '-1' : '-r',
        "-$ipversion",
        '-pf',
        $pidfile,
        '-lf',
        $leasefile,
        '-e',
        "ROOTFS=$rootdir",
        '-sf',
        $scriptfile,
        $eth,
    ]);
}

sub kill_dhclients {
    my ($vmid, $eth) = @_;

    # NOTE: kills all known managed DHCP clients of a CT if no if is passed
    $eth = '*' if !defined($eth);

    for my $pidfile (glob("/var/lib/lxc/$vmid/hook/dhclient*-$eth.pid")) {
        my $pid = eval { file_get_contents($pidfile) };
        if (!$@) {
            chomp $pid;
            next if $pid !~ /^(\d+)$/;
            kill 9, $1;
            # TODO: what about waitpit? or is this collected by systemd directly?
            unlink($pidfile) or $!{ENOENT} or warn "failed to unlink PID file '$pidfile' - $!\n";
        }
    }
}

sub update_ipconfig {
    my ($vmid, $conf, $opt, $eth, $newnet, $rootdir) = @_;

    my $lxc_setup = PVE::LXC::Setup->new($conf, $rootdir);

    my $optdata = PVE::LXC::Config->parse_lxc_network($conf->{$opt});
    my $deleted = [];
    my $added = [];
    my $nscmd = sub {
        my $cmdargs = shift;
        PVE::Tools::run_command(
            ['lxc-attach', '-n', $vmid, '-s', 'NETWORK', '--', @_], %$cmdargs,
        );
    };
    my $ipcmd = sub { &$nscmd({}, '/sbin/ip', @_) };

    my $change_ip_config = sub {
        my ($ipversion) = @_;

        my $family_opt = "-$ipversion";
        my $suffix = $ipversion == 4 ? '' : $ipversion;
        my $gw = "gw$suffix";
        my $ip = "ip$suffix";

        my $newip = $newnet->{$ip};
        my $newgw = $newnet->{$gw};
        my $oldip = $optdata->{$ip};
        my $oldgw = $optdata->{$gw};

        my $change_ip = safe_string_ne($oldip, $newip);
        my $change_gw = safe_string_ne($oldgw, $newgw);

        return if !$change_ip && !$change_gw;

        # step 1: add new IP, if this fails we cancel
        my $is_real_ip = ($newip && $newip !~ /^(?:auto|dhcp|manual)$/);
        if ($change_ip) {
            if ($newnet->{'host-managed'} && $newip && $newip eq 'dhcp') {
                manage_dhclient('start', $vmid, $ipversion, $eth, $rootdir);
            }
            if ($optdata->{'host-managed'} && $oldip && $oldip eq 'dhcp') {
                manage_dhclient('stop', $vmid, $ipversion, $eth, $rootdir);
            }

            if ($is_real_ip) {
                eval { &$ipcmd($family_opt, 'addr', 'add', $newip, 'dev', $eth); };
                if (my $err = $@) {
                    warn $err;
                    return;
                }
            }
        } elsif ($optdata->{'host-managed'} && !$newnet->{'host-managed'}) {
            manage_dhclient('stop', $vmid, $ipversion, $eth, $rootdir);
        }

        # step 2: replace gateway
        #   If this fails we delete the added IP and cancel.
        #   If it succeeds we save the config and delete the old IP, ignoring
        #   errors. The config is then saved.
