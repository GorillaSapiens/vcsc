#!/usr/bin/env perl
# runner: perl @TEST_ROOT@/vcsc_disassembler_fuzz.pl @REPO@ @TMP@
# phase: e2e
# timeout: 120

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
   ['fe',    8192],
   ['wd',    8195],
   ['dpc',  10495],
   ['fa',   12288],
   ['f6',   16384],
   ['e7',   16384],
   ['3e',   32768],
   ['3f',   32768],
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
   elsif ($layout eq 'fe') {
      # FE/SCABS RESET is taken from physical bank 0.  The released-cart JSR
      # idiom hits stack address $01FE, then uses the following target-high
      # data byte to select the bank.  Keep the historical Decathlon signature
      # while making both target and caller continuation deterministic.
      my $fe_code =
         "\xA2\xFF\x9A" .       # LDX #$FF; TXS
         "\x20\x00\xD0" .       # JSR $D000 -> bank 1
         "\xC6\xC5" .           # DEC $C5: FE detector signature tail
         "\xA9\x42\x85\x09\x60";
      substr($$bufref, 0x0100, length($fe_code), $fe_code);
      substr($$bufref, 0x1000, 3, "\xA9\x55\x60");
      substr($$bufref, 0x0FFA, 6, pack('v3', 0xf100, 0xf100, 0xf100));
      substr($$bufref, 0x1FFA, 6, pack('v3', 0x0000, 0x0000, 0x0000));
   }
   elsif ($layout eq 'e7') {
      # E7 vectors live in the fixed final 2K.  Exercise both RAM selectors
      # while executing from fixed ROM, restore lower ROM bank 5, then enter it.
      my $base = $size - 2048;
      my $e7_code =
         "\xAD\xE7\xFF" .       # lower window -> RAM
         "\xAD\xE9\xFF" .       # fixed RAM block 1
         "\xAD\xE5\xFF" .       # lower ROM bank 5
         "\x4C\x00\xF1";
      substr($$bufref, $base + 0x200, length($e7_code), $e7_code);
      substr($$bufref, 5 * 2048 + 0x100, length($code), $code);
      substr($$bufref, $base + 2042, 6, pack('v3', 0xfa00, 0xfa00, 0xfa00));
   }
   elsif ($layout eq '3e') {
      # 3E vectors live in the fixed final 2K.  Exercise the distinguishing
      # $3E RAM selector and the shared $3F ROM selector twice so the image
      # carries the canonical 3E identification evidence.
      my $base = $size - 2048;
      my $threee_code = "\xA9\x02\x85\x3E\xA9\x00\x85\x3F\xA9\x00\x85\x3F\x60";
      substr($$bufref, $base + 0x100, length($threee_code), $threee_code);
      substr($$bufref, $base + 2042, 6, pack('v3', 0xf900, 0xf900, 0xf900));
   }
   elsif ($layout eq '3f') {
      # 3F vectors live in the fixed final 2K.  Repeated explicit STA $3F
      # provides identification evidence while keeping the selected value known.
      my $base = $size - 2048;
      my $threef_code = "\xA9\x00\x85\x3F\xA9\x00\x85\x3F\x60";
      substr($$bufref, $base + 0x100, length($threef_code), $threef_code);
      substr($$bufref, $base + 2042, 6, pack('v3', 0xf900, 0xf900, 0xf900));
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
