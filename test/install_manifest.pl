#!/usr/bin/env perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 60
# expectstdout: Install manifest test passed
# expectexit: 0

use strict;
use warnings;
use File::Path qw(remove_tree);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub run_ok {
    my (@cmd) = @_;
    my $err = gensym;
    my $pid = open3(my $in, my $out, $err, @cmd);
    close $in;
    local $/;
    my $stdout = <$out> // '';
    my $stderr = <$err> // '';
    waitpid($pid, 0);
    my $rc = $? >> 8;
    my $sig = $? & 127;
    die "command failed rc=$rc sig=$sig\n@cmd\nstdout:\n$stdout\nstderr:\n$stderr" if $rc || $sig;
}

my ($repo, $tmp) = @ARGV;
die "usage: $0 REPO TMP\n" unless defined $repo && defined $tmp;
my $helper = File::Spec->catfile($repo, qw(packaging install_manifest.pl));
my $manifest = File::Spec->catfile($repo, qw(packaging install.manifest));

sub helper {
    my ($action, $root, @scopes) = @_;
    my @scope_args = map { ('--scope', $_) } @scopes;
    run_ok($^X, $helper, $action, '--manifest', $manifest,
        @scope_args, '--source-root', $repo, '--dest-root', $root);
}

my $libs = File::Spec->catdir($tmp, 'root');
helper('install', $libs, 'libraries');
helper('verify', $libs, 'libraries');
-f File::Spec->catfile($libs, qw(libraries vcs F8 mapper.c26)) or die "F8 mapper missing from libraries manifest install\n";
-f File::Spec->catfile($libs, qw(libraries runtime libvcsc.l26)) or die "runtime archive missing from libraries manifest install\n";
-f File::Spec->catfile($libs, qw(libraries runtime vcsc-runtime.inc)) or die "runtime include missing from libraries manifest install\n";
helper('uninstall', $libs, 'libraries');
-d File::Spec->catdir($libs, 'libraries') and die "empty libraries tree survived uninstall\n";

my $examples = File::Spec->catdir($tmp, 'examples');
run_ok($^X, $helper, 'install', '--manifest', $manifest, '--scope', 'examples',
    '--source-root', $repo, '--dest-root', $examples, '--vcsc-name', 'vcsc.exe');
run_ok($^X, $helper, 'verify', '--manifest', $manifest, '--scope', 'examples',
    '--source-root', $repo, '--dest-root', $examples, '--vcsc-name', 'vcsc.exe');
my $mk = File::Spec->catfile($examples, qw(01_basic 01_blank_screen Makefile));
open my $fh, '<', $mk or die "$mk: $!\n";
local $/;
my $text = <$fh>;
close $fh;
index($text, '$(ROOT)/bin/vcsc.exe') >= 0 or die "Windows example driver rewrite missing\n";
index($text, '$(ROOT)/libraries/vcs') >= 0 or die "installed example lost shared source/install VCS library path\n";
index($text, '$(ROOT)/driver/vcsc') < 0 or die "source-tree driver path survived example install\n";

for my $rel (
    [qw(01_basic 13_tanks Makefile)],
    [qw(01_basic 11_keypad Makefile)],
    [qw(01_basic 12_drive Makefile)],
) {
    my $direct = File::Spec->catfile($examples, @$rel);
    open my $dfh, '<', $direct or die "$direct: $!\n";
    local $/;
    my $body = <$dfh> // '';
    close $dfh;
    index($body, '../../../bin/vcsc.exe') >= 0
        or die "direct-relative Windows example driver rewrite missing in $direct\n";
    $body !~ m{(?:^|/)driver/vcsc(?:\.exe)?(?:\s|$)}m
        or die "source-tree driver path survived direct-relative example install in $direct\n";
}
helper('uninstall', $examples, 'examples');
-d $examples and die "example tree survived uninstall\n";

for my $platform (qw(linux windows)) {
    my $pkg = File::Spec->catdir($tmp, "package-$platform");
    helper('install', $pkg, 'package-common', "package-$platform");
    helper('verify', $pkg, 'package-common', "package-$platform");
    -f File::Spec->catfile($pkg, 'README.md') or die "$platform package README missing\n";
    -f File::Spec->catfile($pkg, 'addons', 'c26.vim') or die "$platform package addons missing\n";
    my $doc = $platform eq 'linux' ? 'LINUX.md' : 'WINDOWS.md';
    my $other = $platform eq 'linux' ? 'WINDOWS.md' : 'LINUX.md';
    -f File::Spec->catfile($pkg, $doc) or die "$platform package document missing\n";
    -e File::Spec->catfile($pkg, $other) and die "$platform package contains wrong platform document\n";
    if ($platform eq 'windows') {
        my $cmd = File::Spec->catfile($pkg, 'vcsc.cmd');
        -f $cmd or die "Windows package launcher missing\n";
        open my $cfh, '<:raw', $cmd or die "$cmd: $!\n";
        local $/;
        my $body = <$cfh> // '';
        close $cfh;
        $body =~ /\r\n/ or die "Windows package launcher lost CRLF line endings\n";
        index($body, '%~dp0bin\\vcsc.exe') >= 0 or die "Windows package launcher path is wrong\n";
    }
}

print "Install manifest test passed\n";
