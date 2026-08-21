#!/usr/bin/env perl
# runner: perl @FILE@ @VCSC_CC1@ @TEST_ROOT@
# phase: compile
# expectexit: 0
# expectstdout: peephole inline asm codegen tests passed

use strict;
use warnings;
use File::Temp qw(tempdir);
use File::Spec;

my ($vcsc_cc1, $test_root) = @ARGV;
die "usage: $0 vcsc-cc1 test_root\n" if !defined $vcsc_cc1 || !defined $test_root;

my $tmp = tempdir('VCSC_peephole_inline_asm_XXXX', TMPDIR => 1, CLEANUP => 1);
my $src = File::Spec->catfile($tmp, 'inline_asm.c26');
open my $fh, '>', $src or die "write $src: $!";
print $fh <<'N_EOF';
include "machine_6502.c26"

void main(void) {
   asm   lda #$11
   asm   lda #$22
   asm   lda #$22
   asm   tax
   asm   tax
   asm   sta arg0
   asm   sta arg0
   asm   clc
   asm   clc
   asm   and #$0f
   asm   ldy #7
   asm   ldy #7
}
N_EOF
close $fh;

my @expected = (
   '  lda #$11',
   '  lda #$22',
   '  lda #$22',
   '  tax',
   '  tax',
   '  sta arg0',
   '  sta arg0',
   '  clc',
   '  clc',
   '  and #$0f',
   '  ldy #7',
   '  ldy #7',
);

sub compile_and_check {
   my ($mode, @flags) = @_;
   my $asm = File::Spec->catfile($tmp, "$mode.s26");
   my @cmd = ($vcsc_cc1, '-quiet', '-I', $test_root, @flags, $src, '-o', $asm);
   system(@cmd) == 0 or die "compile failed: @cmd\n";

   open my $afh, '<', $asm or die "read $asm: $!";
   my @lines = <$afh>;
   close $afh;
   chomp @lines;
   my $asm_text = join("\n", @lines) . "\n";

   my $start = -1;
   for my $i (0 .. $#lines) {
      if ($lines[$i] eq $expected[0]) {
         $start = $i;
         last;
      }
   }
   $start >= 0 or die "$mode: inline asm sequence start not found\n--- assembly ---\n$asm_text";
   for my $i (0 .. $#expected) {
      my $got = $lines[$start + $i] // '<end of file>';
      $got eq $expected[$i]
         or die "$mode: inline asm changed at item $i: got '$got', expected '$expected[$i]'\n--- assembly ---\n$asm_text";
   }
   $asm_text !~ /vcsc-cc1:inline-asm/
      or die "$mode: inline asm peephole markers leaked into assembly\n--- assembly ---\n$asm_text";
}

compile_and_check('optimized', '-fpeephole');
compile_and_check('disabled', '-fno-peephole');

print "peephole inline asm codegen tests passed\n";
