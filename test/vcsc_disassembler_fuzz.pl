#!/usr/bin/env perl
# runner: perl @TEST_ROOT@/vcsc_disassembler_fuzz.pl @REPO@ @TMP@
# phase: e2e

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

my @layouts = (
   ['2k',    2048],
   ['4k',    4096],
   ['f8',    8192],
   ['wd',    8195],
   ['dpc',  10495],
   ['fa',   12288],
   ['f6',   16384],
   ['f4',   32768],
);
my @cases;

sub plant_entry {
   my ($bufref, $layout, $size) = @_;
   my $code = "\xA9\x42\x85\x09\x60"; # LDA #$42; STA COLUBK; RTS
   if ($layout eq '2k') {
      substr($$bufref, 0x100, length($code), $code);
      substr($$bufref, $size - 6, 6, pack('v3', 0xf900, 0xf900, 0xf900));
   }
   elsif ($layout eq 'wd') {
      # Every physical 1K chunk can occupy WD's top segment.  Give each a
      # self-contained top-segment vector/entry so the rest remains arbitrary.
      for my $bank (0 .. 7) {
         my $base = $bank * 1024;
         substr($$bufref, $base, length($code), $code);
         substr($$bufref, $base + 1018, 6, pack('v3', 0xfc00, 0xfc00, 0xfc00));
      }
   }
   elsif ($layout eq 'fa') {
      # FA's first $200 bytes are hidden by cartridge RAM at runtime.
      for my $bank (0 .. 2) {
         my $base = $bank * 4096;
         substr($$bufref, $base + 0x200, length($code), $code);
         substr($$bufref, $base + 4090, 6, pack('v3', 0xf200, 0xf200, 0xf200));
      }
   }
   else {
      my $program_bytes = $layout eq 'dpc' ? 8192 : $size;
      my $banks = int($program_bytes / 4096);
      for my $bank (0 .. $banks - 1) {
         my $base = $bank * 4096;
         substr($$bufref, $base + 0x100, length($code), $code);
         substr($$bufref, $base + 4090, 6, pack('v3', 0xf100, 0xf100, 0xf100));
      }
   }
}

for my $round (0 .. 1) {
   for my $entry (@layouts) {
      my ($layout, $size) = @$entry;
      my $name = sprintf('fuzz_%s_%d_r%d.bin', $layout, $size, $round);
      my $path = File::Spec->catfile($in, $name);
      my $buf = '';
      for (1 .. $size) {
         $buf .= chr(next_byte());
      }
      plant_entry(\$buf, $layout, $size);
      open(my $fh, '>:raw', $path) or die "open $path: $!\n";
      print {$fh} $buf or die "write $path: $!\n";
      close($fh) or die "close $path: $!\n";
      push @cases, [$name, $layout, $size];
   }
}

my $roundtrip = File::Spec->catfile($root, 'disassembler', 'roundtrip.pl');
my $rc = system($^X, $roundtrip, $in, $out);
die "roundtrip verifier failed\n" if $rc != 0;

for my $entry (@cases) {
   my ($name, $layout, $size) = @$entry;
   (my $stem = $name) =~ s/\.bin\z//i;
   die "missing retained source for $stem\n"
      if !-f File::Spec->catfile($out, "$stem.s26");
   die "missing rebuilt ROM for $stem\n"
      if !-f File::Spec->catfile($out, $name);
   my $source = File::Spec->catfile($out, "$stem.s26");
   open(my $sfh, '<', $source) or die "open $source: $!\n";
   local $/;
   my $text = <$sfh>;
   close($sfh) or die "close $source: $!\n";
   die "$stem random data was overclassified as graphics\n"
      if $text =~ /^\s*\.byte\s+%[01]{8}\s+;/m;
   die "$stem random data was overclassified as a pointer table\n"
      if $text =~ /probable little-endian ROM pointer table/i;
   die "$stem random data was overclassified as a color table\n"
      if $text =~ /probable TIA color table/i;
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
