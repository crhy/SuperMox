# Returns: { kvm => [ flagX, flagY, ... ], tcg => [ flag1, flag2, ... ] }
# since kvm and tcg machines support different flags
#
sub query_supported_cpu_flags {
    my ($arch) = @_;

    my $host_arch = get_host_arch();
    $arch //= $host_arch;
    my $default_machine = PVE::QemuServer::Machine::default_machine_for_arch($arch);

    my $flags = {};

    my $kvm_supported = defined(kvm_version()) && $arch eq $host_arch;
    my $qemu_cmd = PVE::QemuServer::Helpers::get_command_for_arch($arch);
    my $qemu_binary_version = kvm_user_version($qemu_cmd);
    my $fakevmid = -1;
    my $pidfile = PVE::QemuServer::Helpers::vm_pidfile_name($fakevmid);

    # Start a temporary (frozen) VM with vmid -1 to allow sending a QMP command
    my $query_supported_run_qemu = sub {
        my ($kvm) = @_;

        my $flags = {};
        my $cmd = [
            $qemu_cmd,
            '-machine',
            $default_machine,
            '-display',
            'none',
            '-chardev',
            "socket,id=qmp,path=/var/run/qemu-server/$fakevmid.qmp,server=on,wait=off",
            PVE::QemuServer::Monitor::object_commandline($qemu_binary_version, 'qmp')->@*,
            '-pidfile',
            $pidfile,
            '-S',
            '-daemonize',
        ];

        if (!$kvm) {
            push @$cmd, '-accel', 'tcg';
        } else {
            push @$cmd, '-cpu', 'host';
        }

        my $rc = run_command($cmd, noerr => 1, quiet => 0);
        die "QEMU flag querying VM exited with code " . $rc if $rc;

        my $model = { name => $kvm ? 'host' : 'max' };
        $model->{props} = { 'hv-passthrough' => JSON::true } if $kvm && $arch eq 'x86_64';

        eval {
            my $cmd_result = mon_cmd(
                $fakevmid,
                'query-cpu-model-expansion',
                type => 'full',
                model => $model,
            );

            my $props = $cmd_result->{model}->{props};
            foreach my $prop (keys %$props) {
                next if $props->{$prop} ne JSON::true;
                $prop = PVE::QemuServer::CPUFlags::normalize_cpu_flag($prop);

                $flags->{$prop} = 1;
            }
        };
        my $err = $@;

        # force stop with 10 sec timeout and 'nocheck', always stop, even if QMP failed
        vm_stop(undef, $fakevmid, 1, 1, 10, 0, 1);

        die $err if $err;

        return [sort keys %$flags];
