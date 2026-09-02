#!/usr/bin/env perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: physical bank image planes preserve overlapping bytes
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
   return ($out, $err);
}
sub require_fail {
   my ($label, $fragment, @cmd) = @_;
   my ($exit, $sig, $out, $err) = run_capture(@cmd);
   ($exit != 0 || $sig) or die "$label unexpectedly succeeded\n@cmd\n";
   index($err, $fragment) >= 0
      or die "$label stderr missing '$fragment'\nstdout:\n$out\nstderr:\n$err";
}

my $repo = abs_path(shift @ARGV // die "usage: $0 REPO TMP\n");
my $tmp = shift @ARGV // die "usage: $0 REPO TMP\n";
@ARGV and die "usage: $0 REPO TMP\n";
make_path($tmp);
$tmp = abs_path($tmp) // die "could not resolve temp dir\n";

my $vcsc = File::Spec->catfile($repo, 'driver', 'vcsc');
my $vcs = File::Spec->catdir($repo, 'libraries', 'vcs');
my $src = File::Spec->catfile($tmp, 'planes.c26');
my $bin = File::Spec->catfile($tmp, 'planes.bin');
my $hex = File::Spec->catfile($tmp, 'planes.hex');

my $program = <<'SRC';
include "vcs.c26"
cartridge { $fill:0xff $signature:3F };
bank bank0 { $image_size:0x0800 $file_index:0 $image_offset:0 $link_start:0x1000 $cpu_start:0x1000 $map_size:0x0800 };
bank bank1 { $image_size:0x0800 $file_index:1 $image_offset:0 $link_start:0x1000 $cpu_start:0x1000 $map_size:0x0800 };
bank bank2 { $image_size:0x0800 $file_index:2 $image_offset:0 $link_start:0xf800 $cpu_start:0x1800 $map_size:0x0800 $startup };
mem bank0 { $start:0x1000 $size:0x0800 $ro $bank:bank0 };
mem bank1 { $start:0x1000 $size:0x0800 $ro $bank:bank1 };
mem bank2 { $start:0xf800 $size:0x07f8 $ro $bank:bank2 $priority:2 };
bank0 const uint8_t marker0[4] := { 0x10, 0x11, 0x12, 0x13 };
bank1 const uint8_t marker1[4] := { 0x20, 0x21, 0x22, 0x23 };
bank2 void main(void) { while (1) { } }
SRC
write_file($src, $program);

require_ok('overlapping physical-bank link', $vcsc, '-I', $vcs,
           '--no-map', '--no-sym', '--no-list', '--no-cfg', '-o', $bin, $src);
my $image = slurp($bin);
length($image) == 0x1800
   or die "overlapping-bank output length was " . length($image) . ", expected 6144\n";
substr($image, 0x0000, 4) eq "\x10\x11\x12\x13"
   or die "physical bank 0 lost its bank-local bytes\n";
substr($image, 0x0800, 4) eq "\x20\x21\x22\x23"
   or die "physical bank 1 aliased bank 0 at the shared logical address\n";

require_fail('overlapping physical banks as Intel HEX',
             'Intel HEX cannot represent bank-local bytes',
             $vcsc, '-I', $vcs, '--no-map', '--no-sym', '--no-list', '--no-cfg',
             '-o', $hex, $src);

(my $ambiguous = $program) =~ s/ \$bank:bank1//;
my $ambiguous_src = File::Spec->catfile($tmp, 'ambiguous.c26');
write_file($ambiguous_src, $ambiguous);
require_fail('overlapping mem without explicit owner',
             'contained by multiple output banks',
             $vcsc, '-I', $vcs, '--no-map', '--no-sym', '--no-list', '--no-cfg',
             '-o', File::Spec->catfile($tmp, 'ambiguous.bin'), $ambiguous_src);

print "physical bank image planes preserve overlapping bytes\n";
