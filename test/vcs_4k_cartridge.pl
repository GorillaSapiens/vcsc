#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_4k_cartridge ok
# expectexit: 0


use strict;
use warnings;
use Cwd qw(abs_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub without_cartridge_usage {
   my ($out) = @_;
   $out =~ s/\AMEMORY USAGE\n(?:  [^\n]+\n)+//;
   return $out;
}

sub usage {
   die "usage: $0 REPO_ROOT TMP_DIR\n";
}

sub slurp_fh {
   my ($fh) = @_;
   local $/;
   my $data = <$fh>;
   return defined($data) ? $data : '';
}

sub run_capture {
   my (@cmd) = @_;
   my $err = gensym;
   my $pid = open3(my $in, my $out, $err, @cmd);
   close($in);
   my $stdout = slurp_fh($out);
   my $stderr = slurp_fh($err);
   waitpid($pid, 0);
   return ($? >> 8, $? & 127, $stdout, $stderr);
}

sub read_file {
   my ($path) = @_;
   open(my $fh, '<:raw', $path) or die "could not open $path: $!\n";
   local $/;
   my $data = <$fh>;
   close($fh) or die "could not close $path: $!\n";
   return defined($data) ? $data : '';
}

my $repo = shift @ARGV // usage();
my $tmp = shift @ARGV // usage();
usage() if @ARGV;
$repo = abs_path($repo) // die "could not resolve repo root: $repo\n";
$tmp = abs_path($tmp) // die "could not resolve temporary directory: $tmp\n";

my $driver = File::Spec->catfile($repo, 'driver', 'vcsc');
my $vcs_dir = File::Spec->catfile($repo, 'libraries', 'vcs');
my $source = File::Spec->catfile($repo, 'test', 'fixtures', 'vcs_examples', '01_solid_color', 'golden.c26');
my $binary = File::Spec->catfile($tmp, 'solid_color.bin');
my $map = File::Spec->catfile($tmp, 'solid_color.map');

-x $driver or die "compiler driver is not executable: $driver\n";
-f $source or die "example source is missing: $source\n";

my ($exit, $signal, $stdout, $stderr) = run_capture(
   $driver,
   '-I', $vcs_dir,
   '-Map', $map,
   $source,
   '-o', $binary,
);
die "cartridge build exited $exit signal $signal\nstdout:\n$stdout\nstderr:\n$stderr"
   if $exit != 0 || $signal != 0;
die "cartridge build wrote unexpected stdout:\n$stdout" if without_cartridge_usage($stdout) ne '';
die "cartridge build wrote unexpected stderr:\n$stderr" if $stderr ne '';

my $rom = read_file($binary);
length($rom) == 4096
   or die "raw cartridge size is " . length($rom) . ", expected 4096\n";

my @reset_prefix = unpack('C5', substr($rom, 0, 5));
my @expected_prefix = (0x78, 0xd8, 0xa2, 0xff, 0x9a);
for my $i (0 .. $#expected_prefix) {
   $reset_prefix[$i] == $expected_prefix[$i]
      or die sprintf("reset prefix byte %d is %02x, expected %02x\n",
                     $i, $reset_prefix[$i], $expected_prefix[$i]);
}

my ($nmi, $reset, $irq) = unpack('v3', substr($rom, 0x0ffa, 6));
for my $entry ([NMI => $nmi], [RESET => $reset], [IRQ => $irq]) {
   my ($name, $address) = @$entry;
   $address >= 0xf000 && $address <= 0xffff
      or die sprintf("%s vector %04x is outside cartridge ROM\n", $name, $address);
}
$reset == 0xf000
   or die sprintf("RESET vector is %04x, expected f000\n", $reset);

my $map_text = read_file($map);
$map_text =~ /RAM\s+start=\$0080\s+size=\$007C\s+type=rw/
   or die "map does not expose the call-graph-sized RIOT RAM arena\n";
$map_text =~ /region=RAM\s+depth=2\s+bytes=\$0004\s+physical=\$00FC-\$00FF/
   or die "map does not report the expected two-level hardware-stack reserve\n";
$map_text =~ /__stack_top\s+\$00FB/
   or die "map does not stop ordinary allocation below the hardware stack\n";
$map_text =~ /\bmain\b/
   or die "map is missing main\n";
$map_text =~ /\bchoose_background\b/
   or die "map is missing choose_background\n";

print "vcs_4k_cartridge ok\n";
