#!/usr/bin/env perl
use strict;
use warnings;
use File::Temp qw(tempdir);
use File::Spec;

my ($vcsc_cc1, $test_root) = @ARGV;
die "usage: $0 vcsc-cc1 test_root\n" if !defined $vcsc_cc1 || !defined $test_root;

my $tmp = tempdir('VCSC_peephole_inline_asm_XXXX', TMPDIR => 1, CLEANUP => 1);
my $src = File::Spec->catfile($tmp, 'inline_asm.vcsc');
open my $fh, '>', $src or die "write $src: $!";
print $fh <<'N_EOF';
include "machine_6502.vcsc"

void main(void) {
   asm   lda #$01
   asm   lda #$01
}
N_EOF
close $fh;

my $asm = File::Spec->catfile($tmp, 'inline_asm.s');
my @cmd = ($vcsc_cc1, '-quiet', '-I', $test_root, $src, '-o', $asm);
system(@cmd) == 0 or die "compile failed: @cmd\n";

open my $afh, '<', $asm or die "read $asm: $!";
my @lines = <$afh>;
close $afh;
chomp @lines;

my $asm_text = join("\n", @lines) . "\n";
my $count = 0;
for my $line (@lines) {
   $count++ if $line eq '  lda #$01';
}

die "expected two protected indented inline asm loads, got $count\n--- assembly ---\n$asm_text" if $count != 2;
die "inline asm peephole markers leaked into assembly\n--- assembly ---\n$asm_text" if $asm_text =~ /vcsc-cc1:inline-asm/;

print "peephole inline asm codegen tests passed\n";
