#!/usr/bin/env perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: 256-bank automatic placement set works
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub write_file {
   my ($path, $text) = @_;
   open(my $fh, '>:raw', $path) or die "could not write $path: $!\n";
   print {$fh} $text;
   close($fh);
}

sub slurp {
   my ($path) = @_;
   open(my $fh, '<:raw', $path) or die "could not read $path: $!\n";
   local $/;
   my $text = <$fh>;
   close($fh);
   return defined($text) ? $text : '';
}

sub run_capture {
   my (@cmd) = @_;
   my $err = gensym;
   my $pid = open3(my $in, my $out, $err, @cmd);
   close($in);
   local $/;
   my $stdout = <$out> // '';
   my $stderr = <$err> // '';
   waitpid($pid, 0);
   return ($? >> 8, $? & 127, $stdout, $stderr);
}

sub require_ok {
   my ($label, @cmd) = @_;
   my ($exit, $sig, $out, $err) = run_capture(@cmd);
   $exit == 0 && !$sig
      or die "$label failed: exit=$exit signal=$sig\n@cmd\nstdout:\n$out\nstderr:\n$err";
}

my $repo = abs_path(shift @ARGV // die "usage: $0 REPO TMP\n");
my $tmp = shift @ARGV // die "usage: $0 REPO TMP\n";
@ARGV and die "usage: $0 REPO TMP\n";
make_path($tmp);
$tmp = abs_path($tmp) // die "could not resolve temp dir\n";

my $vcsc = File::Spec->catfile($repo, 'driver', 'vcsc');
my $vcs = File::Spec->catdir($repo, 'libraries', 'vcs');
my $mapper = File::Spec->catfile($tmp, 'mapper256.c26');
my $source = File::Spec->catfile($tmp, 'placement256.c26');
my $bin = File::Spec->catfile($tmp, 'placement256.bin');
my $map = File::Spec->catfile($tmp, 'placement256.map');

my $mapper_text = <<'HEAD';
alias VCS_TIA_USE_40_MIRROR 1
include "vcs.c26"
cartridge { $fill:0xff $signature:3F };
HEAD
for my $i (0 .. 254) {
   $mapper_text .= sprintf(
      "bank bank%d { \$image_size:0x0800 \$file_index:%d \$image_offset:0 \$link_start:0x1000 \$cpu_start:0x1000 \$map_size:0x0800 };\n",
      $i, $i);
}
$mapper_text .=
   "bank bank255 { \$image_size:0x0800 \$file_index:255 \$image_offset:0 \$link_start:0x1800 \$cpu_start:0x1800 \$map_size:0x0800 \$startup };\n";
for my $i (0 .. 254) {
   $mapper_text .= sprintf(
      "mem bank%d { \$start:0x1000 \$size:0x0001 \$ro \$bank:bank%d };\n",
      $i, $i);
}
$mapper_text .=
   "mem bank255 { \$start:0x1800 \$size:0x07f8 \$ro \$priority:2 \$bank:bank255 };\n";
write_file($mapper, $mapper_text);

write_file($source, qq{include "$mapper"\nuint8_t helper(void) { return 0x5a; }\nbank255 void main(void) { _ := helper(); while (1) { } }\n});

local $ENV{TERM} = $ENV{TERM} || 'xterm';
require_ok('link 256-bank automatic placement fixture',
   $vcsc, '-I', $vcs, '-Map', $map, $source, '-o', $bin);

length(slurp($bin)) == 256 * 0x0800
   or die "256-bank fixture did not emit a 512K image\n";
my $map_text = slurp($map);
$map_text =~ /automatic CODE\.__vcsc_function\$helper\s+region=bank255\b/
   or die "automatic helper did not reach placement-bank index 255\n$map_text";
$map_text =~ /pinned\s+CODE\.bank255\.__vcsc_function\$main\s+region=bank255\b/
   or die "pinned main did not remain in placement-bank index 255\n$map_text";

print "256-bank automatic placement set works\n";
