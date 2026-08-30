#!/usr/bin/env perl
# runner: perl @FILE@ @VCSC_CC1@ @TEST_ROOT@
# phase: compile
# expectexit: 0
# expectstdout: initializer line wrapping passed

use strict;
use warnings;
use File::Spec;
use File::Temp qw(tempdir);

my ($cc1, $test_root) = @ARGV;
die "usage: $0 vcsc-cc1 test_root\n" if !defined $cc1 || !defined $test_root;

my $tmp = tempdir('VCSC_initializer_line_wrap_XXXX', TMPDIR => 1, CLEANUP => 1);
my $src = File::Spec->catfile($tmp, 'large.c26');
my $asm = File::Spec->catfile($tmp, 'large.s26');

open my $fh, '>', $src or die "write $src: $!\n";
print {$fh} qq{include "machine_6502.c26"\n};
print {$fh} "const uint8_t payload[2048] := {\n";
for my $i (0 .. 2047) {
   print {$fh} '   ' if ($i % 16) == 0;
   printf {$fh} '0x%02X', (($i * 73) ^ ($i >> 3) ^ 0x5a) & 0xff;
   print {$fh} $i == 2047 ? "\n" : ', ';
   print {$fh} "\n" if ($i % 16) == 15 && $i != 2047;
}
print {$fh} "};\nvoid main(void) {}\n";
close $fh or die "close $src: $!\n";

system($cc1, '-quiet', '-I', $test_root, $src, '-o', $asm) == 0
   or die "compile large initializer failed\n";

open my $afh, '<', $asm or die "read $asm: $!\n";
my @lines = <$afh>;
close $afh;
my @bytes = grep { /^\s*\.byte\s/ } @lines;
@bytes == 16 or die "2048-byte initializer emitted " . scalar(@bytes) . ".byte lines, expected 16\n";
for my $line (@bytes) {
   my @values = ($line =~ /\$[0-9a-fA-F]{2}/g);
   @values == 128 or die "initializer .byte line emitted " . scalar(@values) . " bytes, expected 128\n";
   length($line) < 1024 or die "initializer .byte line is unexpectedly long (" . length($line) . " bytes)\n";
}

print "initializer line wrapping passed\n";
