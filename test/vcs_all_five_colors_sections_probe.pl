#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 180
# expectstdout: vcs_all_five_colors_sections_probe ok
# expectexit: 0

# Feasibility gate, NOT a public renderer or a general section implementation.
# Dense/packed/later seams, score composition, and bounded geometry experiments.
# Keep the established public renderer, heights, pointers and RAM unchanged.
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use IPC::Open3;
use Symbol qw(gensym);
my($repo,$tmp,$profile,$edges,$proof_seam,$geometry)=@ARGV;
$edges //= 0;
$profile //= 'dense';
my$bad_refill=$profile eq 'late_bad_refill';
my$bad_colour=$profile eq 'packed_bad_colour';
my$bad_glyph=$profile eq 'packed_bad_glyph';
my$bad_dense_refill=$profile eq 'late_dense_bad_refill';
my$bad_fine_pose=$profile eq 'fine_rts_dense_later_bad_pose';
my$fine_dense_later=$profile=~/^fine_rts_dense_later(?:_uniform|_controls|_bad_feed|_bad_pose)?$/;
my$fine_dense=$fine_dense_later||$profile=~/^fine_rts_dense(?:_uniform|_controls|_bad_feed)?$/;
my$fine_boundary=$profile=~/^fine_rts_boundary(?:_uniform|_controls|_bad_feed)?$/;
my$fine_mixed=$fine_boundary||$profile=~/^fine_rts_mixed(?:_uniform|_controls|_bad_feed)?$/;
my$fine_late=$fine_dense||$fine_mixed||$profile=~/^fine_rts_late(?:_uniform|_controls|_bad_feed)?$/;
my$fine_rts=$fine_late||$profile=~/^fine_rts(?:_uniform|_controls|_bad_feed)?$/;
my$fine_controls=$profile eq 'fine_spread_controls'||$profile eq 'fine_rts_controls'||$profile eq 'fine_rts_late_controls'||$profile eq 'fine_rts_mixed_controls'||$profile eq 'fine_rts_dense_controls'||$profile eq 'fine_rts_boundary_controls'||$profile eq 'fine_rts_dense_later_controls';
my$fine_eight=$profile eq 'fine_spread_eight'||($fine_rts&&$profile!~/_uniform$/&&!$fine_controls);
my$bad_fine_p1=$profile eq 'fine_spread_bad_p1';
my$fine_spread=$profile eq 'fine_spread'||$profile eq 'fine_spread_uniform'||$profile eq 'fine_spread_bad_feed'||$fine_controls||$bad_fine_p1||$fine_eight||$fine_rts;
my$bad_fine_feed=$profile eq 'fine_spread_bad_feed'||$profile eq 'fine_rts_bad_feed'||$profile eq 'fine_rts_late_bad_feed'||$profile eq 'fine_rts_mixed_bad_feed'||$profile eq 'fine_rts_dense_bad_feed'||$profile eq 'fine_rts_boundary_bad_feed'||$profile eq 'fine_rts_dense_later_bad_feed';
my$uniform=$profile eq 'late_dense_uniform'||$profile eq 'preview_uniform'||$profile eq 'fine_spread_uniform'||$profile eq 'fine_rts_uniform'||$profile eq 'fine_rts_late_uniform'||$profile eq 'fine_rts_mixed_uniform'||$profile eq 'fine_rts_dense_uniform'||$profile eq 'fine_rts_boundary_uniform'||$profile eq 'fine_rts_dense_later_uniform';
my$preview=$profile eq 'preview'||$profile eq 'preview_uniform'||$fine_spread;
$proof_seam //= 16;
my@preview_heights=split /,/,($geometry//($fine_dense_later?'34,2,2,2,2,2,2,146':$fine_boundary?'16,2,2,2,2,6,16,146':$fine_dense?'2,2,2,2,2,2,2,178':$fine_mixed?'4,22,2,2,16,32,48,66':$fine_late?'2,4,4,2,2,8,8,162':$fine_rts?'2,2,2,2,6,16,32,130':$fine_spread?'2,4,8,16,32,48,64,18':'16,16,16,16,32,32,32,32'));
@preview_heights==8 && !grep{!/^\d+$/||$_%($fine_spread?2:16)}@preview_heights or die 'invalid preview test geometry';
my(@preview_seams,%seen);my$end=0;
for(@preview_heights){$end+=$_;push@preview_seams,$end if$end>0&&$end<192&&!$seen{$end}++;}
$end==192&&$preview_heights[0]>0 or die 'invalid preview test extent';
(!$preview||!$edges||grep{$_==$proof_seam}@preview_seams) or die 'unsupported preview proof seam';
sub preview_palette {
   my$line=shift;my$end=0;
    for my$n(0..7){$end+=$preview_heights[$n];return$n%($fine_eight?8:4) if$line<$end;}
   die 'preview line outside display';
}
my$routed=$profile eq 'routed_dense'||$profile eq 'routed_dense_bad_reset'||$preview;
my$bad_route=$profile eq 'routed_dense_bad_reset';
my$example_score=$profile=~/^example_score_(above|below)$/?$1:'';
$profile="score_${example_score}_packed" if$example_score;
my$bad_score_m0=$profile eq 'score_above_bad_m0';
my$bad_score_late_m1=$profile eq 'score_above_packed_late_bad_m1';
my$bad_score_tail_call=$profile eq 'score_below_packed_late_bad_call';
my$score_dynamic=$profile eq 'score_above_packed_late_dynamic'||$profile eq 'score_below_packed_late_dynamic';
$profile='score_above_packed_late' if$profile eq 'score_above_packed_late_dynamic';
$profile='score_below_packed_late' if$profile eq 'score_below_packed_late_dynamic';
$profile='score_above_packed_late' if$bad_score_late_m1;
$profile='score_below_packed_late' if$bad_score_tail_call;
my$score_late=$profile eq 'score_above_packed_late'||$profile eq 'score_below_packed_late';
$profile='score_above_packed' if$profile eq 'score_above_packed_late';
$profile='score_below_packed' if$profile eq 'score_below_packed_late';
my$score_packed=$profile eq 'score_above_packed'||$profile eq 'score_below_packed';
$profile='score_above' if$profile eq 'score_above_packed';
$profile='score_below' if$profile eq 'score_below_packed';
$profile='score_above' if$bad_score_m0;
my$score_routed=$profile eq 'score_above_routed'||$profile eq 'score_below_routed';
my$score_order=$profile eq 'score_above'||$profile eq 'score_above_routed'?'above':$profile eq 'score_below'||$profile eq 'score_below_routed'?'below':'';
$profile='late' if$bad_refill;
$profile='packed' if$bad_colour;
$profile='packed' if$bad_glyph;
$profile='late_dense' if$bad_dense_refill;
$profile='late_dense' if$uniform;
$profile='late_dense' if$routed;
$profile='late' if$score_order;
($profile eq 'dense'||$profile eq 'packed'||$profile eq 'handoff'||$profile eq 'late'||$profile eq 'late_dense') or die 'unknown probe profile';
my$later=$profile eq 'late'||$profile eq 'late_dense';
$repo=abs_path($repo);$tmp=abs_path($tmp);
sub slurp { open(my$f,'<',$_[0]) or die$!;local$/;return <$f>; }
sub save { open(my$f,'>',$_[0]) or die$!;print{$f}$_[1];close$f or die$!; }
sub run {
   my$err=gensym;my$p=open3(my$i,my$o,$err,@_);close$i;
   local$/;my$out=<$o>//'';my$e=<$err>//'';waitpid($p,0);
   $?==0 or die "@_ failed\n$out$e";
}
sub bank_preparation {
   my$c=shift;
   my($prepare,$prime)=$c =~ /require inline void TEMPLATE_vblank\(void\) \{(.*?)   \/\/ Stage row-zero BL\/M1(.*?)\n\}\n\nrequire inline void TEMPLATE_draw/s;
   defined$prime or die 'banked preparation split';
   $prepare =~ s/\bTEMPLATE_playfield\b/TEMPLATE_prepare_playfield/g;
   my$mirror="bank1 page const uint8_t TEMPLATE_prepare_playfield[48] := {\n".join(',',map{"TEMPLATE_playfield[$_]"}0..47)."\n};\n";
   my$wrapper=$mirror."bank1 void TEMPLATE_prepare(void) {".$prepare."}\nrequire inline void TEMPLATE_vblank(void) {\n   TEMPLATE_prepare();\n   // Stage row-zero BL/M1".$prime."\n}\n\nrequire inline void TEMPLATE_draw";
   $c =~ s/require inline void TEMPLATE_vblank\(void\) \{.*?\n\}\n\nrequire inline void TEMPLATE_draw/$wrapper/s or die 'banked preparation wrapper';
   $c =~ s/page const uint8_t TEMPLATE_reposition_table/bank1 page const uint8_t TEMPLATE_reposition_table/ or die 'banked reposition table';
   return$c;
}

my$component=slurp("$repo/libraries/vcs/renderers/all_five_player_color_192/all_five_player_color_192.c26");
my$prime=join('',map{"   asm lda.a TEMPLATE_playfield + ".(4+$_).";\n   asm sta.z TEMPLATE_row_cache + ".(7+$_).";\n"}0..3);
$prime.=join('',map{"   asm lda.z TEMPLATE_object_masks + ".(4+$_).";\n   asm sta.z TEMPLATE_row_cache + ".(11+$_).";\n"}0..2);
$component =~ s/(   asm lda.z TEMPLATE_player0_y;)/$prime$1/ or die 'prime boundary';
my($body)=$component =~ /(   asm \@TEMPLATE_A_u1:;.*?)   \/\/ B pair 1: fixed 152-cycle cached pair\./s;
defined$body or die 'initial row boundary';
my@pal=([0x2e,0x84],[0x46,0xc2],[0x8e,0x26],[0xae,0x64]);
push@pal,([0x16,0xb4],[0x66,0x34],[0xd6,0x04],[0xf6,0x74]) if$fine_eight;
for my$n(1..6) {
   my$next=$n+1;
   my$end=$n<6 ? "   asm \@TEMPLATE_A_u$next:;" : '   // A pair 7 consumes';
   my($pair)=$body =~ /(   asm \@TEMPLATE_A_u$n:;.*?)\Q$end\E/s;
   defined$pair or die "pair $n boundary";
   my$old=$pair;my($pf,$bk)=@{$pal[$n%4]};
   $pair =~ s/   asm cpy.z TEMPLATE_player1_height;\n   asm lda\.(?:ax TEMPLATE_playfield|zx TEMPLATE_object_masks) \+ \d,x;\n   asm sta.z TEMPLATE_row_cache \+ \d+;/   asm lsr.z TEMPLATE_row_cache + 6;\n   asm ldx #$pf;\n   asm cpy.z TEMPLATE_player1_height;/
      or die "pair $n refill";
   # M0 was already committed: its shift can move earlier without advancing
   # M1's still-uncommitted bit. CPY must FOLLOW that shift to restore carry.
   $pair =~ s/(   asm sta ENAM1;)/$1\n   asm stx COLUPF;\n   asm lda #$bk;\n   asm sta COLUBK;/
      or die "pair $n palette";
   $pair =~ s/(   asm sta ENAM1;.*?)   asm lsr.z TEMPLATE_row_cache \+ 6;\n/$1/s
      or die "pair $n late M0 shift";
   $pair =~ s/   asm cpy.z TEMPLATE_player0_height;\n// or die "pair $n P0 compare";
   $pair =~ s/   asm lda.a TEMPLATE_row_cache \+ 3;\n   asm sta PF1;\n   asm bcs.same/   asm lda.z TEMPLATE_row_cache + 3;\n   asm sta PF1;\n   asm cpy.z TEMPLATE_player0_height;\n   asm bcs.same/
      or die "pair $n P0 phase";
   $pair =~ s/(   asm lsr.z TEMPLATE_row_cache \+ 4;)\n   asm nop;/$1/
      or die "pair $n tail";
   $body =~ s/\Q$old\E/$pair/ or die "pair $n replacement";
}
if($profile eq 'packed') {
   # Packed pair seven has no ordinary refill slot. Carry its last M1 bit in
   # X, duplicate the P1-active/zero tails to avoid the three-cycle join, and
   # move the raw P0-counter store into an equal-cost boundary pad. Both P1
   # colour stores retain their original phase; only GRP1 moves within HBLANK.
   my($before,$active,$zero,$tail,$boundary)=$body =~ /\A(.*?   asm \@TEMPLATE_A_u7:;.*?   asm bcs.same \@TEMPLATE_A_u7_p1_zero;\n)(.*?)   asm jmp \@TEMPLATE_A_u7_p1_ready;\n   asm \@TEMPLATE_A_u7_p1_zero:;\n(.*?)   asm bit.z \$00;\n   asm \@TEMPLATE_A_u7_p1_ready:;\n(.*?)(   asm \@TEMPLATE_A_boundary:;.*)\z/s;
   defined$boundary or die 'packed row split';
   $before =~ s/   asm lda.zx TEMPLATE_object_masks \+ 3,x;/   asm lda.z TEMPLATE_object_masks + 3;/ or die 'packed source';
   $before =~ s/(   asm lsr;\n)(   asm lsr;\n   asm sta.z TEMPLATE_row_cache \+ 6;)/$1   asm tax;\n$2/ or die 'packed M1 register';
   $before =~ s/   asm ldy.zx TEMPLATE_object_masks \+ 6,x;\n// or die 'packed redundant preload';
   $before =~ s/   asm sty.z TEMPLATE_row_cache \+ 13;/   asm bit.z \$00;\n   asm bit.z \$00;/ or die 'packed colour phase';
   $tail =~ s/   asm lda.zx TEMPLATE_object_masks \+ 3,x;\n   asm lsr;\n   asm sta ENAM1;/   asm stx ENAM1;\n   asm lda #174;\n   asm sta COLUPF;\n   asm lda #100;\n   asm sta COLUBK;/ or die 'packed palette';
   $tail =~ s/   asm lda.z TEMPLATE_row_cache \+ 0;\n   asm sta PF1;/   PF1 := TEMPLATE_first_pf1;/ or die 'packed immutable PF byte';
   $tail =~ s/   asm sty.z TEMPLATE_object_masks \+ 0;\n// or die 'packed deferred P0 counter';
   $tail =~ s/(   asm lda #0;\n)   asm tay;/$1   asm nop;/ or die 'packed raw P0 Y';
   # Replace an existing three-cycle boundary pad, not an extra instruction.
   $boundary =~ s/   asm nop;\n   asm bit.z \$00;/   asm nop;\n   asm sty.z TEMPLATE_object_masks + 0;/ or die 'packed counter boundary pad';
   my$zero_tail=$tail;
   $zero_tail =~ s/\@TEMPLATE_A_u7_/\@TEMPLATE_A_u7_zero_/g;
   $body=$before.$active.$tail."   asm jmp \@TEMPLATE_A_boundary;\n   asm \@TEMPLATE_A_u7_p1_zero:;\n".$zero.$zero_tail."   asm jmp \@TEMPLATE_A_boundary;\n".$boundary;
   $component =~ s/(extern const uint8_t TEMPLATE_playfield\[48\];)/$1\nconst uint8_t TEMPLATE_first_pf1 := TEMPLATE_playfield[0];/ or die 'packed constant byte';
}
if($profile eq 'handoff') {
   my($before,$active,$zero,$tail)=$body =~ /\A(.*?   asm \@TEMPLATE_A_boundary:;.*?   asm bcs.same \@TEMPLATE_A_boundary_p1_zero;\n)(.*?)   asm jmp \@TEMPLATE_A_boundary_p1_ready;\n   asm \@TEMPLATE_A_boundary_p1_zero:;\n(.*?)   asm bit.z \$00;\n   asm \@TEMPLATE_A_boundary_p1_ready:;\n(.*)\z/s;
   defined$tail or die 'handoff row split';
   # Decrement P0 in the old five-cycle pad, retaining the exact P1-colour
   # phase. Duplicated tails stage M1 in Y without delaying GRP1.
   $before =~ s/(   asm \@TEMPLATE_A_boundary:;.*?)   asm nop;\n   asm bit.z \$00;/$1   asm dec.z TEMPLATE_object_masks + 0;/s or die 'handoff early P0';
   $tail =~ s/   asm lda.z TEMPLATE_row_cache \+ 12;\n   asm sta ENAM1;/   asm sty ENAM1;\n   asm lda #174;\n   asm sta COLUPF;\n   asm lda #100;\n   asm sta COLUBK;/ or die 'handoff palette';
   $tail =~ s/(   asm ldy.z TEMPLATE_object_masks \+ 0;)\n   asm dey;\n   asm sty.z TEMPLATE_object_masks \+ 0;/$1/ or die 'handoff P0 counter';
   $tail =~ s/   asm inx;\n   asm inx;\n   asm inx;/   asm nop;\n   asm nop;/ or die 'handoff reclaimed pad';
   my$zero_tail=$tail;$zero_tail =~ s/\@TEMPLATE_A_firstB_/\@TEMPLATE_A_firstB_zero_/g;
   my$stage="   asm ldy.z TEMPLATE_row_cache + 12;\n";
   $body=$before.$active.$stage.$tail."   asm \@TEMPLATE_A_boundary_p1_zero:;\n".$zero.$stage.$zero_tail;
}
if($later) {
   # The late-layout proof needs no early seams. Share its six identical
   # no-refill pairs, keeping room for the second-row specialization in bank0.
   my($pair)=$component =~ /(   asm \@TEMPLATE_A_u1:;.*?)   \/\/ A pair 2:/s;
   defined$pair or die 'late initial loop';
   $pair =~ s/   asm cpy.z TEMPLATE_player1_height;\n   asm lda.ax TEMPLATE_playfield \+ 4,x;\n   asm sta.z TEMPLATE_row_cache \+ 7;/   asm lsr.z TEMPLATE_row_cache + 6;\n   asm nop;\n   asm cpy.z TEMPLATE_player1_height;/ or die 'late loop refill';
   $pair =~ s/(   asm sta ENAM1;.*?)   asm lsr.z TEMPLATE_row_cache \+ 6;\n/$1/s or die 'late loop M0 shift';
   $pair =~ s/(   asm lsr.z TEMPLATE_row_cache \+ 4;)\n   asm nop;/$1\n   asm dex;\n   asm beq.same \@TEMPLATE_A_initial_loop_done;\n   asm jmp \@TEMPLATE_A_u1;\n   asm \@TEMPLATE_A_initial_loop_done:;\n   asm ldx #0;/ or die 'late loop tail';
   $body =~ s/\A.*?(?=   asm \@TEMPLATE_A_u7:;)/$pair/s or die 'late loop replacement';
   $component =~ s/(   asm \@TEMPLATE_first_p0_ready:;\n   asm sta GRP0;)\n   asm nop;\n   asm nop;/$1\n   asm ldx #6;\n   asm nop;/ or die 'late loop entry';
}
# This one-off row knows its source offset. Force absolute mode to retain
# the four-cycle cost while X carries section colours instead of the row base.
$body =~ s/(asm (?:lda|ldy))\.zx (TEMPLATE_object_masks \+ (?:3|6)),x;/$1.a $2;/g;
if($profile ne 'handoff') {
   $body =~ s/   asm inx;\n   asm inx;\n   asm inx;/   asm nop;\n   asm nop;\n   asm nop;/g or die 'row offset increment';
}
$body =~ s/   asm inx;\n   asm nop;\n   asm bit.z \$00;\n/   asm ldx #4;\n   asm nop;\n   asm jmp \@TEMPLATE_B_u1;\n/g
   or die 'initial row successor';
$body =~ s/\@TEMPLATE_A_/\@TEMPLATE_initial_A_/g;
$component =~ s/   asm jmp \@TEMPLATE_A_u1;/   asm jmp \@TEMPLATE_initial_A_u1;/
   or die 'initial entry';
$component =~ s/   asm \.align 256, \$90;//;
$component =~ s/(   asm sta WSYNC;\n)(\}\n\nrequire inline void TEMPLATE_overscan)/$1   asm jmp \@TEMPLATE_initial_done;\n$body   asm \@TEMPLATE_initial_done:;\n$2/
   or die 'private schedule insertion';
if($later) {
   # Keep the complete row-one refill schedule, then change colours at its
   # handoff to row two. This exercises a cache filled during visible output.
   my($b)=$component =~ /(   asm \@TEMPLATE_B_u1:;.*?)   \/\/ Row 11 is terminal\./s;
   defined$b or die 'later row boundary';
   $b =~ s/   asm cpx #44;\n   asm beq.same \@TEMPLATE_terminal_boundary;/   asm dec.z TEMPLATE_object_masks + 0;/ or die 'later nonterminal counter';
   $b =~ s/(   asm \@TEMPLATE_B_boundary:;.*?)   asm lsr.a TEMPLATE_row_cache \+ 4;/$1   asm lsr.z TEMPLATE_row_cache + 4;/s or die 'later counter pad';
   my($before,$active,$zero,$tail)=$b =~ /\A(.*?   asm \@TEMPLATE_B_boundary:;.*?   asm bcs.same \@TEMPLATE_B_boundary_p1_zero;\n)(.*?)   asm jmp \@TEMPLATE_B_boundary_p1_ready;\n   asm \@TEMPLATE_B_boundary_p1_zero:;\n(.*?)   asm bit.z \$00;\n   asm \@TEMPLATE_B_boundary_p1_ready:;\n(.*)\z/s;
   defined$tail or die 'later handoff split';
   $tail =~ s/   asm lda.z TEMPLATE_row_cache \+ 5;\n   asm sta ENAM1;/   asm sty ENAM1;\n   asm lda #174;\n   asm sta COLUPF;\n   asm lda #100;\n   asm sta COLUBK;/ or die 'later palette';
   $tail =~ s/(   asm ldy.z TEMPLATE_object_masks \+ 0;)\n   asm dey;\n   asm sty.z TEMPLATE_object_masks \+ 0;/$1/ or die 'later P0 counter';
   $tail =~ s/   asm inx;\n   asm inx;\n   asm inx;/   asm nop;\n   asm nop;/ or die 'later reclaimed pad';
   $tail =~ s/   asm inx;\n   asm nop;\n   asm jmp \@TEMPLATE_A_u1;/   asm ldx #8;\n   asm nop;\n   asm jmp \@TEMPLATE_A_u1;/ or die 'later successor';
   my$zero_tail=$tail;$zero_tail =~ s/\@TEMPLATE_B_firstA_/\@TEMPLATE_B_firstA_zero_/g;
   my$stage="   asm ldy.z TEMPLATE_row_cache + 5;\n";
   $b=$before.$active.$stage.$tail."   asm \@TEMPLATE_B_boundary_p1_zero:;\n".$zero.$stage.$zero_tail;
   if($profile eq 'late_dense') {
      # Full refills remain in place: immediate immutable PF loads save enough
      # cycles for two palette stores. Preserve both right-PF2 write phases at
      # 49/125. M0 shifts after its commit, P1's counter store waits until after
      # its graphics fetch, and M1 shifts after the next left-side PF rewrites.
      # The absolute CPY is an explicit one-cycle phase constraint, not padding
      # that the assembler may silently compact back to zero page.
      my$constants=join('',map{"const uint8_t TEMPLATE_second_pf$_ := TEMPLATE_playfield[".(4+$_)."];\n"}0..3);
      $component =~ s/(extern const uint8_t TEMPLATE_playfield\[48\];)/$1\n$constants/ or die 'second-row constants';
      for my$n(1..6) {
         my$next=$n+1;
         my$end=$n<6 ? "   asm \@TEMPLATE_B_u$next:;" : '   // B pair 7 consumes';
         my($pair)=$b =~ /(   asm \@TEMPLATE_B_u$n:;.*?)\Q$end\E/s;
         defined$pair or die "baked pair $n";my$old=$pair;
         $pair =~ s/   asm lda\.(?:z|a) TEMPLATE_row_cache \+ (7|8|9|10);\n   asm sta (PF[12]);/'   '.$2.' := TEMPLATE_second_pf'.($1-7).';'/ge;
         $pair =~ s/   asm sty.z TEMPLATE_object_masks \+ 1;\n// or die 'defer P1 store';
         $pair =~ s/(   asm cpy.z TEMPLATE_player1_height;)/   asm lsr.z TEMPLATE_row_cache + 13;\n$1/ or die 'early M0 shift';
         $pair =~ s/   PF2 := TEMPLATE_second_pf2;/   asm lda.z TEMPLATE_row_cache + 9;\n   asm sta PF2;/ or die 'first rewrite phase';
         $pair =~ s/(   asm sta ENAM1;.*?)   asm lsr.z TEMPLATE_row_cache \+ 13;\n/$1/s or die 'old M0 shift';
         $pair =~ s/(   asm sta ENAM1;.*?)   asm lsr.z TEMPLATE_row_cache \+ 12;\n/$1/s or die 'old M1 shift';
         my($pf,$bk)=@{$pal[$n%4]};
         $pair =~ s/(   asm sta ENAM1;)/$1\n   asm lda #$pf;\n   asm sta COLUPF;\n   asm lda #$bk;\n   asm sta COLUBK;/ or die 'baked palette';
         $pair =~ s/(   asm sta COLUBK;.*?   PF2 := TEMPLATE_second_pf1;)/$1\n   asm lsr.z TEMPLATE_row_cache + 12;\n   asm sty.z TEMPLATE_object_masks + 1;/s or die 'deferred stores';
         $pair =~ s/   asm cpy.z TEMPLATE_player0_height;\n   PF2 := TEMPLATE_second_pf2;/   PF2 := TEMPLATE_second_pf2;\n   asm cpy.a TEMPLATE_player0_height;/ or die 'second rewrite phase';
         $pair =~ s/(   asm lsr.z TEMPLATE_row_cache \+ 11;)\n   asm nop;/$1/ or die 'baked tail pad';
         # Labels are zero-cycle control-flow barriers for the compiler's
         # redundant-load peephole. Equal neighbouring PF bytes must still
         # issue both two-cycle LDA immediates in this timed schedule.
         my$barrier=0;
         $pair =~ s/(   PF[12] := TEMPLATE_second_pf\d;)/'   asm @TEMPLATE_pf_barrier_'.$n.'_'.($barrier++).":;\n".$1/ge;
         $b =~ s/\Q$old\E/$pair/ or die 'baked replacement';
      }
   }
   $b =~ s/\@TEMPLATE_B_/\@TEMPLATE_initial_B_/g;
   # Redirect only the one-off A-row successor, not later generic A rows.
   $component =~ s/(   asm \@TEMPLATE_initial_A_u1:;.*?)   asm jmp \@TEMPLATE_B_u1;/$1   asm jmp \@TEMPLATE_initial_B_u1;/s or die 'later entry';
   $component =~ s/(   asm \@TEMPLATE_initial_done:;)/$b$1/ or die 'later insertion';

   # More specialized ROM code, not more RAM: put preparation in the other
   # F8 bank, while graphics/colour priming and the entire raster stay in bank0.
   $component=bank_preparation($component);
}
if($bad_refill) {
   $component =~ s/(   asm \@TEMPLATE_initial_B_u1:;.*?)   asm lda.ax TEMPLATE_playfield \+ 4,x;/$1   asm lda.ax TEMPLATE_playfield + 5,x;/s or die 'negative refill target';
}
if($bad_dense_refill) {
   $component =~ s/(   asm \@TEMPLATE_initial_B_u1:;.*?)   asm lda.ax TEMPLATE_playfield \+ 4,x;/$1   asm lda.ax TEMPLATE_playfield + 5,x;/s or die 'negative dense refill target';
}
if($bad_colour) {
   $component =~ s/const uint8_t TEMPLATE_first_pf1 := TEMPLATE_playfield\[0\];/const uint8_t TEMPLATE_first_pf1 := TEMPLATE_playfield[0] ^ 0x80;/ or die 'negative packed byte target';
}
if($routed) {
   # Thread the A-row exit through a two-byte pointer. Duplicating the P0
   # tails removes their three-cycle join; the original five-cycle exit pad
   # becomes JMP(indirect), and a three-cycle entry stub balances the join.
   # No runtime object API is removed, and all executable drawing stays bank0.
   $component="uint8_t TEMPLATE_route[2];\n".$component;
   # The unreachable .same branch constrains both three-byte stubs to one
   # page. Updating just the low byte is therefore a placement contract, not
   # an assumed numeric ROM address. These remain hygienic local asm labels.
   my$stubs="   asm \@TEMPLATE_route_normal:;\n   asm jmp \@TEMPLATE_B_u1;\n   asm \@TEMPLATE_route_special:;\n   asm jmp \@TEMPLATE_initial_B_u1;\n   asm bne.same \@TEMPLATE_route_normal;\n";
   $component =~ s/(   asm \@TEMPLATE_initial_A_u1:;)/$stubs$1/ or die 'route stubs';
   # Ten entry cycles replace an eight-cycle pad; remove the later two-cycle
   # pad before the first right PF rewrite to restore its exact phase.
   $component =~ s/(require inline void TEMPLATE_draw\(void\) \{.*?)(   asm bit.z \$00;\n   asm bit.z \$00;\n   asm nop;)/$1   asm lda #<\@TEMPLATE_route_special;\n   asm sta.z TEMPLATE_route;\n   asm lda #>\@TEMPLATE_route_special;\n   asm sta.z TEMPLATE_route + 1;/s or die 'route preparation';
   $component =~ s/(require inline void TEMPLATE_draw\(void\) \{.*?   asm cpy.z TEMPLATE_player0_height;\n   asm bit.z \$00;)\n   asm nop;/$1/s or die 'route entry phase';
   $component =~ s/   asm jmp \@TEMPLATE_initial_A_u1;/   asm jmp \@TEMPLATE_A_u1;/ or die 'ordinary initial A';
   $component =~ s/(   asm \@TEMPLATE_first_p0_ready:;\n   asm sta GRP0;)\n   asm ldx #6;/$1\n   asm ldx #0;/ or die 'ordinary initial X';
   my($prefix,$active,$zero,$tail)=$component =~ /(   asm \@TEMPLATE_A_boundary:;.*?   asm bcs.same \@TEMPLATE_A_firstB_p0_zero;\n)(.*?)   asm jmp \@TEMPLATE_A_firstB_p0_ready;\n   asm \@TEMPLATE_A_firstB_p0_zero:;\n(.*?)   asm bit.z \$00;\n   asm \@TEMPLATE_A_firstB_p0_ready:;\n(.*?)(?=   \/\/ B pair 1:)/s;
   defined$tail or die 'routed boundary split';
   my$old=$prefix.$active."   asm jmp \@TEMPLATE_A_firstB_p0_ready;\n   asm \@TEMPLATE_A_firstB_p0_zero:;\n".$zero."   asm bit.z \$00;\n   asm \@TEMPLATE_A_firstB_p0_ready:;\n".$tail;
   $tail =~ s/   asm nop;\n   asm bit.z \$00;/   asm jmp (TEMPLATE_route);/ or die 'routed tail';
   my$new=$prefix.$active.$tail."   asm \@TEMPLATE_A_firstB_p0_zero:;\n".$zero.$tail;
   $component =~ s/\Q$old\E/$new/ or die 'routed boundary replacement';
   my($boundary)=$component =~ /(   asm \@TEMPLATE_initial_B_boundary:;.*?)(?=   asm \@TEMPLATE_initial_done:;)/s;
   defined$boundary or die 'special boundary';my$prior=$boundary;
   my$target=$bad_route?'special':'normal';
   my$count=($boundary =~ s/   asm lda #174;\n   asm sta COLUPF;\n   asm lda #100;\n   asm sta COLUBK;/   asm lda #<\@TEMPLATE_route_$target;\n   asm sta.z TEMPLATE_route;\n   asm nop;\n   asm bit.z \$00;/g);
   $count==2 or die "special route update count $count";
   $component =~ s/\Q$prior\E/$boundary/ or die 'special boundary route';
   # Unlike the original late-row proof, this routes the ordinary initial A
   # row. Retaining its unreachable alternate copy wastes scarce draw-bank ROM.
   $component =~ s/   asm \@TEMPLATE_initial_A_u1:;.*?(?=   asm \@TEMPLATE_initial_B_u1:;)//s or die 'unused first-row proof';
}
if($score_order) {
   # Reuse the newly proven dense pair on the score-safe initial B row.
   # The established compact 181-line scheduler owns every subsequent row.
   my$old=slurp("$repo/libraries/vcs/renderers/all_five_player_color_192/all_five_player_color_192.c26");
   $component=slurp("$repo/libraries/vcs/renderers/all_five_player_color_181/all_five_player_color_181.c26");
   my($body)=$old =~ /(   asm \@TEMPLATE_B_u1:;.*?)   \/\/ B pair 7 consumes/s;
   defined$body or die 'score body';
   for my$n(1..6) {
      my$next=$n+1;my$end=$n<6?"   asm \@TEMPLATE_B_u$next:;":'END';
      my$part=$body.($n==6?'END':'');
      my($pair)=$part =~ /(   asm \@TEMPLATE_B_u$n:;.*?)\Q$end\E/s;
      defined$pair or die 'score pair';my$prior=$pair;
      $pair =~ s/   asm lda\.(?:z|a) TEMPLATE_row_cache \+ (7|8|9|10);\n   asm sta (PF[12]);/'   '.$2.' := TEMPLATE_score_pf'.($1-7).';'/ge;
      $pair =~ s/   asm sty.z TEMPLATE_object_masks \+ 1;\n// or die 'score P1 store';
      $pair =~ s/(   asm cpy.z TEMPLATE_player1_height;)/   asm lsr.z TEMPLATE_row_cache + 13;\n$1/ or die 'score M0';
      $pair =~ s/   PF2 := TEMPLATE_score_pf2;/   asm lda.z TEMPLATE_row_cache + 9;\n   asm sta PF2;/ or die 'score right PF2';
      $pair =~ s/(   asm sta ENAM1;.*?)   asm lsr.z TEMPLATE_row_cache \+ 13;\n/$1/s or die 'score late M0';
      $pair =~ s/(   asm sta ENAM1;.*?)   asm lsr.z TEMPLATE_row_cache \+ 12;\n/$1/s or die 'score late M1';
      my($pf,$bk)=@{$pal[$n%4]};
      $pair =~ s/(   asm sta ENAM1;)/$1\n   asm lda #$pf;\n   asm sta COLUPF;\n   asm lda #$bk;\n   asm sta COLUBK;/ or die 'score palette';
      $pair =~ s/(   asm sta COLUBK;.*?   PF2 := TEMPLATE_score_pf1;)/$1\n   asm lsr.z TEMPLATE_row_cache + 12;\n   asm sty.z TEMPLATE_object_masks + 1;/s or die 'score deferred';
      $pair =~ s/   asm cpy.z TEMPLATE_player0_height;\n   PF2 := TEMPLATE_score_pf2;/   PF2 := TEMPLATE_score_pf2;\n   asm cpy.a TEMPLATE_player0_height;/ or die 'score compare';
      $pair =~ s/(   asm lsr.z TEMPLATE_row_cache \+ 11;)\n   asm nop;/$1/ or die 'score pad';
      # The score profile primes M0 differently: its last normal shift is dead
      # and must not advance the cached bit used at packed-pair entry.
      if($n==6&&!$bad_score_m0){$pair =~ s/   asm lsr.z TEMPLATE_row_cache \+ 13;/   asm nop;\n   asm bit.z \$00;/ or die 'score last M0';}
      my$barrier=0;
      $pair =~ s/(   PF[12] := TEMPLATE_score_pf\d;)/'   asm @TEMPLATE_score_pf_barrier_'.$n.'_'.($barrier++).":;\n".$1/ge;
      $body =~ s/\Q$prior\E/$pair/ or die 'score replace';
   }
   $body =~ s/   asm lsr.z TEMPLATE_row_cache \+ 11;\n\z/   asm nop;\n   asm jmp \@TEMPLATE_B_c_u7;\n/ or die 'score successor';
   my$defs=join('',map{"const uint8_t TEMPLATE_score_pf$_ := TEMPLATE_playfield[$_];\n"}0..3);
   $component =~ s/(extern const uint8_t TEMPLATE_playfield\[44\];)/$1\n$defs/ or die 'score PF constants';
   $component =~ s/   asm jmp \@TEMPLATE_B_c_u1;/   asm jmp \@TEMPLATE_B_u1;/ or die 'score entry';
   $component =~ s/(   asm \@TEMPLATE_A_c_u1:;)/$body$1/ or die 'score insertion';
   my($prepare)=$component =~ /require inline void TEMPLATE_vblank\(void\) \{(.*?)\n\}\n\nrequire inline void TEMPLATE_draw/s;
   defined$prepare or die 'score prepare split';
   $prepare =~ s/\bTEMPLATE_playfield\b/TEMPLATE_prepare_playfield/g;
   # Re-snapshot S after the banked preparation returns, not inside its call.
   my$wrapper="bank1 void TEMPLATE_prepare(void) {".$prepare."\n}\nrequire inline void TEMPLATE_vblank(void) {\n   TEMPLATE_prepare();\n   asm tsx;\n   asm stx.z TEMPLATE_row_cache + 20;\n}\n\nrequire inline void TEMPLATE_draw";
   $component =~ s/require inline void TEMPLATE_vblank\(void\) \{.*?\n\}\n\nrequire inline void TEMPLATE_draw/$wrapper/s or die 'score prepare replacement';
   $component =~ s/page const uint8_t TEMPLATE_reposition_table/bank1 page const uint8_t TEMPLATE_reposition_table/ or die 'score reposition';
   $component="bank1 page const uint8_t TEMPLATE_prepare_playfield[44] := {".join(',',map{"TEMPLATE_playfield[$_]"}0..43)."};\n".$component;
   if($score_routed) {
      # The RESP counts at cache +16/+17 are dead after visible positioning.
      # Reuse those two bytes, keeping both RAM usage and the saved S at +20.
      # No new private RAM is affordable in the full interactive composition.
      $component =~ s/(\/\/ Row zero enters in cache B.*?)(   asm bit.z \$00;\n   asm bit.z \$00;\n   asm nop;)/$1   asm lda #<\@TEMPLATE_A_c_u1;\n   asm sta.z TEMPLATE_row_cache + 16;\n   asm lda #>\@TEMPLATE_A_c_u1;\n   asm sta.z TEMPLATE_row_cache + 17;/s or die 'score route preparation';
      $component =~ s/(require inline void TEMPLATE_draw\(void\) \{.*?   asm cpy.z TEMPLATE_player0_height;\n   asm bit.z \$00;)\n   asm nop;/$1/s or die 'score route entry phase';
      my($prefix,$active,$zero,$tail)=$component =~ /(   asm \@TEMPLATE_B_c_boundary:;.*?   asm bcs.same \@TEMPLATE_B_c_boundary_p0_zero;\n)(.*?)   asm jmp \@TEMPLATE_B_c_boundary_p0_ready;\n   asm \@TEMPLATE_B_c_boundary_p0_zero:;\n(.*?)   asm bit.z \$00;\n   asm \@TEMPLATE_B_c_boundary_p0_ready:;\n(.*?)(?=   \/\/ Row 10 is terminal)/s;
      defined$tail or die 'score routed boundary split';
      my$old=$prefix.$active."   asm jmp \@TEMPLATE_B_c_boundary_p0_ready;\n   asm \@TEMPLATE_B_c_boundary_p0_zero:;\n".$zero."   asm bit.z \$00;\n   asm \@TEMPLATE_B_c_boundary_p0_ready:;\n".$tail;
      $tail =~ s/   asm sta GRP0;/   asm sta.a GRP0;/ or die 'score route phase pad';
      $tail =~ s/   asm jmp \@TEMPLATE_A_c_u1;/   asm jmp (TEMPLATE_row_cache + 16);/ or die 'score route exit';
      my$new=$prefix.$active.$tail."   asm \@TEMPLATE_B_c_boundary_p0_zero:;\n".$zero.$tail;
      $component =~ s/\Q$old\E/$new/ or die 'score routed boundary replacement';
   }
}
if($score_packed) {
   # Only the initial packed B pair and its exit are specialized. Subsequent
   # compact rows retain their stack/cache choreography and use the same bank.
   my($packed)=$component =~ /(   asm \@TEMPLATE_B_c_u7:;.*?)(?=   \/\/ Row 10 is terminal)/s;
   defined$packed or die 'score packed body';
   my($before,$active,$zero,$tail,$boundary)=$packed =~ /\A(.*?   asm bcs.same \@TEMPLATE_B_c_u7_p1_zero;\n)(.*?)   asm jmp \@TEMPLATE_B_c_u7_p1_ready;\n   asm \@TEMPLATE_B_c_u7_p1_zero:;\n(.*?)   asm bit.z \$00;\n   asm \@TEMPLATE_B_c_u7_p1_ready:;\n(.*?)(   asm \@TEMPLATE_B_c_boundary:;.*)\z/s;
   defined$boundary or die 'score packed split';
   $before =~ s/   asm lda.zx TEMPLATE_object_masks \+ 3,x;/   asm lda.z TEMPLATE_object_masks + 3;/ or die 'score packed source';
   $before =~ s/(   asm lsr;\n)(   asm lsr;\n   asm sta.z TEMPLATE_row_cache \+ 13;)/$1   asm tax;\n$2/ or die 'score packed M1';
   $before =~ s/   asm ldy.zx TEMPLATE_object_masks \+ 6,x;\n// or die 'score packed preload';
   $before =~ s/   asm sty.z TEMPLATE_row_cache \+ 6;/   asm bit.z \$00;\n   asm bit.z \$00;/ or die 'score packed phase';
   $tail =~ s/   asm lda.zx TEMPLATE_object_masks \+ 3,x;\n   asm lsr;\n   asm sta ENAM1;/   asm stx ENAM1;\n   asm lda #174;\n   asm sta COLUPF;\n   asm lda #100;\n   asm sta COLUBK;/ or die 'score packed palette';
   $tail =~ s/   asm lda.z TEMPLATE_row_cache \+ 7;\n   asm sta PF1;/   PF1 := TEMPLATE_score_pf0;/ or die 'score packed PF';
   $tail =~ s/   asm sty.z TEMPLATE_object_masks \+ 0;\n// or die 'score packed P0';
   $tail =~ s/(   asm lda #0;\n)   asm tay;/$1   asm nop;/ or die 'score packed raw Y';
   $boundary =~ s/   asm cpx #40;\n   asm beq.cross \@TEMPLATE_terminal_boundary;\n   asm lsr.a TEMPLATE_row_cache \+ 4;/   asm ldx #0;\n   asm sty.z TEMPLATE_object_masks + 0;\n   asm lsr.z TEMPLATE_row_cache + 4;/ or die 'score packed exit budget';
   my$zt=$tail;$zt =~ s/\@TEMPLATE_B_c_u7_/\@TEMPLATE_B_c_u7_zero_/g;
   my$new=$before.$active.$tail."   asm jmp \@TEMPLATE_B_c_boundary;\n   asm \@TEMPLATE_B_c_u7_p1_zero:;\n".$zero.$zt."   asm jmp \@TEMPLATE_B_c_boundary;\n".$boundary;
   $new =~ s/\@TEMPLATE_B_c_/\@TEMPLATE_score_packed_/g;
   $component =~ s/   asm jmp \@TEMPLATE_B_c_u7;/   asm jmp \@TEMPLATE_score_packed_u7;/ or die 'score packed entry';
   if($score_late) {
      # Cache +12 is live row-zero M1 during setup and cannot be primed in
      # VBLANK. Packed M1 now lives in X, so these six dead padding cycles
      # can stage row-two M1 after the old cache's final use instead.
      $new =~ s/   asm bit.z \$00;\n   asm bit.z \$00;/   asm lda.z TEMPLATE_object_masks + 9;\n   asm sta.z TEMPLATE_row_cache + 12;/ or die 'score later M1 staging';
      $new =~ s/   asm lda.z TEMPLATE_object_masks \+ 9;/   asm lda.z TEMPLATE_object_masks + 8;/ or die 'score later M1 mutation' if$bad_score_late_m1;
      my($pair)=$component =~ /(   asm \@TEMPLATE_A_c_u1:;.*?)(?=   \/\/ A pairs 2\.\.3:)/s;
      defined$pair or die 'score later pair';
      $pair =~ s/   asm lda\.(?:z|a) TEMPLATE_row_cache \+ ([0-3]);\n   asm sta (PF[12]);/'   '.$2.' := TEMPLATE_late_pf'.$1.';'/ge;
      $pair =~ s/   asm sty.z TEMPLATE_object_masks \+ 1;\n// or die 'score later P1';
      $pair =~ s/(   asm cpy.z TEMPLATE_player1_height;)/   asm lsr.z TEMPLATE_row_cache + 6;\n$1/ or die 'score later M0';
      $pair =~ s/   asm lda.zx TEMPLATE_object_masks \+ 5,x;\n   asm sta.z TEMPLATE_row_cache \+ 12;/   asm dec.z TEMPLATE_object_masks + 0;\n   asm nop;/ or die 'score later early P0';
      $pair =~ s/   PF2 := TEMPLATE_late_pf2;/   asm lda.z TEMPLATE_row_cache + 2;\n   asm sta PF2;/ or die 'score later right phase';
      $pair =~ s/(   asm sta ENAM1;.*?)   asm lsr.z TEMPLATE_row_cache \+ 6;\n/$1/s or die 'score later old M0';
      $pair =~ s/(   asm sta ENAM1;.*?)   asm lsr.z TEMPLATE_row_cache \+ 5;\n/$1/s or die 'score later old M1';
      $pair =~ s/(   asm sta ENAM1;)/$1\n   asm lda #46;\n   asm sta COLUPF;\n   asm lda #132;\n   asm sta COLUBK;/ or die 'score later palette';
      $pair =~ s/(   asm sta COLUBK;.*?   PF2 := TEMPLATE_late_pf1;)/$1\n   asm lsr.z TEMPLATE_row_cache + 5;\n   asm sty.z TEMPLATE_object_masks + 1;/s or die 'score later deferred stores';
      $pair =~ s/(   asm ldy.z TEMPLATE_object_masks \+ 0;)\n   asm dey;\n   asm sty.z TEMPLATE_object_masks \+ 0;/$1/ or die 'score later old P0';
      $pair =~ s/   asm cpy.z TEMPLATE_player0_height;\n   PF2 := TEMPLATE_late_pf2;/   PF2 := TEMPLATE_late_pf2;\n   asm cpy.a TEMPLATE_player0_height;/ or die 'score later compare';
      # The early decrement frees five cycles only AFTER the right PF writes.
      # Move LDX there and spend three cycles before PF2; duplicated P0 tails
      # remove the three-cycle join and pay for the jump into the shared loop.
      $pair =~ s/   asm ldx #2;\n// or die 'score later loop count';
      $pair =~ s/(   asm ldy.z TEMPLATE_object_masks \+ 0;)/$1\n   asm ldx #2;\n   asm bit.z \$00;/ or die 'score later right padding';
      my$barrier=0;$pair =~ s/(   PF[12] := TEMPLATE_late_pf\d;)/'   asm @TEMPLATE_late_barrier_'.($barrier++).":;\n".$1/ge;
      $pair =~ s/\@TEMPLATE_A_c_u1/\@TEMPLATE_score_late_u1/g;
      my($p,$a,$z,$commit)=$pair =~ /\A(.*?   asm bcs.same \@TEMPLATE_score_late_u1_p0_zero;\n)(.*?)   asm jmp \@TEMPLATE_score_late_u1_p0_ready;\n   asm \@TEMPLATE_score_late_u1_p0_zero:;\n(.*?)   asm bit.z \$00;\n   asm \@TEMPLATE_score_late_u1_p0_ready:;\n(.*)\z/s;
      defined$commit or die 'score later P0 tails';
      $commit.="   asm jmp \@TEMPLATE_A_c_loop;\n";
      $pair=$p.$a.$commit."   asm \@TEMPLATE_score_late_u1_p0_zero:;\n".$z.$commit;
      $new =~ s/   asm jmp \@TEMPLATE_A_c_u1;/   asm jmp \@TEMPLATE_score_late_u1;/ or die 'score later entry';
      $new.=$pair;
      my$defs=join('',map{"const uint8_t TEMPLATE_late_pf$_ := TEMPLATE_playfield[".(4+$_)."];\n"}0..3);
      $component=$defs.$component;
   }
   # Both specialized exits jump over this unexecuted phase anchor. The
   # compact renderer and successor score retain all branch-page contracts.
   my$anchor=$score_late&&$score_order eq 'above'?"   asm .align 256, \$e6;\n":'';
   $component =~ s/(   asm \@TEMPLATE_A_c_u1:;)/$new$anchor$1/ or die 'score packed insertion';
   # Prime next-row M0 before borrowing X. Saved S and all RAM stay unchanged.
   $component =~ s/(   asm stx.z TEMPLATE_row_cache \+ 20;\n\}\n\nrequire inline void TEMPLATE_draw)/   asm stx.z TEMPLATE_row_cache + 20;\n   asm lda.z TEMPLATE_object_masks + 6;\n   asm sta.z TEMPLATE_row_cache + 6;\n}\n\nrequire inline void TEMPLATE_draw/ or die 'score packed priming';
   if($score_late&&$score_order eq 'below'&&!$bad_score_tail_call) {
      $component="bank0 void draw_probe_score_tail(void);\n".$component;
      # Enter the helper BEFORE the final gameplay WSYNC. Its leading WSYNC
      # absorbs JSR, preserving the existing line count and score entry phase.
      $component =~ s/   asm sta WSYNC;\n\}\n\nrequire inline void TEMPLATE_overscan/   draw_probe_score_tail();\n}\n\nrequire inline void TEMPLATE_overscan/ or die 'score tail terminal call';
   }
}
if($preview) {
   # Frozen counterpart of the preview, not just its generated ancestor.
   $component=slurp("$repo/test/fixtures/all_five_colors_sections_preview/component.c26");
   for my$n(1..8) {
      $component =~ s/(parameter section${n}_lines := )\d+;/$1$preview_heights[$n-1];/ or die 'preview height parameter';
   }
}
if($fine_spread) {
   # Private sparse-phase schedule, not a general geometry implementation.
   # It changes palettes at row offsets 2,6,14; row boundaries retain colour.
   # S holds row X only during drawing; no calls or stack accesses are allowed.
   for my$seam(@preview_seams) {
      grep{$_==$seam%16}($fine_boundary?(0,2,4,6,8,10,12,14):$fine_late?(2,4,6,8,10,12,14):$fine_rts?(2,4,6,8,14):(2,6,14)) or die 'unsupported fine spread phase';
   }
   my$helper=$fine_dense_later?'fine_dense_later':$fine_boundary?'fine_boundary':$fine_dense?'fine_dense_first':$fine_late?'fine_late':'fine_spread';
   my$build=do "$repo/test/fixtures/all_five_colors_sections_preview/$helper.pl";
   ref$build eq 'CODE' or die "fine spread helper: $@ $!";
   $component=$build->($repo,\@preview_heights,\@pal,$bad_fine_feed,$fine_rts,$uniform,$fine_mixed);
    if($bad_fine_p1) {
       # Reproduce the old early-COLUP1 bug without changing line cycles.
       # Sweep seam14: its crossing pose keeps P1 active in this A-row tail.
       # Seam30's corrected pose leaves row0 inactive and cannot expose it.
      $component =~ s/   asm sty.z TEMPLATE_object_masks \+ 1;\n(?=   asm cpy.z TEMPLATE_player1_height;\n   asm bcs.same \@TEMPLATE_fine_A_3_u7_p1_zero;)// or die 'fine early P1 mutation';
      $component =~ s/(   asm \@TEMPLATE_fine_A_3_u7_p1_ready:;\n   asm sta GRP1;)/$1\n   asm sty.z TEMPLATE_object_masks + 1;/ or die 'fine late P1 counter';
   }
}
if($example_score){
   $component=slurp("$repo/test/fixtures/all_five_colors_sections_score/component.c26");
   $component =~ s/parameter score_below := 0;/parameter score_below := 1;/ if$example_score eq 'below';
}
save("$tmp/component.c26",$component);

my$source=slurp("$repo/test/fixtures/all_five_player_color_192/smoke.c26");
if($preview) {
   # The spread-out preview folds the example's two alternating PF patterns.
   # Keep this fixture explicit rather than claiming arbitrary per-row PF data.
   my@rows=map{$uniform?(255,255,255,255):$_%2?(0x36,0x81,0x18,0xa5):(0x81,0x18,0x42,0x24)}0..11;
   my$pf='page const uint8_t game_playfield[48] := {'.join(',',@rows).'};';
   $source =~ s/page const uint8_t game_playfield\[48\] := \{.*?\};/$pf/s or die 'preview playfield fixture';
}
$source =~ s/0x81,0x18,0x18,0x81/0x69,0x96,0x3c,0xc3/g;
$source =~ s/0x69,0x96,0x3c,0xc3/0xff,0xff,0xff,0xff/ if$uniform;
$source =~ s/game_BALL_X := 80;/game_BALL_X := 8;/ or die 'isolated ball window';
# Eight nonblank rows, matching frame zero of the standard interactive sprites.
$source =~ s/game_SPRITE_GLYPH\(0x3c,0x66,0x66,0x7e,0x66,0x66,0x66,0x00\)/game_SPRITE_GLYPH(0x66,0x3c,0x7e,0xdb,0xff,0xbd,0xa5,0x42)/ or die 'P0 artwork';
$source =~ s/game_SPRITE_GLYPH\(0x7c,0x66,0x66,0x7c,0x66,0x66,0x7c,0x00\)/game_SPRITE_GLYPH(0x3c,0x66,0xff,0xdb,0xff,0x24,0x5a,0xa5)/ or die 'P1 artwork';
if($bad_glyph) {
   # Mutate BOTH the ordinary golden renderer and the probe. Raster equality
   # alone must not certify a shared, repeated-row artwork mistake.
   $source =~ s/0x66,0x3c,0x7e,0xdb,0xff,0xbd,0xa5,0x42/0x66,0x66,0x7e,0xdb,0xff,0xbd,0xa5,0x42/ or die 'negative glyph target';
}
for my$name(qw(player0 player1 missile0 missile1 ball)) {
   $source =~ s/game_${name}_y := \d+;/game_${name}_y := 8;/ or die "$name pose";
}
$source =~ s/void main\(void\)/uint8_t motion;\nvoid main(void)/ or die 'motion state';
my$updates=join('',map{"      game_${_}_y := motion;\n"}qw(player0 player1 missile0 missile1 ball));
$source =~ s/(      game_vblank\(\);)/      motion++;\n      if (motion == 40) { motion := 0; }\n$updates$1/ or die 'motion update';
if($preview&&!$edges) {
   # Forty captured poses cover a complete 32-step lap through all 96 Y units.
   $source =~ s/motion\+\+;\n      if \(motion == 40\) \{ motion := 0; \}/motion += 3;\n      if (motion >= 96) { motion -= 96; }/ or die 'spread motion';
   # Player Y is its lower edge: terminal seams188/190 need poses beyond95.
   # Include clipped-below-screen poses, preserving the independent full-glyph
   # and all-five-object straddle checks rather than waiving terminal seams.
   if($fine_dense_later&&$preview_heights[0]==178){
      $source =~ s/motion >= 96\) \{ motion -= 96;/motion >= 104) { motion -= 104;/ or die 'terminal dense motion';
   }
}
$source =~ s/(      game_vblank\(\);)/      COLUPF := 0x2e;\n      COLUBK := 0x84;\n$1/ or die 'palette reset';
if($edges) {
   # Exercise each object in isolation at both physical edges and the RESP
   # residue transitions. Controls run in overscan, as in the public examples;
   # putting another bank call in VBLANK can move visible entry by one line.
     # Fine-phase sweeps must cross the seam, not finish above it. Public Y
     # is the lower edge; one pair below the seam spans both sides, including
     # terminal190 after clipping. Keep the older non-fine fixture poses.
     my$pose=$preview?int($proof_seam/2)+($fine_spread?1:-2):$score_order?7:$profile eq 'late_dense'?13:$later?18:$profile eq 'handoff'?10:9;
     $pose-=3 if$bad_fine_pose; # Old non-crossing pose must fail presence gate.
    $pose=0 if$preview&&$pose<0; # Seam2 must straddle the top, not wrap to Y255.
   $source =~ s/void main\(void\)/bank1 page const uint8_t edge_positions[8] := {0,13,14,15,16,150,157,159};\nuint8_t edge;\nvoid main(void)/ or die 'edge table';
   for my$n(qw(player0 player1 missile0 missile1 ball)) {
      $source =~ s/game_${n}_y := motion;/game_${n}_y := 200;/ or die 'edge isolation';
   }
   my($move)=$source =~ /(      motion\+\+;.*?)(?=      COLUPF := )/s;
   defined$move or die 'edge motion extraction';
   $source =~ s/\Q$move\E// or die 'edge move removal';
   my$setup="      edge := edge_positions[motion & 7];\n";
   $setup.=join('',map{"      game_${_}_X := edge;\n"}qw(PLAYER0 PLAYER1 MISSILE0 MISSILE1 BALL));
   $setup.="      switch (motion >> 3) {\n";
   my@names=qw(player0 player1 missile0 missile1 ball);
   $setup.=join('',map{"         case $_: game_$names[$_]\_y := $pose; break;\n"}0..4);
   $setup.="      }\n";
   my$helper="bank1 void update_probe_pose(void) {\n$move$setup}\n";
   $source =~ s/void main\(void\)/$helper\nvoid main(void)/ or die 'edge helper';
   $source =~ s/(      game_overscan\(\);)/$1\n      update_probe_pose();/ or die 'edge overscan call';
   $source =~ s/include "vcs.c26"/include "vcs.c26"\ninclude "F8\/mapper.c26"/ or die 'edge mapper';
   $component=bank_preparation($component) if!$later;
   save("$tmp/component.c26",$component);
}
if($fine_controls) {
   $edges or die 'fine control fixture requires isolated poses';
   my$controls=<<'CONTROLS';
bank0 page const uint8_t alternate_p0[8] := {0x81,0x42,0x24,0x18,0x18,0x24,0x42,0x81};
bank0 page const uint8_t alternate_p1[8] := {0xff,0x81,0xbd,0xa5,0xa5,0xbd,0x81,0xff};
bank0 void update_probe_controls(void) {
   if (motion & 1) {
      game_player0_graphics := alternate_p0;
      game_player1_graphics := alternate_p1;
   } else {
      game_player0_graphics := p0_graphics;
      game_player1_graphics := p1_graphics;
   }
   game_player0_height := motion & 7;
   game_player1_height := (motion >> 1) & 7;
   game_missile0_height := (motion & 7) + 1;
   game_missile1_height := ((motion >> 1) & 7) + 1;
   game_ball_height := (motion & 3) + 1;
   game_PLAYER0_NUSIZ := 0x20 | (motion & 7);
   game_PLAYER1_NUSIZ := 0x20 | ((motion >> 1) & 7);
}
CONTROLS
   $source =~ s/void main\(void\)/$controls\nvoid main(void)/ or die 'fine control helper';
   $source =~ s/(      update_probe_pose\(\);)/$1\n      update_probe_controls();/ or die 'fine control update';
}
my$probe=$source;
if($score_order) {
   $source =~ s/game_playfield\[48\]/game_playfield[44]/ or die 'score field size';
   $source =~ s/   0xff,0xff,0xff,0xff\n\};/};/ or die 'score field tail';
   $source =~ s#renderers/all_five_player_color_192/all_five_player_color_192.c26#renderers/all_five_player_color_181/all_five_player_color_181.c26#g;
   $source =~ s/(include "frame_ntsc.c26")/$1\ninclude "fonts\/default_decimal.c26"/ or die 'score font';
   $source =~ s/(instantiate "renderers\/all_five_player_color_181\/all_five_player_color_181.c26" as game)/$1\ninstantiate "six_glyph_component.c26" as score/ or die 'score instantiation';
    $source =~ s/(   game_init\(\);)/$1\n   score_score := 123456;\n   score_init();/ or die 'score init';
    if($score_packed) {
       # Keep pointer preparation in ordinary bank1 ROM, but pass the real
       # bank0 font address instead of mirroring drawing data or pinning a
       # bank1 helper to a bank0 symbol through an immediate relocation.
       $source =~ s/instantiate "six_glyph_component.c26" as score/instantiate "six_glyph_component.c26" as score (external_pointers:=1)/ or die 'external score pointers';
       my$score=slurp("$repo/libraries/vcs/six_glyph_component.c26");
       my($prepare)=$score =~ /#if TEMPLATE_compact_font && TEMPLATE_glyph_rows == 8\nstatic inline void TEMPLATE_prepare_pointers\(void\) \{(.*?)\n\}\n#else/s;
       defined$prepare or die 'score pointer preparation';
       $prepare =~ s/TEMPLATE_/score_/g;
       $prepare =~ s/#<score_font/probe_font/g;
       $prepare =~ s/#>score_font/probe_font+1/g;
       my$helper="const uint8_t *probe_font;\nbcd24_t score_score := 0;\nbank1 void prepare_probe_score(void) {".$prepare."\n}\n";
       $source =~ s/void main\(void\)/$helper\nvoid main(void)/ or die 'banked score pointer helper';
       $source =~ s/score_init\(\);/score_init();\n   probe_font := score_font;\n   prepare_probe_score();/ or die 'banked score initialization';
       # The candidate is copied below, then the golden is switched back to
       # ordinary score preparation and the independent gameplay kernel.
       $source =~ s/include "vcs.c26"/include "vcs.c26"\ninclude "F8\/mapper.c26"/ if!$edges;
    }
    $source =~ s/(      game_vblank\(\);)/$1\n      score_vblank();/ or die 'score vblank';
    $source =~ s/score_vblank\(\);/score_vblank();\n      prepare_probe_score();/ or die 'banked score preparation call' if$score_packed;
   $source =~ s/(      game_overscan\(\);)/$1\n      score_overscan();/ or die 'score overscan';
    my$draw=$score_order eq 'above'?"      score_draw();\n      vcs_ntsc_component_handoff();\n      game_draw();":"      game_draw();\n      vcs_ntsc_component_handoff();\n      score_draw();";
    $source =~ s/      game_draw\(\);/$draw/ or die 'score drawing';
    if($score_dynamic) {
       my@values=(0,9,99,999,9999,99999,999999,123456);
       my$update="bank1 void update_probe_score(void) {\n   switch (motion & 7) {\n";
       $update.=join('',map{"      case $_: score_score := $values[$_]; break;\n"}0..7);
       $update.="   }\n}\n";
       $source =~ s/void main\(void\)/$update\nvoid main(void)/ or die 'dynamic score helper';
       $source =~ s/(      game_vblank\(\);)/      update_probe_score();\n$1/ or die 'dynamic score call';
    }
    $probe=$source;
    $probe =~ s#renderers/all_five_player_color_181/all_five_player_color_181.c26#$tmp/component.c26# or die 'score component include';
    if($score_packed) {
       # The golden score MUST keep its original pointer preparation. Sharing
       # the banked helper would conceal a font-address/digit-order mistake.
       $source =~ s/instantiate "six_glyph_component.c26" as score \(external_pointers:=1\)/instantiate "six_glyph_component.c26" as score/ or die 'ordinary golden score';
       $source =~ s/const uint8_t \*probe_font;\nbcd24_t score_score := 0;\nbank1 void prepare_probe_score\(void\) \{.*?\n\}\n//s or die 'remove golden banked score helper';
       $source =~ s/   probe_font := score_font;\n   prepare_probe_score\(\);\n// or die 'ordinary golden score initialization';
       $source =~ s/      prepare_probe_score\(\);\n// or die 'ordinary golden score preparation';
    }
} else {
   $probe =~ s#renderers/all_five_player_color_192/all_five_player_color_192.c26#$tmp/component.c26# or die 'component include';
}
if($score_packed) {
   if($score_dynamic) {
      # Candidate score controls and pointer preparation share bank1. Keep
      # the golden's separately called updater and original preparation.
      my($update)=$probe =~ /bank1 void update_probe_score\(void\) \{(.*?)\n\}/s;
      defined$update or die 'dynamic candidate score updater';
      $probe =~ s/bank1 void update_probe_score\(void\) \{.*?\n\}\n//s or die 'fold dynamic score helper';
      $probe =~ s/      update_probe_score\(\);\n// or die 'fold dynamic score call';
      $probe =~ s/(bank1 void prepare_probe_score\(void\) \{)/$1$update\n/ or die 'dynamic candidate preparation';
   }
   my($initial)=$probe =~ /void main\(void\) \{\n(.*?)(?=   game_player0_graphics := )/s;
   defined$initial or die 'score packed initialization';
   $probe =~ s/void main\(void\) \{\n\Q$initial\E/bank1 void initialize_probe_objects(void) {\n$initial}\nvoid main(void) {\n   initialize_probe_objects();\n/ or die 'score packed banked initialization';
   my($heights)=$probe =~ /(   game_player0_height := .*?   game_init\(\);\n)/s;
   defined$heights or die 'score packed initial heights';
   $probe =~ s/\Q$heights\E// or die 'score packed move heights';
   $probe =~ s/(bank1 void initialize_probe_objects\(void\) \{\n.*?)(\n\})/$1\n$heights$2/s or die 'score packed banked heights';
   $probe =~ s/void main\(void\)/bank1 void finish_probe_gameplay(void) { game_overscan(); }\nvoid main(void)/ or die 'score packed banked cleanup';
   $probe =~ s/(      vcs_ntsc_begin_overscan\(\);\n)      game_overscan\(\);/$1      finish_probe_gameplay();/ or die 'score packed cleanup call';
   if(!$edges) {
      my($move)=$probe =~ /(      motion\+\+;.*?)(?=      COLUPF := )/s;
      defined$move or die 'score packed pose update';
      $probe =~ s/\Q$move\E// or die 'score packed move pose';
      $probe =~ s/bank1 void finish_probe_gameplay\(void\) \{ game_overscan\(\); \}/bank1 void advance_probe_pose(void) {\n$move}\nbank1 void finish_probe_gameplay(void) { game_overscan(); advance_probe_pose(); }/ or die 'score packed overscan pose';
      $probe =~ s/(   prepare_probe_score\(\);\n)(   while)/$1   advance_probe_pose();\n$2/ or die 'score packed first pose';
   }
    if(($score_late||$example_score)&&$score_order eq 'below') {
      # The gameplay terminal calls this helper before its final WSYNC. Start
      # overscan before returning so RTS is absorbed by the timer deadline.
      # This is another function in bank0, never a second drawing bank.
      my$tail="      vcs_ntsc_component_handoff();\n      score_draw();\n      vcs_ntsc_begin_overscan();";
      my$call=$bad_score_tail_call?'      draw_probe_score_tail();':'';
      $probe =~ s/\Q$tail\E/$call/ or die 'score tail composition';
      my$sync=$bad_score_tail_call?'':"      asm sta WSYNC;\n";
      my$wrapper="bank0 void draw_probe_score_tail(void) {\n$sync$tail\n}\n";
       $probe =~ s/void main\(void\)/$wrapper\nvoid main(void)/ or die 'score tail function';
       $probe =~ s/draw_probe_score_tail/draw_combined_score_tail/g if$example_score;
   }
}
if($fine_spread) {
   my($initial)=$probe =~ /void main\(void\) \{\n(.*?)(?=   game_player0_graphics := )/s;
   defined$initial or die 'fine initialization';
   $probe =~ s/void main\(void\) \{\n\Q$initial\E/bank1 void initialize_probe_objects(void) {\n$initial}\nvoid main(void) {\n   initialize_probe_objects();\n/ or die 'fine banked initialization';
   my($heights)=$probe =~ /void main\(void\) \{.*?(   game_player0_height := .*?   game_init\(\);\n)/s;
   defined$heights or die 'fine initial heights';
   $probe =~ s/\Q$heights\E// or die 'fine move heights';
   $probe =~ s/(bank1 void initialize_probe_objects\(void\) \{\n.*?)(\n\})/$1\n$heights$2/s or die 'fine banked heights';
   $probe =~ s/void main\(void\)/bank1 void finish_probe_gameplay(void) { game_overscan(); }\nvoid main(void)/ or die 'fine banked cleanup';
   $probe =~ s/(      vcs_ntsc_begin_overscan\(\);\n)      game_overscan\(\);/$1      finish_probe_gameplay();/ or die 'fine cleanup call';
}
$probe =~ s/include "vcs.c26"/include "vcs.c26"\ninclude "F8\/mapper.c26"/ if$later&&!$edges&&!$score_packed;
save("$tmp/probe.c26",$probe);
run("$repo/driver/vcsc",'-I',"$repo/libraries/vcs","$tmp/probe.c26",'-o',"$tmp/probe.bin");
-s"$tmp/probe.bin"==($later||$edges?8192:4096) or die 'unexpected probe ROM size';
my$mos="$repo/simulator/mos6502";
my$obj=-f"$mos/mos6502.o"?"$mos/mos6502.o":"$mos/mos6502.cpp";
run($ENV{CXX}||'c++','-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,
   "$repo/test/vcs_frame_timing.cpp",$obj,'-o',"$tmp/timing");
run("$tmp/timing","$tmp/probe.bin",'200','--no-audio','--released-inputs','--raw-lines','264');
my$sym=slurp("$tmp/probe.sym");
sub address { my$n=shift;$sym =~ /^\Q$n\E\s+([0-9a-fA-F]{4})\s*$/m or die "missing symbol $n";return hex$1; }
my@runtime=('--randomize-zp',address('game_object_x'),5,160,733,
   '--randomize-zp',address('game_player0_nusiz'),2,256,911);
for my$n(qw(game_player0_height game_player1_height game_missile0_height game_missile1_height game_ball_height)) {
   push@runtime,'--randomize-zp',address($n),1,8,955+scalar@runtime;
}
run("$tmp/timing","$tmp/probe.bin",'420','--no-audio','--released-inputs','--raw-lines','264',@runtime);
my@graphics;
for my$n(qw(game_player0_graphics game_player1_graphics)) {
   my$a=address($n);my@p=map{address($_)}qw(p0_graphics p1_graphics);
   push@graphics,'--frame-sequence',$a,join(',',map{$_&255}@p),
      '--frame-sequence',$a+1,join(',',map{$_>>8}@p);
}
my@restored_heights=$fine_controls?(3,1):(7,7);
run("$tmp/timing","$tmp/probe.bin",'420','--no-audio','--released-inputs','--raw-lines','264',@graphics,
   '--expect-memory',address('game_player0_height'),$restored_heights[0],
   '--expect-memory',address('game_player1_height'),$restored_heights[1],
   $fine_controls?('--expect-memory',address('motion'),19):());

require "$repo/test/stella_test_lib.pl";
my$helpers=slurp("$repo/test/stella_png_sequence.pl");
$helpers =~ s/\n\@ARGV>=2.*\z//s or die 'PNG helper boundary';eval$helpers;die$@ if$@;
sub findexe {
   my$n=shift;return abs_path($n) if$n=~m{/}&&-x$n;
   for(split(/:/,$ENV{PATH}//'')){my$p="$_/$n";return abs_path($p) if-x$p;}
   die "required executable not found: $n\n";
}
my$stella=findexe($ENV{VCSC_STELLA}||$ENV{STELLA}||'stella');
my$xvfb=findexe($ENV{VCSC_XVFB}||$ENV{XVFB}||'Xvfb');
my%children;
sub terminate { my$p=shift;kill 'TERM',$p;waitpid($p,0);delete$children{$p}; }
END { local$?;terminate($_) for keys%children; }
my(undef,$display)=vcsc_reserve_x_display(250,40);
my$xp=fork();defined$xp or die$!;
if(!$xp){open(STDOUT,'>',"$tmp/xvfb.log");open(STDERR,'>&STDOUT');exec($xvfb,$display,'-ac','-screen','0','1024x768x24');die$!}
$children{$xp}=1;vcsc_xvfb_assert_ready($display,$xp);
local$ENV{DISPLAY}=$display;local$ENV{XAUTHORITY}='/dev/null';local$ENV{SDL_AUDIODRIVER}='dummy';
sub capture {
   my($name,$bin)=@_;my$snap="$tmp/snap_$name";my$user="$tmp/user_$name";
   # Every capture has a fresh directory: stale PNGs must not satisfy readiness.
   !-e$snap or die "capture directory already exists: $snap";
   make_path($snap,$user);
   my$p=fork();defined$p or die$!;
   if(!$p){open(STDOUT,'>',"$tmp/stella_$name.log");open(STDERR,'>&STDOUT');
      exec($stella,vcsc_stella_palette_args($repo,$user),
         '-plr.bankrandom','0','-plr.ramrandom','0','-plr.tiarandom','0',
         '-dev.bankrandom','0','-dev.ramrandom','0','-dev.cpurandom','0','-dev.tiarandom','0',
         '-dev.hsrandom','0','-dev.tiadriven','0','-video','software','-turbo','1','-audio.enabled','0',
         '-bs',(-s$bin==8192?'F8':'4K'),'-framesnap','200-239','-snapsavedir',$snap,'-snapname','rom','-sssingle','1','-ss1x','1',
         '-exitlauncher','0','-confirmexit','0','-userdir',$user,$bin);die$!}
   $children{$p}=1;my@png;
   @png=vcsc_stella_wait_snapshots("$snap/*.png",40);
   # Let the final PNG writer close before terminating the emulator.
   select undef,undef,undef,.025;terminate($p);
   @png==40 or die "$name snapshot count !=40\n";
   my%frames;for(@png){/_([0-9A-F]{8})\.png$/ or die 'snapshot name';$frames{hex$1}=[decode_rgb($_)];}
   return\%frames;
}
my@gold;
for my$n(0..$#pal) {
   my$s=$source;
   $s =~ s/COLUPF := 0x2e;/COLUPF := $pal[$n][0];/g;
   $s =~ s/COLUBK := 0x84;/COLUBK := $pal[$n][1];/g;
   save("$tmp/gold_$n.c26",$s);
   run("$repo/driver/vcsc",'-I',"$repo/libraries/vcs","$tmp/gold_$n.c26",'-o',"$tmp/gold_$n.bin");
   $gold[$n]=capture("gold_$n","$tmp/gold_$n.bin");
}
my$actual=capture('probe',"$tmp/probe.bin");
my$empty=$source;
for my$name(qw(player0 player1 missile0 missile1 ball)) {
   if($edges) {
      $empty =~ s/(case \d: game_${name}_y := )\d+;/${1}200;/ or die "$name empty edge pose";
   } else {
      $empty =~ s/game_${name}_y := motion;/game_${name}_y := 200;/ or die "$name empty pose";
   }
}
save("$tmp/empty.c26",$empty);
run("$repo/driver/vcsc",'-I',"$repo/libraries/vcs","$tmp/empty.c26",'-o',"$tmp/empty.bin");
my$background=capture('empty',"$tmp/empty.bin");
my@seams=$edges ? () : $preview ? @preview_seams : $score_order ? (2,4,6,8,10,12,$score_packed?14:(),$score_late?18:()) : $profile eq 'late_dense' ? (18,20,22,24,26,28,$routed?():32) : $later ? (32) : (2,4,6,8,10,12,$profile eq 'packed'?14:$profile eq 'handoff'?16:());
my(%crossed,%complete_glyph,%edge_crossed);
for my$f(200..239) {
    my($w,$h,$rgb)=@{$gold[0]{$f}};my%count;
    # Repeated NUSIZ copies can cover the usual border sample. For the
    # control matrix locate the same 192 lines in the independent empty ROM.
    my$extent=$fine_controls?$background->{$f}[2]:$rgb;
    $count{substr($extent,($_*$w+20)*3,3)}++ for 0..$h-1;
    my($bg)=sort{$count{$b}<=>$count{$a}}keys%count;
    my@visible=grep{substr($extent,($_*$w+20)*3,3)eq$bg}0..$h-1;
   ($score_order?@visible>=176:@visible==192) or die 'visible extent';
    my$first=$visible[0]+($score_order?($score_order eq 'above'?15:4):0);my$expected=$rgb;
    if($edges&&$fine_spread){
       # First frame uses setup coordinates; subsequent overscans increment
       # the forty-pose counter. Each eight-frame group isolates one object.
       # Require physical pixels on both sides, not equality of two blanks.
       my$name=(qw(P0 P1 M0 M1 BL))[int((($f-1)%40)/8)];my@on;
       for my$lines([$first+$proof_seam-2,$first+$proof_seam-1],[$first+$proof_seam,$first+$proof_seam+1]){
          my$visible=0;
          for my$y(@$lines){for my$x(0..$w-1){my$p=($y*$w+$x)*3;
             $visible=1 if substr($rgb,$p,3)ne substr($background->{$f}[2],$p,3);
          }}
          push@on,$visible;
       }
       $edge_crossed{$name}=1 if$on[0]&&$on[1];
    }
   if(!$edges) {
      # Independent top-to-bottom artwork, not decoded from the fixture or
      # inferred from another renderer. The whole-raster oracle below then
      # transfers this geometry requirement to the sectioned output. Palette
      # zero never shares either player's colour, so an empty-field difference
      # identifies every intentional bit, including doubled horizontal pixels.
      for my$glyph(['P0',38,[0x66,0x3c,0x7e,0xdb,0xff,0xbd,0xa5,0x42]],
                   ['P1',258,[0x3c,0x66,0xff,0xdb,0xff,0x24,0x5a,0xa5]]) {
         my($name,$left,$shape)=@$glyph;my@rows;
         for my$y($first..$first+($score_order?175:191)) {
            my$bits=0;
            for my$bit(0..7) {
               my$x=$left+2*$bit;my@on;
               for my$half(0,1){my$p=($y*$w+$x+$half)*3;
                  push@on,substr($rgb,$p,3)ne substr($background->{$f}[2],$p,3);
               }
               $on[0]==$on[1] or die "$name frame $f half-pixel glyph bit\n";
               $bits|=0x80>>$bit if$on[0];
            }
            push@rows,$bits if$bits;
         }
         @rows<=16 or die "$name frame $f extra glyph rows\n";
         if(@rows==16) {
            join(',',@rows)eq join(',',map{($_,$_)}@$shape) or die "$name frame $f glyph rows differ from canonical eight-row shape: ".join(',',map{sprintf('%02x',$_)}@rows)."\n";
            $complete_glyph{$name}=1;
         }
      }
   }
   for my$line(2..($score_order?$h-$first-1:191)) {
      my$n=$preview ? preview_palette($line) : $score_order ? ($line<12?int($line/2)%4:$score_late&&$line>=18?0:$score_packed&&$line>=14?3:2) : $profile eq 'late_dense' ? ($line<18?0:$line<28?int(($line-16)/2)%4:$routed||$line<32?2:3) : $later ? ($line<32?0:3) : $line<12 ? int($line/2)%4 : (($profile eq 'packed'&&$line>=14)||($profile eq 'handoff'&&$line>=16) ? 3 : 2);
      substr($expected,($first+$line)*$w*3,$w*3)=substr($gold[$n]{$f}[2],($first+$line)*$w*3,$w*3);
   }
   my($aw,$ah,$got)=@{$actual->{$f}};$aw==$w&&$ah==$h or die 'image geometry';
   if($got ne$expected) {
      for my$y(0..$h-1){for my$x(0..$w-1){my$p=($y*$w+$x)*3;
         substr($got,$p,3)eq substr($expected,$p,3) or die "frame $f RGB mismatch at $x,$y (visible line ".($y-$first).")\n";
      }}
   }
   # Separate, non-overlapping object windows prove actual pixels on both
   # sides, not merely agreement between two blank/completely clipped renders.
   for my$seam(@seams) {
      for my$obj(['P0',36,56],['P1',256,280],['M0',94,110],['M1',214,230],['BL',10,22]) {
         my($name,$lo,$hi)=@$obj;my@seen;
         next if$name eq 'P0'&&$seam==2; # inherited two-line P0 priming
         for my$side([$first+$seam-2,$first+$seam-1],[$first+$seam,$first+$seam+1]) {
            my$visible=0;
            for my$y($side->[0]..$side->[1]){for my$x($lo..$hi){my$p=($y*$w+$x)*3;
               $visible=1 if substr($rgb,$p,3)ne substr($background->{$f}[2],$p,3);
            }}
            push@seen,$visible;
         }
         $crossed{"$name/$seam"}=1 if$seen[0]&&$seen[1];
      }
   }
}
for my$seam(@seams){for my$name(qw(P0 P1 M0 M1 BL)){
   next if$name eq 'P0'&&$seam==2;
   $crossed{"$name/$seam"} or die "$name never straddled seam $seam\n";
}}
if(!$edges){$complete_glyph{$_} or die "$_ never displayed a complete canonical glyph\n" for qw(P0 P1);}
if($edges&&$fine_spread){for my$name(qw(P0 P1 M0 M1 BL)){
   next if$name eq 'P0'&&$proof_seam==2; # inherited P0 priming, as above
   $edge_crossed{$name} or die "$name never crossed seam $proof_seam in edge sweep\n";
}}
print "vcs_all_five_colors_sections_probe ok\n";
