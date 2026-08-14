#!/usr/bin/perl
# runner: perl @FILE@ @VCSC_CC1@ @TEST_ROOT@
# phase: compile
# timeout: 30
# expectexit: 0
# expectstdout: inline value specialization tests passed

use strict;
use warnings;
use File::Temp qw(tempdir);
use File::Spec;

my ($cc1, $test_root) = @ARGV;
die "usage: $0 vcsc-cc1 test_root\n" unless defined $cc1 && defined $test_root;
my $tmp = tempdir('VCSC_inline_value_XXXX', TMPDIR => 1, CLEANUP => 1);
my $src = File::Spec->catfile($tmp, 'inline_value.c26');
my $asm = File::Spec->catfile($tmp, 'inline_value.s26');
open my $fh, '>', $src or die "write $src: $!";
print {$fh} <<'C26';
include "machine_6502.c26"

uint8_t mutable_global;
static void mutate(ref uint8_t y) { y++; }
static uint8_t observe_ref(ref const uint8_t y) { return y; }

static uint8_t explicit_ro(const uint8_t x) { return x + 1; }
static uint8_t implicit_ro(uint8_t x) { return x + 2; }
static uint8_t literal_ro(uint8_t x) { return x + 3; }
static uint8_t const_if_zero(uint8_t x) { if (x) { return 9; } else { return 4; } }
static uint8_t nested_const_leaf(uint8_t x) { return x + 6; }
static uint8_t nested_const_middle(uint8_t x) { return nested_const_leaf(x) + 7; }
static uint8_t compound_if(uint8_t x) { if (x + 1 == 5) { return 0x21; } else { return 0x22; } }
static uint8_t compound_ternary(uint8_t x) { return (x * 2 == 8) ? 0x31 : 0x32; }
static uint8_t compound_while(uint8_t x) { while (x + 1 != 5) { return 0x41; } return 0x42; }
static uint8_t compound_for(uint8_t x) { for (; x + 1 != 5; ) { return 0x51; } return 0x52; }
static uint8_t newly_single(uint8_t x) { return x + 1; }
static uint8_t prune_to_single(uint8_t x) {
   if (x + 1 == 5) { return newly_single(10); }
   else { return newly_single(20); }
}
static uint8_t written(uint8_t x) { x++; return x; }
static uint8_t write_through_call(uint8_t x) { mutate(x); return x; }
static uint8_t address_observed(const uint8_t x) { return observe_ref(x); }
static uint8_t global_fallback(uint8_t x) { return x + 4; }
static uint8_t escaped_actual(uint8_t x) { return x + 5; }
static uint8_t same_object_alias(uint8_t x, ref uint8_t y) { y++; return x; }
static uint16_t conversion_fallback(uint16_t x) { return x + 6; }

void main(void) {
   uint8_t explicit_actual := 10;
   uint8_t implicit_actual := 20;
   uint8_t written_actual := 30;
   uint8_t through_actual := 40;
   uint8_t observed_actual := 50;
   uint8_t escaped := 60;
   uint8_t aliased := 70;
   uint8_t converted := 80;
   uint16_t sink;

   sink := explicit_ro(explicit_actual);
   sink := implicit_ro(implicit_actual);
   sink := literal_ro(7);
   sink := const_if_zero(0);
   sink := nested_const_middle(4);
   sink := compound_if(4);
   sink := compound_ternary(4);
   sink := compound_while(4);
   sink := compound_for(4);
   sink := prune_to_single(4);
   sink := written(written_actual);
   sink := write_through_call(through_actual);
   sink := address_observed(observed_actual);
   sink := global_fallback(mutable_global);
   mutate(escaped);                 // address escaped before the call
   sink := escaped_actual(escaped);
   sink := same_object_alias(aliased, aliased);
   sink := conversion_fallback(converted);
}
C26
close $fh;

system($cc1, '-quiet', '-I', $test_root, $src, '-o', $asm) == 0
   or die "compile failed\n";
open my $afh, '<', $asm or die "read $asm: $!";
local $/;
my $text = <$afh>;
close $afh;

sub require_re { my ($n,$r)=@_; $text =~ $r or die "$n missing\n--- assembly ---\n$text"; }
sub forbid_re { my ($n,$r)=@_; $text !~ $r or die "$n unexpectedly present\n--- assembly ---\n$text"; }
sub proc_body {
   my ($name) = @_;
   $text =~ /\.proc \Q$name\E\b(.*?)\.endproc/s
      or die "$name procedure missing\n--- assembly ---\n$text";
   return $1;
}

for my $fn (qw(explicit_ro implicit_ro literal_ro const_if_zero nested_const_leaf nested_const_middle compound_if compound_ternary compound_while compound_for prune_to_single newly_single)) {
   forbid_re("specialized value slot $fn", qr/^\Q$fn\E\$x:\s*$/m);
}
require_re('explicit const aliases caller storage', qr/\.proc explicit_ro\b.*?main\$explicit_actual\b/s);
require_re('implicit const aliases caller storage', qr/\.proc implicit_ro\b.*?main\$implicit_actual\b/s);
require_re('integer constant is materialized in callee', qr/\.proc literal_ro\b.*?lda\s+#\$07\b/s);
require_re('constant-bound false branch remains', qr/\.proc const_if_zero\b.*?lda\s+#\$04\b/s);
forbid_re('constant-bound dead true branch', qr/\.proc const_if_zero\b.*?lda\s+#\$09\b/s);
$text =~ /\.proc nested_const_leaf\b(.*?)\.endproc/s
   or die "nested_const_leaf procedure missing\n--- assembly ---\n$text";
my $nested_leaf_body = $1;
$nested_leaf_body =~ /lda\s+#\$04\b/
   or die "nested constant did not propagate into leaf\n$nested_leaf_body";
$nested_leaf_body !~ /middle\$x/
   or die "nested leaf retained dead parent parameter symbol\n$nested_leaf_body";
my $compound_if_body = proc_body('compound_if');
$compound_if_body =~ /lda\s+#\$21\b/ or die "compound if selected arm missing\n$compound_if_body";
$compound_if_body !~ /lda\s+#\$22\b/ or die "compound if dead arm unexpectedly present\n$compound_if_body";
my $compound_ternary_body = proc_body('compound_ternary');
$compound_ternary_body =~ /lda\s+#\$31\b/ or die "compound ternary selected arm missing\n$compound_ternary_body";
$compound_ternary_body !~ /lda\s+#\$32\b/ or die "compound ternary dead arm unexpectedly present\n$compound_ternary_body";
my $compound_while_body = proc_body('compound_while');
$compound_while_body =~ /lda\s+#\$42\b/ or die "compound while fallthrough missing\n$compound_while_body";
$compound_while_body !~ /lda\s+#\$41\b/ or die "compound while dead body unexpectedly present\n$compound_while_body";
my $compound_for_body = proc_body('compound_for');
$compound_for_body =~ /lda\s+#\$52\b/ or die "compound for fallthrough missing\n$compound_for_body";
$compound_for_body !~ /lda\s+#\$51\b/ or die "compound for dead body unexpectedly present\n$compound_for_body";
$text =~ /\.proc newly_single\b(.*?)\.endproc/s
   or die "newly_single procedure missing\n--- assembly ---\n$text";
my $newly_single_body = $1;
$newly_single_body =~ /lda\s+#\$0a\b/
   or die "dead-edge fixed point did not specialize newly_single\n$newly_single_body";

for my $fn (qw(written write_through_call address_observed global_fallback escaped_actual same_object_alias conversion_fallback)) {
   require_re("fallback value slot $fn", qr/^\Q$fn\E\$x:\s*$/m);
}
require_re('same-object writable ref remains direct while value copy is preserved',
           qr/\.proc same_object_alias\b.*?main\$aliased\b/s);

print "inline value specialization tests passed\n";
