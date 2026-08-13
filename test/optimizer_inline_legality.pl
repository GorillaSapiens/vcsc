#!/usr/bin/perl
# runner: perl @FILE@ @VCSC_CC1@ @TEST_ROOT@
# phase: compile
# timeout: 45
# expectexit: 0
# expectstdout: optimizer inline legality tests passed

use strict;
use warnings;
use File::Temp qw(tempdir);
use File::Spec;

my ($cc1,$test_root)=@ARGV;
die "usage: $0 vcsc-cc1 test_root\n" unless defined $cc1 && defined $test_root;
my $tmp=tempdir('VCSC_optimizer_inline_legality_XXXX',TMPDIR=>1,CLEANUP=>1);
my $src=File::Spec->catfile($tmp,'legality.c26');
my $out=File::Spec->catfile($tmp,'legality.s26');
open my $fh,'>',$src or die "write $src: $!";
print {$fh} <<'C26';
include "machine_6502.c26"
mem bank1 { $start:0xD000 $size:0x1000 $ro };
mem resultbox { $start:0x0080 $size:0x0010 $rw };

/* A data object's page contract remains independently placed and must not veto
   moving code that merely references it. */
page const uint8_t lookup_table[4] := { 1, 2, 3, 4 };
static uint8_t safe_table(void) { return lookup_table[0]; }
static uint8_t safe_plain(uint8_t x) { return x + 1; }

/* Callee and caller hard page-containment contracts are both vetoes. */
page static void page_callee(void) { }
static void page_target(void) { }
page static void page_caller(void) { page_target(); }

/* Independently placeable named function regions are conservative vetoes on
   either side of the callsite until trial placement/rollback exists. */
bank1 static void region_callee(void) { }
static void region_target(void) { }
bank1 static void region_caller(void) { region_target(); }
resultbox static uint8_t result_callee(void) { return 7; }

/* A hard branch in the caller makes changing the caller layout unproven. */
static void hard_callee(void) {
   asm lda #0;
   asm beq.same @done;
   asm nop;
   asm @done:;
}

static void same_target(void) { }
static void same_caller(void) {
   same_target();
   asm lda #0;
   asm beq.same @done;
   asm nop;
   asm @done:;
}
static void cross_target(void) { }
static void cross_caller(void) {
   cross_target();
   asm lda #0;
   asm beq.cross @done;
   asm nop;
   asm @done:;
}

/* .flex is not a hard page contract: the target may still inline into a caller
   that contains otherwise ordinary inline assembly. */
static void flex_target(void) { }
static void flex_caller(void) {
   flex_target();
   asm lda #0;
   asm beq.flex @done;
   asm nop;
   asm @done:;
}

/* Hard policy introduced by source-inline expansion is still generated inside
   wrapper_caller and must be seen transitively by the placement proof. */
inline void hard_inline_wrapper(void) {
   asm lda #0;
   asm beq.same @done;
   asm nop;
   asm @done:;
}
static void wrapper_target(void) { }
static void wrapper_caller(void) {
   wrapper_target();
   hard_inline_wrapper();
}

void main(void) {
   uint8_t v := safe_table();
   v := safe_plain(v);
   page_callee();
   page_caller();
   region_callee();
   region_caller();
   v += result_callee();
   hard_callee();
   same_caller();
   cross_caller();
   flex_caller();
   wrapper_caller();
}
C26
close $fh;

system($cc1,'-quiet','-I',$test_root,'-X','inlineir',$src,'-o',$out)==0
   or die "forced optimizer-inline compile failed\n";
open my $rf,'<',$out or die "read $out: $!"; local $/; my $asm=<$rf>//''; close $rf;
sub req { my($name,$re)=@_; $asm =~ $re or die "$name missing\n--- asm ---\n$asm"; }
sub forbid { my($name,$re)=@_; $asm !~ $re or die "$name unexpectedly present\n--- asm ---\n$asm"; }

for my $name (qw(page_callee page_target page_caller region_callee region_target region_caller result_callee hard_callee same_target same_caller cross_target cross_caller flex_caller wrapper_target wrapper_caller)) {
   req("retained $name",qr/^\.proc\s+\Q$name\E\b/m);
}
for my $name (qw(safe_table safe_plain flex_target)) {
   forbid("standalone $name",qr/^\.proc\s+\Q$name\E\b/m);
   req("inline expansion $name",qr/begin optimizer inline expansion \Q$name\E\b/);
}
req('page callee containment',qr/^\.proc\s+page_callee\b\s+\.pagecontain/m);
req('page caller containment',qr/^\.proc\s+page_caller\b\s+\.pagecontain/m);
req('callee code region',qr/\.segment "CODE\.bank1"\s+\.proc region_callee\b/s);
req('caller code region',qr/\.segment "CODE\.bank1"\s+\.proc region_caller\b/s);
req('same annotation retained',qr/beq\.same\s+\@/);
req('cross annotation retained',qr/beq\.cross\s+\@/);

print "optimizer inline legality tests passed\n";
