#!/usr/bin/perl
use strict;
use warnings;

use PVE::SysvService;

my $fail = 0;

sub ok {
    my ($cond, $msg) = @_;
    if ($cond) {
        print "ok: $msg\n";
    } else {
        print "FAIL: $msg\n";
        $fail++;
    }
}

sub log_lines {
    my @l;
    open my $fh, '<', $ENV{PVE_SYSV_TEST_LOG} or die "no log: $!";
    while (my $line = <$fh>) { chomp $line; push @l, $line; }
    close $fh;
    return @l;
}

sub log_has {
    my ($needle) = @_;
    for my $l (log_lines()) {
        return 1 if $l eq $needle;
    }
    return 0;
}

sub log_count {
    my ($needle) = @_;
    my $c = 0;
    for my $l (log_lines()) {
        $c++ if $l eq $needle;
    }
    return $c;
}

# --- exists ---
ok(PVE::SysvService::exists('pve-demo') == 1, "exists pve-demo");
ok(PVE::SysvService::exists('pve-demo.service') == 1, "exists strips .service");
ok(PVE::SysvService::exists('nope') == 0, "exists missing");

# --- start/stop/restart/reload ---
PVE::SysvService::start('pve-demo');
ok(log_has('pve-demo start'), "start logs");
PVE::SysvService::stop('pve-demo');
ok(log_has('pve-demo stop'), "stop logs");
PVE::SysvService::restart('pve-demo');
ok(log_has('pve-demo restart'), "restart logs");
PVE::SysvService::reload('pve-demo');
ok(log_has('pve-demo reload'), "reload logs");

# .service suffix routes to the same script
PVE::SysvService::start('pve-demo.service');
ok(log_count('pve-demo start') == 2, "start via .service suffix");

# --- is_running ---
ok(PVE::SysvService::is_running('pve-demo') == 1, "is_running running svc");
ok(PVE::SysvService::is_running('pve-stopped') == 0, "is_running stopped svc (status exit 3)");

# --- reload_or_restart ---
PVE::SysvService::reload_or_restart('pve-demo');   # has reload) arm -> reload
ok(log_has('pve-demo reload'), "reload_or_restart uses reload when supported");
PVE::SysvService::reload_or_restart('pve-noreload'); # no reload arm -> restart
ok(log_has('pve-noreload restart'), "reload_or_restart falls back to restart");

# --- try_reload_or_restart ---
my $before = log_count('pve-demo reload');
PVE::SysvService::try_reload_or_restart('pve-demo'); # running -> reload
ok(log_count('pve-demo reload') == $before + 1, "try_reload_or_restart acts when running");
my $stopped_reload = log_count('pve-stopped reload');
PVE::SysvService::try_reload_or_restart('pve-stopped'); # not running -> no-op
ok(log_count('pve-stopped reload') == $stopped_reload, "try_reload_or_restart no-op when stopped");

# --- enable / disable ---
PVE::SysvService::enable('pve-demo');
ok(log_has('update-rc.d pve-demo defaults'), "enable runs update-rc.d defaults");
PVE::SysvService::disable('pve-demo');
ok(log_has('update-rc.d pve-demo disable'), "disable runs update-rc.d disable");

# --- is_enabled ---
ok(PVE::SysvService::is_enabled('pve-demo') == 1, "is_enabled with S99 link");
ok(PVE::SysvService::is_enabled('pve-stopped') == 0, "is_enabled without link");

# --- show ---
my $s = PVE::SysvService::show('pve-demo');
ok($s->{ActiveState} eq 'active', "show ActiveState active");
ok($s->{SubState} eq 'running', "show SubState running");
ok($s->{UnitFileState} eq 'enabled', "show UnitFileState enabled");
ok($s->{Description} eq 'Demo PVE service', "show Description from Short-Description header");

my $t = PVE::SysvService::show('pve-stopped');
ok($t->{ActiveState} eq 'inactive', "show stopped ActiveState");
ok($t->{SubState} eq 'dead', "show stopped SubState");
ok($t->{UnitFileState} eq 'disabled', "show stopped UnitFileState");

my $m = PVE::SysvService::show('nope');
ok($m->{UnitFileState} eq 'not-found', "show missing UnitFileState not-found");
ok($m->{ActiveState} eq 'inactive', "show missing ActiveState");
ok($m->{Description} eq '', "show missing Description empty");

# --- missing service dies (except exists/show/is_enabled) ---
my $did_die = 0;
eval { PVE::SysvService::start('nope'); };
$did_die = 1 if $@;
ok($did_die, "start on missing service dies");

$did_die = 0;
eval { PVE::SysvService::is_running('nope'); };
$did_die = 1 if $@;
ok($did_die, "is_running on missing service dies");

if ($fail) {
    print "FAILED: $fail assertion(s)\n";
    exit 1;
}
print "ALL OK\n";
exit 0;
