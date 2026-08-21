#!/usr/bin/env perl
# runner: perl @FILE@ @VCSC_CC1@ @TEST_ROOT@
# phase: compile
# expectexit: 0
# expectstdout: template inline asm codegen tests passed

use strict;
use warnings;
use File::Temp qw(tempdir);
use File::Spec;

my ($vcsc_cc1, $test_root) = @ARGV;
die "usage: $0 vcsc-cc1 test_root\n" if !defined $vcsc_cc1 || !defined $test_root;

my $tmp = tempdir('VCSC_template_inline_asm_XXXX', TMPDIR => 1, CLEANUP => 1);
my $component = File::Spec->catfile($tmp, 'component.c26');
my $main = File::Spec->catfile($tmp, 'main.c26');

open my $cfh, '>', $component or die "write $component: $!";
print $cfh <<'C26';
uint8_t TEMPLATE_value;
void TEMPLATE_helper(void) {
}
void TEMPLATE(void) {
}
inline void TEMPLATE_touch(void) {
   asm lda TEMPLATE_value
   asm lda TEMPLATE_value
   asm sta TEMPLATE_value
   asm sta TEMPLATE_value
   asm jsr TEMPLATE_helper
   asm jsr TEMPLATE
   asm .byte "TEMPLATE_value"
   asm lda MY_TEMPLATE_HELPER
}
C26
close $cfh;

open my $mfh, '>', $main or die "write $main: $!";
print $mfh <<'C26';
include "machine_6502.c26"
instantiate "component.c26" as first
instantiate "component.c26" as λ
uint8_t MY_TEMPLATE_HELPER;
void main(void) {
   first_touch();
   λ_touch();
}
C26
close $mfh;

my @first = (
   'lda first_value',
   'lda first_value',
   'sta first_value',
   'sta first_value',
   'jsr first_helper',
   'jsr first',
   '.byte "TEMPLATE_value"',
   'lda MY_TEMPLATE_HELPER',
);
my @unicode = (
   'lda ?u03BB?_value',
   'lda ?u03BB?_value',
   'sta ?u03BB?_value',
   'sta ?u03BB?_value',
   'jsr ?u03BB?_helper',
   'jsr ?u03BB?',
   '.byte "TEMPLATE_value"',
   'lda MY_TEMPLATE_HELPER',
);

sub require_sequence {
   my ($mode, $text, $label, $expected) = @_;
   my @lines = split /\n/, $text;
   for my $start (0 .. $#lines) {
      next if $lines[$start] ne $expected->[0];
      my $ok = 1;
      for my $i (0 .. $#$expected) {
         if (!defined($lines[$start + $i]) || $lines[$start + $i] ne $expected->[$i]) {
            $ok = 0;
            last;
         }
      }
      return if $ok;
   }
   die "$mode: $label template inline-asm sequence missing or changed\n--- assembly ---\n$text";
}

sub compile_and_check {
   my ($mode, @flags) = @_;
   my $asm = File::Spec->catfile($tmp, "$mode.s26");
   my @cmd = ($vcsc_cc1, '-quiet', '-I', $test_root, '-I', $tmp, @flags, $main, '-o', $asm);
   system(@cmd) == 0 or die "compile failed: @cmd\n";
   open my $afh, '<', $asm or die "read $asm: $!";
   local $/;
   my $text = <$afh>;
   close $afh;

   require_sequence($mode, $text, 'ASCII', \@first);
   require_sequence($mode, $text, 'UTF-8', \@unicode);
   $text !~ /(?:^|\s)TEMPLATE_(?:value|helper)(?:\s|$)/m
      or die "$mode: unquoted template identifier survived inline-asm rewriting\n--- assembly ---\n$text";
   $text !~ /vcsc-cc1:inline-asm/
      or die "$mode: inline-asm peephole markers leaked into assembly\n--- assembly ---\n$text";
}

compile_and_check('optimized', '-fpeephole');
compile_and_check('disabled', '-fno-peephole');
print "template inline asm codegen tests passed\n";
