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

# Deterministic arbitrary bytes exercise supported mapper sizes without relying
# on Perl's implementation-specific rand() sequence. Unsupported/raw sizes are
# tested separately below and must now fail rather than masquerade as a 100%-data
# successful disassembly.
my $state = 0x260816;
sub next_byte {
   $state = (1103515245 * $state + 12345) & 0x7fffffff;
   return ($state >> 11) & 0xff;
}

my @sizes = (2048, 4096, 8192, 16384, 32768);
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
   my $source = File::Spec->catfile($out, "$stem.s26");
   open(my $sfh, '<', $source) or die "open $source: $!\n";
   local $/;
   my $text = <$sfh>;
   close($sfh) or die "close $source: $!\n";
   die "$stem random data was overclassified as graphics\n"
      if $text =~ /^\s*\.byte\s+%[01]{8}\s+;/m;
}

my @unsupported = (1, 17, 257, 655, 4097, 5000, 8191);
my $disas = File::Spec->catfile($root, 'disassembler', 'vcsc-disas');
for my $size (@unsupported) {
   my $path = File::Spec->catfile($tmp, "unsupported_$size.bin");
   open(my $fh, '>:raw', $path) or die "open $path: $!\n";
   print {$fh} chr(0x02) x $size or die "write $path: $!\n";
   close($fh) or die "close $path: $!\n";
   my $s26 = File::Spec->catfile($tmp, "unsupported_$size.s26");
   unlink($s26);
   system {$disas} $disas, '-o', $s26, $path;
   die "unsupported $size-byte image unexpectedly succeeded\n" if $? == 0;
   die "unsupported $size-byte image left output source\n" if -e $s26;
}

print "vcsc-disassembler deterministic fuzz ok\n";
