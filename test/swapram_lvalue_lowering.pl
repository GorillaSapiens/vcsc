#!/usr/bin/env perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: swapram lvalue lowering ok
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

my $cc1 = File::Spec->catfile($repo, 'compiler', 'vcsc-cc1');
my $vcs = File::Spec->catdir($repo, 'libraries', 'vcs');
my $src = File::Spec->catfile($tmp, 'swapram_access.c26');
my $asm = File::Spec->catfile($tmp, 'swapram_access.s26');

write_file($src, <<'SRC');
include "3E/mapper_8k.c26"

struct Pair {
   uint8_t byte;
   uint16_t word;
};

swapram uint8_t one;
swapram uint16_t two;
swapram uint24_t three;
swapram uint32_t four;
swapram uint16_t words[8];
swapram Pair pair;

bank3 void main(void) {
   uint8_t a;
   uint16_t b;
   uint24_t c;
   uint32_t d;
   uint8_t i;
   swapram uint16_t local_swap := 5;

   a := one;   one := a;
   b := two;   two := b;
   c := three; three := c;
   d := four;  four := d;

   i := 3;
   b := words[i];
   words[i] := b;
   a := pair.byte;
   pair.word := b;
   b := local_swap;
   local_swap := b;

   one += a;
   ++one;
   words[i] += b;
}
SRC

require_ok('swapram access compile', $cc1, '-I', $vcs, '-o', $asm, $src);
my $text = slurp($asm);

for my $width (1 .. 4) {
   $text =~ /^\.import swapram_read$width$/m
      or die "missing swapram_read$width import\n$text";
   $text =~ /^\.import swapram_write$width$/m
      or die "missing swapram_write$width import\n$text";
   $text =~ /\bjsr swapram_read$width\b/
      or die "missing swapram_read$width call\n$text";
   $text =~ /\bjsr swapram_write$width\b/
      or die "missing swapram_write$width call\n$text";
   $text =~ /\bjsr swapram_read$width\s*\n\s*\.banktarget swapram_read$width\b/
      or die "swapram_read$width call is not bankcall annotated\n$text";
   $text =~ /\bjsr swapram_write$width\s*\n\s*\.banktarget swapram_write$width\b/
      or die "swapram_write$width call is not bankcall annotated\n$text";
}

# Generic bankcall owns ptr0 while crossing into the fixed bank.  The private
# helper ABI therefore carries the three-byte logical address as arg0:ptr1 and
# uses ptr2 for the ordinary CPU-addressable source/destination buffer.
$text =~ /sta ptr2\b.*?#<\{two \+ 0\}.*?sta ptr0\b.*?lda #\^\{two \+ 0\}.*?sta arg0\b.*?lda ptr0\b.*?sta ptr1\b.*?jsr swapram_read2/s
   or die "swapram helper ABI did not use arg0:ptr1 logical address plus ptr2 buffer\n$text";

# The logical symbol address may be materialized into ptr0, but it must never be
# used as a CPU load/store/inc/dec operand.
$text !~ /^\s*(?:lda|sta|inc|dec)\s+(?:one|two|three|four|words|pair|main\$local_swap)(?:\s|\+|,|$)/m
   or die "swapram object escaped to ordinary CPU memory access\n$text";

# Runtime array indexing must still compute a logical ptr0 and dispatch through
# the width-specific helper rather than dereferencing ptr0 itself.
$text =~ /#<\{words \+ 0\}.*?asl arg0.*?jsr swapram_read2/s
   or die "runtime-indexed swapram read did not use logical-address helper path\n$text";
$text =~ /#<\{words \+ 0\}.*?asl arg0.*?jsr swapram_write2/s
   or die "runtime-indexed swapram write did not use logical-address helper path\n$text";

my @bad = (
   [ 'address',
     'bank3 void main(void) { uint8_t *p; p := &value; }' ],
   [ 'read_address',
     'bank3 void main(void) { const uint8_t *p; p := &<value; }' ],
   [ 'write_address',
     'bank3 void main(void) { writeonly uint8_t *p; p := &>value; }' ],
   [ 'decay',
     'bank3 void main(void) { uint8_t *p; p := values; }' ],
   [ 'ref',
     'void touch(ref uint8_t x) { x := 1; } bank3 void main(void) { touch(value); }' ],
);
for my $case (@bad) {
   my ($name, $body) = @$case;
   my $bad_src = File::Spec->catfile($tmp, "swapram_${name}.c26");
   my $bad_asm = File::Spec->catfile($tmp, "swapram_${name}.s26");
   write_file($bad_src, qq{include "3E/mapper_8k.c26"\nswapram uint8_t value;\nswapram uint8_t values[8];\n$body\n});
   require_fail($name,
                "swapram object",
                $cc1, '-I', $vcs, '-o', $bad_asm, $bad_src);
}

print "swapram lvalue lowering ok\n";
