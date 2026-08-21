#!/usr/bin/env perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: compile
# expectexit: 0
# expectstdout: peephole source toggle tests passed

use strict;
use warnings;
use File::Spec;
use File::Temp qw(tempdir);

my ($repo, $tmp_root) = @ARGV;
die "usage: $0 repo tmp_root\n" if !defined $repo || !defined $tmp_root;

my $cc1 = File::Spec->catfile($repo, 'compiler', 'vcsc-cc1');
my $driver = File::Spec->catfile($repo, 'driver', 'vcsc');
my $test = File::Spec->catdir($repo, 'test');
my $src = File::Spec->catfile($test, 'fixtures', 'peephole', 'generated_patterns.c26');
my $tmp = tempdir('VCSC_peephole_source_XXXXXX', DIR => $tmp_root, CLEANUP => 1);
my $off = File::Spec->catfile($tmp, 'off.s26');
my $on = File::Spec->catfile($tmp, 'on.s26');
my $driver_off = File::Spec->catfile($tmp, 'driver_off.s26');
my $re_enabled = File::Spec->catfile($tmp, 're_enabled.s26');
my $re_disabled = File::Spec->catfile($tmp, 're_disabled.s26');
my $debug = File::Spec->catfile($tmp, 'debug.txt');

sub run_ok {
   my (@cmd) = @_;
   system(@cmd) == 0 or die "command failed: @cmd\n";
}

sub slurp {
   my ($path) = @_;
   open my $fh, '<', $path or die "read $path: $!";
   local $/;
   return <$fh>;
}

run_ok($cc1, '-quiet', '-I', $test, '-fno-peephole', $src, '-o', $off);
run_ok($cc1, '-quiet', '-I', $test, '-fpeephole', $src, '-o', $on);
run_ok($driver, '-S', '-I', $test, '-fno-peephole', $src, '-o', $driver_off);
run_ok($cc1, '-quiet', '-I', $test, '-fno-peephole', '-fpeephole', $src, '-o', $re_enabled);
run_ok($cc1, '-quiet', '-I', $test, '-fpeephole', '-fno-peephole', $src, '-o', $re_disabled);

my $off_text = slurp($off);
my $on_text = slurp($on);
my $driver_text = slurp($driver_off);
$driver_text eq $off_text or die "driver -fno-peephole did not match direct cc1 output\n";
slurp($re_enabled) eq $on_text or die "last -fpeephole option did not re-enable optimization\n";
slurp($re_disabled) eq $off_text or die "last -fno-peephole option did not disable optimization\n";

my @patterns = (
   [ 'dup_lda', qr/lda #\$00\n    sta  __vcsc_scratch_0\n    lda #\$00\n    sta  __vcsc_scratch_0 \+ 1/ ],
   [ 'jump_next', qr/jmp \@fini\n\@fini:/ ],
   [ 'branch_next', qr/beq (\@if_false_\d+)\n\1:/ ],
   [ 'branch_jmp_invert', qr/bcc (\@u8_lt_true_\d+)\n    jmp (\@if_false_\d+)\n\1:/ ],
);

for my $item (@patterns) {
   my ($name, $re) = @$item;
   $off_text =~ $re or die "unoptimized compiler output does not contain $name pattern\n--- output ---\n$off_text";
   $on_text !~ $re or die "optimized compiler output still contains $name pattern\n--- output ---\n$on_text";
}

my $cmd = join(' ', map { quotemeta($_) } ($cc1, '-quiet', '-I', $test, '-X', 'debug', $src, '-o', File::Spec->catfile($tmp, 'debug.s26')));
my $status = system("$cmd 2> " . quotemeta($debug));
$status == 0 or die "debug compile failed\n";
my $debug_text = slurp($debug);
for my $kind (qw(dup_lda jump_next branch_next branch_jmp_invert)) {
   $debug_text =~ /peephole:\Q$kind\E\b/ or die "optimized source fixture did not exercise $kind\n--- debug ---\n$debug_text";
}

my $no_debug = File::Spec->catfile($tmp, 'no_debug.txt');
$cmd = join(' ', map { quotemeta($_) } ($cc1, '-quiet', '-I', $test, '-fno-peephole', '-X', 'debug', $src, '-o', File::Spec->catfile($tmp, 'no_debug.s26')));
$status = system("$cmd 2> " . quotemeta($no_debug));
$status == 0 or die "no-peephole debug compile failed\n";
my $no_debug_text = slurp($no_debug);
$no_debug_text !~ /peephole:/ or die "peephole rewrites ran under -fno-peephole\n--- debug ---\n$no_debug_text";

print "peephole source toggle tests passed\n";
