#!/usr/bin/env perl
# runner: perl @FILE@ @VCSC_CC1@ @TEST_ROOT@
# phase: compile
# expectexit: 0
# expectstdout: inline ref specialization tests passed

use strict;
use warnings;
use File::Temp qw(tempdir);
use File::Spec;

my ($vcsc_cc1, $test_root) = @ARGV;
die "usage: $0 vcsc-cc1 test_root\n" if !defined $vcsc_cc1 || !defined $test_root;
my $tmp = tempdir('VCSC_inline_ref_XXXX', TMPDIR => 1, CLEANUP => 1);
my $src = File::Spec->catfile($tmp, 'inline_ref.c26');
my $asm = File::Spec->catfile($tmp, 'inline_ref.s26');

open my $fh, '>', $src or die "write $src: $!";
print $fh <<'C26';
include "machine_6502.c26"

uint8_t ordinary;
uint8_t chain_target;
uint8_t mixed_target;
zeropage uint8_t zp_actual;
uint8_t external_split @[0x7403/0x7607];

struct Pair { uint8_t left; uint8_t right; };

static uint8_t spec_const(ref const uint8_t value) {
   return value;
}
static void spec_writeonly(ref writeonly uint8_t value) {
   value := 0x5a;
}
static void spec_regular(ref uint8_t value) {
   value++;
}
static void spec_zp(ref uint8_t value) {
   value++;
}
static void spec_split(ref uint8_t value) {
   value++;
}
static void spec_member(ref uint8_t value) {
   value++;
}
static void spec_index(ref uint8_t value) {
   value++;
}
static void fallback_runtime_index(ref uint8_t value) {
   value++;
}
static void asm_guarded(ref uint8_t value) {
   value++;
}
static void asm_body_guarded(ref uint8_t value) {
   asm nop;
   value++;
}
/* Deliberately define leaf before middle so fixed-point propagation, not source
   order, is what turns middle's specialized ref into leaf's fixed actual. */
static void chain_leaf(ref uint8_t value) {
   value++;
}
static void chain_middle(ref uint8_t value) {
   chain_leaf(value);
}
static void spec_mixed(uint8_t add1, ref uint8_t value, uint8_t add2) {
   value += add1;
   value += add2;
}

void asm_escape(void) {
   asm jsr asm_guarded;
}

void main(void) {
   Pair pair;
   uint8_t values[4];
   uint8_t i := 1;
   ordinary := spec_const(ordinary);
   spec_writeonly(ordinary);
   spec_regular(ordinary);
   spec_zp(zp_actual);
   spec_split(external_split);
   spec_member(pair.right);
   spec_index(values[2]);
   fallback_runtime_index(values[i]);
   asm_guarded(ordinary);
   asm_body_guarded(ordinary);
   chain_middle(chain_target);
   spec_mixed(2, mixed_target, 3);
}
C26
close $fh;

my @cmd = ($vcsc_cc1, '-quiet', '-I', $test_root, $src, '-o', $asm);
system(@cmd) == 0 or die "compile failed: @cmd\n";
open my $afh, '<', $asm or die "read $asm: $!";
local $/;
my $text = <$afh>;
close $afh;

sub require_re {
   my ($name, $re) = @_;
   $text =~ $re or die "$name missing\n--- assembly ---\n$text";
}
sub forbid_re {
   my ($name, $re) = @_;
   $text !~ $re or die "$name unexpectedly present\n--- assembly ---\n$text";
}

for my $fn (qw(spec_const spec_writeonly spec_regular spec_zp spec_split spec_member spec_index chain_leaf chain_middle spec_mixed)) {
   forbid_re("specialized ref slot $fn", qr/^\Q$fn\E\$value:\s*$/m);
}
require_re('const ref direct read', qr/\.proc spec_const\b.*?lda\s+ordinary\b/s);
require_re('writeonly ref direct store', qr/\.proc spec_writeonly\b.*?sta\s+ordinary\b/s);
require_re('regular ref direct read/write', qr/\.proc spec_regular\b.*?lda\s+ordinary\b.*?sta\s+ordinary\b/s);
require_re('zeropage actual direct access', qr/\.proc spec_zp\b.*?lda\s+zp_actual\b.*?sta\s+zp_actual\b/s);
require_re('split regular ref read address', qr/\.proc spec_split\b.*?lda\s+\$7403\b/s);
require_re('split regular ref direct write', qr/\.proc spec_split\b.*?sta\s+\$7607\b/s);
require_re('fixed member offset', qr/\.proc spec_member\b.*?main\$pair\s*\+\s*1/s);
require_re('fixed constant index', qr/\.proc spec_index\b.*?main\$values\s*\+\s*2/s);
require_re('fixed-point ref chain reaches leaf', qr/\.proc chain_leaf\b.*?lda\s+chain_target\b.*?sta\s+chain_target\b/s);
require_re('runtime-index fallback slot', qr/^fallback_runtime_index\$value:\s*$/m);
require_re('assembly-escaped function keeps ref slot', qr/^asm_guarded\$value:\s*$/m);
require_re('inline-asm callee keeps ref slot', qr/^asm_body_guarded\$value:\s*$/m);
require_re('runtime-index fallback pointer copy', qr/sta\s+fallback_runtime_index\$value\b.*?sta\s+fallback_runtime_index\$value\s*\+\s*1/s);

print "inline ref specialization tests passed\n";
