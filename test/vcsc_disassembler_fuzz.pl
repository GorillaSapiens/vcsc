#!/usr/bin/env perl
# runner: perl @TEST_ROOT@/vcsc_disassembler_fuzz.pl @REPO@ @TMP@
# phase: e2e
# timeout: 20

use strict;
use warnings;
use File::Path qw(make_path);
use File::Spec;

my ($root, $tmp) = @ARGV;
die "usage: $0 REPO TMP\n" if !defined($tmp) || @ARGV != 2;

my $in = File::Spec->catdir($tmp, 'in');
my $out = File::Spec->catdir($tmp, 'out');
make_path($in);

# Deterministic arbitrary bytes exercise both supported-size analysis and raw
# fallback without relying on Perl's implementation-specific rand() sequence.
my $state = 0x260816;
sub next_byte {
   $state = (1103515245 * $state + 12345) & 0x7fffffff;
   return ($state >> 11) & 0xff;
}

my @sizes = (1, 17, 257, 655, 2048, 4096, 4097, 5000,
             8192, 8191, 16384, 32768);
for my $i (0 .. $#sizes) {
   my $size = $sizes[$i];
   my $name = sprintf('fuzz_%02d_%d.bin', $i, $size);
   my $path = File::Spec->catfile($in, $name);
   open(my $fh, '>:raw', $path) or die "open $path: $!\n";
   my $buf = '';
   for (1 .. $size) {
      $buf .= chr(next_byte());
   }
   print {$fh} $buf or die "write $path: $!\n";
   close($fh) or die "close $path: $!\n";
}

my $roundtrip = File::Spec->catfile($root, 'disassembler', 'roundtrip.pl');
my $rc = system($^X, $roundtrip, $in, $out);
die "roundtrip verifier failed\n" if $rc != 0;

for my $i (0 .. $#sizes) {
   my $size = $sizes[$i];
   my $stem = sprintf('fuzz_%02d_%d', $i, $size);
   die "missing retained source for $stem\n"
      if !-f File::Spec->catfile($out, "$stem.s26");
   die "missing rebuilt ROM for $stem\n"
      if !-f File::Spec->catfile($out, "$stem.bin");
}

print "vcsc-disassembler deterministic fuzz ok\n";
