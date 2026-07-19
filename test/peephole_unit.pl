#!/usr/bin/env perl
use strict;
use warnings;
use File::Basename qw(dirname);
use File::Spec;
use Cwd qw(abs_path);

my $test_root = dirname(abs_path($0));
my $repo_root = abs_path(File::Spec->catdir($test_root, '..'));
my $build = File::Spec->catdir('/tmp', 'VCSC_peephole_unit_' . $$);
mkdir $build or die "mkdir $build: $!";
my $c = File::Spec->catfile($build, 'peephole_unit.c');
my $exe = File::Spec->catfile($build, 'peephole_unit');

open my $fh, '>', $c or die $!;
print $fh <<'C_EOF';
#define NO_XRAY_OVERRIDE_EXIT 1
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void message(const char *fmt, ...) { (void) fmt; }
void debug(const char *fmt, ...) { (void) fmt; }
int get_xray(int n) { (void) n; return 0; }

#include "REPO/compiler/emit.c"

static char *run_pass(const char *input) {
   EmitSink es = EMIT_INIT;
   emit(&es, "%s", input);
   emit_peephole_optimize(&es);
   return es.head ? (char *) es.head->txt : strdup("");
}

static int contains(const char *haystack, const char *needle) {
   return strstr(haystack, needle) != NULL;
}

static int count_of(const char *haystack, const char *needle) {
   int count = 0;
   size_t n = strlen(needle);
   const char *p = haystack;
   while ((p = strstr(p, needle)) != NULL) {
      count++;
      p += n;
   }
   return count;
}

static void require_true(int ok, const char *msg, const char *text) {
   if (!ok) {
      fprintf(stderr, "%s\n--- output ---\n%s\n", msg, text ? text : "");
      exit(1);
   }
}

int main(void) {
   char *out;

   require_true(instruction_size_for("dex", NULL) == 1, "dex must count as 1 byte", NULL);
   require_true(instruction_size_for("bpl", "@l") == 2, "bpl must count as 2 bytes", NULL);
   require_true(instruction_size_for("ror", "a") == 1, "ror a must count as 1 byte", NULL);
   require_true(instruction_size_for("jmp", "(ptr0)") == 3, "jmp indirect must count as 3 bytes", NULL);
   require_true(instruction_size_for("lda", "arg0,x") == 2, "compiler zp indexed loads must count as 2 bytes", NULL);

   out = run_pass("    bcc @l\n@l:\n    bcs @m\n@m:\n    bmi @n\n@n:\n    bpl @o\n@o:\n    bvc @p\n@p:\n    bvs @q\n@q:\n");
   require_true(!contains(out, "bcc @l") && !contains(out, "bcs @m") && !contains(out, "bmi @n") &&
                !contains(out, "bpl @o") && !contains(out, "bvc @p") && !contains(out, "bvs @q"),
                "all branch-to-next-label opcodes must be removed", out);

   out = run_pass("    bne @second\n@first:\n@second:\n    lda #$01\n");
   require_true(!contains(out, "bne @second"), "branch-to-next-label cleanup must see through adjacent labels", out);

   out = run_pass("    lda #$05\n    sta arg0\n    lda arg0\n");
   require_true(count_of(out, "lda") == 1, "lda #imm; sta arg0; lda arg0 should remove the final load", out);


   out = run_pass("    lda #$00\n    bne @skip\n    sta arg0\n@skip:\n");
   require_true(!contains(out, "bne @skip") && contains(out, "sta arg0"), "bne after known-zero N/Z flags must be removed as never taken", out);

   out = run_pass("    lda #$01\n    beq @skip\n    sta arg0\n@skip:\n");
   require_true(!contains(out, "beq @skip") && contains(out, "sta arg0"), "beq after known-nonzero N/Z flags must be removed as never taken", out);

   out = run_pass("    lda #$7f\n    bmi @skip\n    sta arg0\n@skip:\n");
   require_true(!contains(out, "bmi @skip") && contains(out, "sta arg0"), "bmi after known-positive N flag must be removed as never taken", out);

   out = run_pass("    lda #$80\n    bpl @skip\n    sta arg0\n@skip:\n");
   require_true(!contains(out, "bpl @skip") && contains(out, "sta arg0"), "bpl after known-negative N flag must be removed as never taken", out);

   out = run_pass("    sec\n    bcc @skip\n    sta arg0\n@skip:\n");
   require_true(!contains(out, "bcc @skip") && contains(out, "sta arg0"), "bcc after known-set carry must be removed as never taken", out);

   out = run_pass("    clc\n    bcs @skip\n    sta arg0\n@skip:\n");
   require_true(!contains(out, "bcs @skip") && contains(out, "sta arg0"), "bcs after known-clear carry must be removed as never taken", out);

   out = run_pass("    clv\n    bvs @skip\n    sta arg0\n@skip:\n");
   require_true(!contains(out, "bvs @skip") && contains(out, "sta arg0"), "bvs after known-clear overflow must be removed as never taken", out);

   out = run_pass("    lda $d000\n    bne @maybe\n    sta arg0\n@maybe:\n");
   require_true(contains(out, "bne @maybe"), "branches must stay when N/Z flags are unknown", out);

   out = run_pass("    lda #$00\n    beq @taken\n    sta arg0\n@taken:\n");
   require_true(contains(out, "beq @taken"), "always-taken branches must not be removed as never-taken branches", out);

   out = run_pass("    clc\n    bcc @taken\n    sta arg0\n@taken:\n");
   require_true(contains(out, "bcc @taken"), "always-taken carry branches must not be removed as never-taken branches", out);

   out = run_pass("    lda #$01\n    lda #$02\n    sta arg0\n");
   require_true(!contains(out, "lda #$01") && contains(out, "lda #$02") && contains(out, "sta arg0"), "dead adjacent lda overwritten by another lda should be removed", out);

   out = run_pass("    lda #$01\n    lda #$01\n    sta arg0\n");
   require_true(count_of(out, "lda #$01") == 1 && contains(out, "sta arg0"), "dead adjacent identical lda should leave exactly one load, not remove both", out);

   out = run_pass("    ldx arg0\n    ldx #$02\n    stx ptr0\n    ldy arg1\n    ldy #$03\n    sty ptr1\n");
   require_true(!contains(out, "ldx arg0") && contains(out, "ldx #$02") && !contains(out, "ldy arg1") && contains(out, "ldy #$03"), "dead adjacent ldx/ldy loads from compiler scratch should be removed", out);

   out = run_pass("    lda $d000\n    lda #$02\n    sta arg0\n");
   require_true(contains(out, "lda $d000") && contains(out, "lda #$02"), "dead adjacent load removal must not discard untracked/hardware reads", out);

   out = run_pass("    lda #$01\n@incoming:\n    lda #$02\n");
   require_true(contains(out, "lda #$01") && contains(out, "lda #$02"), "dead adjacent load removal must not cross labels", out);

   out = run_pass("    lda $d000\n    sta arg0\n    lda arg0\n    sta ptr0\n    ldx #$00\n");
   require_true(count_of(out, "lda arg0") == 0 && contains(out, "sta ptr0"), "unknown A stored to tracked scratch should make a later dead-flag reload redundant", out);

   out = run_pass("    lda $d000\n    sta arg0\n    lda arg0\n    bne @used\n    nop\n@used:\n");
   require_true(count_of(out, "lda arg0") == 1, "unknown A store/load forwarding must not remove a reload whose N/Z flags feed a branch", out);

   out = run_pass("    ldx $d000\n    stx arg0\n    ldx arg0\n    lda #$00\n");
   require_true(count_of(out, "ldx arg0") == 0, "unknown X stored to tracked scratch should make a later dead-flag reload redundant", out);

   out = run_pass("    ldy $d000\n    sty arg0\n    ldy arg0\n    lda #$00\n");
   require_true(count_of(out, "ldy arg0") == 0, "unknown Y stored to tracked scratch should make a later dead-flag reload redundant", out);

   out = run_pass("    lda #$05\n    sta arg0\n    lda #$05\n");
   require_true(count_of(out, "lda") == 1, "sta must preserve A for duplicate load removal", out);

   out = run_pass("    ldx arg0\n    lda #$05\n    sta arg0\n    ldx arg0\n");
   require_true(count_of(out, "ldx arg0") == 2, "store to arg0 must invalidate X value loaded from arg0", out);

   out = run_pass("    lda #$01\n    cmp #$02\n    lda #$01\n");
   require_true(count_of(out, "lda #$01") == 2, "cmp preserves A but invalidates flags, so the second lda must stay", out);

   out = run_pass("    ldy #0\n    lda (ptr0),y\n    ldy #0\n    sta __vcsc_scratch_0,y\n    ldy #1\n");
   require_true(count_of(out, "ldy #0") == 1, "duplicate ldy with dead N/Z flags before a later flag-setting load should be removed", out);

   out = run_pass("    ldy #0\n    lda (ptr0),y\n    ldy #0\n    bne @taken\n@taken:\n");
   require_true(count_of(out, "ldy #0") == 2, "duplicate ldy must stay when its N/Z flags feed a conditional branch", out);

   out = run_pass("    lda #$01\n    cmp #$02\n    lda #$01\n    bcc @uses_nz\n    inx\n@uses_nz:\n    bne @done\n@done:\n");
   require_true(count_of(out, "lda #$01") == 2, "C/V-only conditional branches must block dead-N/Z load removal because they can skip a later N/Z overwrite", out);

   out = run_pass("    ldy #1\n    lda __vcsc_scratch_0,y\n    ldy #1\n    sta (ptr1),y\n    jmp @fini\n@fini:\n    lda #$02\n");
   require_true(count_of(out, "ldy #1") == 1 && !contains(out, "jmp @fini"), "dead flag scan should see through a removable jump-to-next-label", out);

   out = run_pass("    lda #$03\n    tax\n    ldx #$03\n");
   require_true(!contains(out, "ldx #$03"), "tax should make a following identical ldx redundant", out);

   out = run_pass("    ldx #$03\n    lda #$03\n    tax\n");
   require_true(!contains(out, "tax"), "tax should be removed when X and N/Z already match A", out);

   out = run_pass("    ldx #$03\n    lda #$03\n    cmp #$04\n    tax\n    lda #$00\n");
   require_true(!contains(out, "tax"), "tax should be removed when only its dead N/Z flags differ", out);

   out = run_pass("    ldx #$03\n    lda #$03\n    cmp #$04\n    tax\n    bne @used\n@used:\n");
   require_true(contains(out, "tax"), "tax must stay when its N/Z flags feed a branch", out);

   out = run_pass("    lda #$05\n    sta arg0\n    sta arg0\n    ldx #$06\n");
   require_true(count_of(out, "sta arg0") == 1, "duplicate sta to compiler scratch with unchanged A should be removed", out);

   out = run_pass("    lda #$07\n    sta arg0\n    lda #$08\n    sta arg0\n");
   require_true(count_of(out, "sta arg0") == 2, "store to compiler scratch must stay when the stored value changed", out);

   out = run_pass("    lda #$09\n    sta $d020\n    sta $d020\n");
   require_true(count_of(out, "sta $d020") == 2, "stores to untracked/non-compiler addresses must not be removed", out);

   out = run_pass("    lda #$01\n    cmp #$02\n    lda #$01\n    brk\n    lda #$00\n");
   require_true(count_of(out, "lda #$01") == 2, "brk must be treated as observing N/Z through the pushed status byte", out);

   out = run_pass("    lda #$f0\n    and #$0f\n    sta arg0\n");
   require_true(contains(out, "lda #$00") && !contains(out, "and #$0f") && contains(out, "sta arg0"), "adjacent lda-immediate/and-immediate should fold to one immediate lda", out);

   out = run_pass("    lda #$55\n    eor #%11111111\n    sta arg0\n");
   require_true(contains(out, "lda #$aa") && !contains(out, "eor"), "adjacent lda-immediate/eor-immediate should fold binary immediates", out);

   out = run_pass("    lda #1\n    ora #2\n    sta arg0\n");
   require_true(contains(out, "lda #$03") && !contains(out, "ora #2"), "adjacent lda-immediate/ora-immediate should fold decimal immediates", out);

   out = run_pass("    lda #$f0\n@incoming:\n    and #$0f\n");
   require_true(contains(out, "and #$0f"), "immediate ALU folding must not cross labels", out);

   out = run_pass("    sec\n    sec\n    php\n");
   require_true(count_of(out, "sec") == 1 && contains(out, "php"), "duplicate sec should be removed while preserving the flag value observed by php", out);

   out = run_pass("    clc\n    rol a\n    clc\n");
   require_true(count_of(out, "clc") == 2, "carry-writing instructions must invalidate redundant clc/sec tracking", out);

   out = run_pass("    clv\n    bit arg0\n    clv\n");
   require_true(count_of(out, "clv") == 2, "overflow-writing bit must invalidate redundant clv tracking", out);

   out = run_pass("    sed\n    adc #$01\n    sed\n");
   require_true(count_of(out, "sed") == 1, "adc/sbc must not invalidate decimal-mode facts because they do not change D", out);

   out = run_pass("    sei\n    jsr _helper\n    sei\n");
   require_true(count_of(out, "sei") == 2, "calls must invalidate interrupt-flag facts before redundant sei/cli removal", out);

   out = run_pass("    clc\n@incoming:\n    clc\n");
   require_true(count_of(out, "clc") == 2, "labels must remain status-fact barriers because other control-flow paths can enter there", out);

   out = run_pass("    lda #$11\n    sta arg0\n    lda arg0\n    sta ptr0\n    lda #$22\n    sta arg0\n    lda arg0\n    sta ptr0\n");
   require_true(count_of(out, "sta ptr0") == 2, "changing arg0 must invalidate tracked memory facts that reference arg0", out);

   out = run_pass("    lda #$01\n" EMIT_INLINE_ASM_BEGIN_MARKER "\n    lda #$01\n" EMIT_INLINE_ASM_END_MARKER "\n    lda #$01\n");
   require_true(count_of(out, "lda #$01") == 3 && !contains(out, "vcsc-cc1:inline-asm"), "inline asm markers must protect indented programmer assembly and disappear", out);

   out = run_pass("    lda #$01\n    cmp #$02\n    lda #$01\n" EMIT_INLINE_ASM_BEGIN_MARKER "\n    nop\n" EMIT_INLINE_ASM_END_MARKER "\n    lda #$00\n");
   require_true(count_of(out, "lda #$01") == 2, "inline asm must be an N/Z liveness barrier even when the raw line looks harmless", out);

   puts("peephole unit tests passed");
   return 0;
}
C_EOF
close $fh;

my $text;
{
   local $/;
   open my $in, '<', $c or die $!;
   $text = <$in>;
   close $in;
}
$text =~ s{REPO}{$repo_root}g;
open my $out, '>', $c or die $!;
print $out $text;
close $out;

my @cmd = (
   'gcc',
   '-Wall',
   '-Wextra',
   '-Werror',
   '-pedantic',
   '-I',
   File::Spec->catdir($repo_root, 'compiler'),
   $c,
   '-o',
   $exe
);
system(@cmd) == 0 or die "compile failed: @cmd\n";
exec $exe or die "exec $exe: $!";
