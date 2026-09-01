#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_standard_renderer_normalization ok
# expectexit: 0


use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub usage { die "usage: $0 REPO_ROOT TMP_DIR\n"; }
sub slurp_fh { my ($fh)=@_; local $/; my $d=<$fh>; return defined($d)?$d:''; }
sub run_capture {
   my (@cmd)=@_;
   my $err=gensym;
   my $pid=open3(my $in,my $out,$err,@cmd);
   close($in);
   my $stdout=slurp_fh($out);
   my $stderr=slurp_fh($err);
   waitpid($pid,0);
   return ($? >> 8, $? & 127, $stdout, $stderr);
}
sub read_file {
   my ($path)=@_;
   open(my $fh,'<:raw',$path) or die "could not open $path: $!\n";
   local $/; my $d=<$fh>; close($fh) or die "could not close $path: $!\n";
   return defined($d)?$d:'';
}
sub write_file {
   my ($path,$text)=@_;
   open(my $fh,'>:raw',$path) or die "could not create $path: $!\n";
   print {$fh} $text;
   close($fh) or die "could not close $path: $!\n";
}
sub require_re {
   my ($text,$re,$why)=@_;
   $text =~ $re or die "$why\n";
}

my $repo=shift @ARGV // usage();
my $tmp=shift @ARGV // usage();
usage() if @ARGV;
$repo=abs_path($repo) // die "could not resolve repo root\n";
$tmp=abs_path($tmp) // die "could not resolve temp dir\n";

my $assembler=File::Spec->catfile($repo,'assembler','vcsc-as');
my $profile=File::Spec->catdir($repo,'libraries','vcs','renderers','standard_4k_ntsc');
my $normalizer=File::Spec->catfile($profile,'normalize.pl');
my $macros=File::Spec->catfile($profile,'standard_4k_ntsc_macros.inc');
my $renderer=File::Spec->catfile($profile,'standard_4k_ntsc_renderer.s26');
my $generated=File::Spec->catdir($tmp,'normalized');
make_path($generated);

my ($check_exit,$check_sig,$check_out,$check_err)=run_capture($normalizer,'--check');
$check_exit == 0 && !$check_sig
   or die "normalization check exited $check_exit signal $check_sig\nstdout:\n$check_out\nstderr:\n$check_err";
$check_out eq "standard_4k_ntsc normalization is current\n"
   or die "unexpected normalization-check stdout:\n$check_out";
$check_err eq '' or die "normalization check wrote stderr:\n$check_err";

my ($gen_exit,$gen_sig,$gen_out,$gen_err)=run_capture(
   $normalizer,'--output-dir',$generated);
$gen_exit == 0 && !$gen_sig
   or die "normalization generation exited $gen_exit signal $gen_sig\nstdout:\n$gen_out\nstderr:\n$gen_err";
$gen_err eq '' or die "normalization generation wrote stderr:\n$gen_err";
for my $name ('standard_4k_ntsc_macros.inc','standard_4k_ntsc_renderer.s26') {
   my $checked=read_file(File::Spec->catfile($profile,$name));
   my $fresh=read_file(File::Spec->catfile($generated,$name));
   $fresh eq $checked or die "$name is not reproducibly generated\n";
}

my $macro_text=read_file($macros);
my $renderer_text=read_file($renderer);
my @macro_defs=($macro_text =~ /^MACRO\s+([A-Za-z_][A-Za-z0-9_]*)\b/mg);
join(',',@macro_defs) eq 'SLEEP,VERTICAL_SYNC,CLEAN_START,SET_POINTER,RETURN'
   or die "normalized macro set/order is wrong: @macro_defs\n";
require_re($macro_text,qr/^MACRO SET_POINTER pointer,address$/m,
   'SET_POINTER does not use two named macro parameters');
require_re($macro_text,qr/BIT\s+VSYNC/,
   'SLEEP does not use the legal three-cycle BIT delay');
$macro_text !~ /NOP\.z|NO_ILLEGAL_OPCODES/
   or die "SLEEP still contains unofficial-opcode selection\n";
require_re($macro_text,qr/standard_4k_ntsc RETURN does not support bankswitch/,
   'RETURN does not reject the excluded bankswitch profile');

my $active=$renderer_text;
$active =~ s/;[^\n]*//g;
$active !~ /^\s*(?:ifconst|ifnconst|if|else|endif|repeat|repend|align|include|MAC|ENDM)\b/im
   or die "active normalized source still contains a bare DASM directive\n";
$active !~ /\.[Ww]\b/
   or die "active normalized source still contains a DASM forced mode\n";
$active !~ /\b(?:player0x|scorepointers|temp[1-6]|playfieldbase|stack[12])\b/
   or die "active normalized source still uses old fixed-map state names\n";
require_re($active,qr/^\s*\.include\s+"standard_4k_ntsc_macros\.inc"/m,
   'normalized renderer does not include the normalized macro file');
$active !~ /^\s*(?:ASR|ALR|SBX|AXS|NOP\.z)\b/im
   or die "normalized standard renderer still contains a task-20r unofficial form\n";
require_re($active,qr/\b(?:lda|ldy)\.(?:a|ax|ay)\b/i,
   'selected source is missing explicit forced-wide addressing');
my $aligns=()=$active =~ /^\s*\.align\s+256\b/mg;
$aligns == 5 or die "selected source has $aligns page alignments, expected five\n";
require_re($active,qr/^\s*\.segmentregion\s+"RENDERER_CODE",\s*startup$/m,
   'renderer code segment does not carry its startup-region contract');
require_re($active,qr/^\s*\.segmentalign\s+"RENDERER_CODE",\s*256$/m,
   'renderer code segment does not carry its 256-byte alignment contract');
require_re($active,qr/^\s*\.segmentprivate\s+"RENDERER_CODE"$/m,
   'renderer code segment does not carry its private-route contract');
require_re($active,qr/^\s*\.segmentregion\s+"RENDERER_RODATA",\s*startup$/m,
   'renderer score-table segment does not carry its startup-region contract');
require_re($active,qr/^\s*\.segmentalign\s+"RENDERER_RODATA",\s*256$/m,
   'renderer score-table segment does not carry its 256-byte alignment contract');
require_re($active,qr/^\s*\.segmentprivate\s+"RENDERER_RODATA"$/m,
   'renderer score-table segment does not carry its private-route contract');
require_re($active,qr/^\s*\.callstackextra\s+4$/m,
   'renderer object does not carry its hidden-stack contract');
require_re($active,qr/^\s*lda\s+#37\+128\s*$/m,
   'selected renderer no longer uses the Stella-verified 262-line vblank timer');
require_re($active,qr/\.align 256\s+\@kerloop:/s,
   'hot two-line renderer loop is no longer page-aligned');
$active !~ /\@skipDrawP[01]:/
   or die "obsolete steady player skip stubs remain in normalized source\n";
require_re($active,
   qr/\@startrenderer:\s+ldy vcs_standard_player1_y\s+dey\s+sty vcs_standard_player1_y\s+cpy vcs_standard_object_masks \+ 15\s+bcc\.same \@drawP1\s+lda vcs_standard_object_masks \+ 19\s+jmp \@continueP1\s+\@drawP1:\s+lda \(vcs_standard_player1_graphics\),y\s+\@continueP1:\s+sta GRP1/s,
   'legal steady player-1 path or its cycle-balanced zero path changed');
require_re($active,
   qr/ldy vcs_standard_player0_y\s+dey\s+sty vcs_standard_player0_y\s+cpy vcs_standard_object_masks \+ 11\s+bcc\.same \@drawP0\s+lda vcs_standard_object_masks \+ 19\s+jmp \@continueP0\s+\@drawP0:\s+lda \(vcs_standard_player0_graphics\),y\s+\@continueP0:\s+sta\.a GRP0/s,
   'legal steady player-0 path or its cycle-balanced zero path changed');
require_re($active,qr/\@continuerenderer:\s+\@continuerenderer2:/s,
   'steady loop did not consume the former two-cycle pad');
$active !~ /^\s*dcp\b/im
   or die "normalized standard renderer still uses DCP\n";
require_re($active,qr/jsr vcs_standard_prepare_object_masks.*?\.proc vcs_standard_prepare_object_masks.*?lda vcs_standard_player0_height.*?sta vcs_standard_object_masks \+ 11.*?lda vcs_standard_player1_height.*?sta vcs_standard_object_masks \+ 15.*?lda #0\s+sta vcs_standard_object_masks \+ 19.*?lda #1\s+sta vcs_standard_object_masks \+ 23.*?lda vcs_standard_ball_height\s+dec vcs_standard_ball_y\s+cmp vcs_standard_ball_y\s+rol\s+rol\s+sta vcs_standard_object_masks \+ 27.*?sbc #89.*?sta vcs_standard_object_masks \+ 31.*?lda vcs_standard_missile1_height\s+dec vcs_standard_missile1_y.*?sta vcs_standard_object_masks \+ 35.*?sbc #89.*?sta vcs_standard_object_masks \+ 39.*?lda vcs_standard_missile0_height\s+dec vcs_standard_missile0_y.*?lda #\$fd\s+adc #0\s+sta vcs_standard_object_masks \+ 43\s+rts/s,
   'object-mask/player-state/final-value preparation helper changed');
require_re($active,qr/\@enterlastrenderer:\s+lda vcs_standard_object_masks \+ 27\s+bit vcs_standard_object_masks \+ 19\s+SLEEP 6\s+sta ENABL\s+lda vcs_standard_object_masks \+ 31\s+bit vcs_standard_object_masks \+ 19\s+SLEEP 12\s+sta GRP1.*?lda vcs_standard_object_masks \+ 35\s+bit vcs_standard_object_masks \+ 19\s+nop.*?SLEEP 4\s+sta ENAM1.*?lda vcs_standard_object_masks \+ 39\s+bit vcs_standard_object_masks \+ 19\s+bit vcs_standard_object_masks \+ 19\s+SLEEP 10\s+sta GRP0.*?lda vcs_standard_object_masks \+ 43\s+bit vcs_standard_object_masks \+ 19\s+bit vcs_standard_object_masks \+ 19\s+nop\s+sta ENAM0/s,
   'legal final-row object schedule changed');
require_re($active,qr/lsr vcs_standard_object_masks,x\s+adc #0.*?lsr vcs_standard_object_masks \+ 1,x.*?adc #0.*?lsr vcs_standard_object_masks \+ 2,x.*?adc #0/s,
   'legal steady ball/missile mask schedule changed');
require_re($active,qr/^\s*ldx\s+#0\s*$/m,
   'playfield row index is not zero-based');
$active !~ /vcs_standard_playfield[^\n]*-128/
   or die "biased playfield operands remain in normalized source\n";
for my $operand ('vcs_standard_playfield,x','vcs_standard_playfield+1,x',
                 'vcs_standard_playfield+2,x','vcs_standard_playfield+3,x') {
   my $count=()=$active =~ /\Q$operand\E/g;
   $count == 2 or die "$operand appears $count times, expected two direct row reads\n";
}
require_re($active,qr/txa\s+adc\s+#4\s+tax\s+cpx\s+#44\s+bcs\.same\s+\@lastrendererline/s,
   'zero-based playfield loop does not use the legal carry-clear ADC/TAX advance');
require_re($active,qr/bcs\.same\s+\@lastrendererline.*?SLEEP 3.*?\@lastrendererline:\s+SLEEP 6/s,
   'legal row-advance transition padding changed');
require_re($active,qr/^\s*\.if\s+\{<\*\}\s*>\s*\$e9\s*&&\s*\{<\*\}\s*<\s*\$fa\s*\n\s*\.align\s+256\s*,\s*\$fa\s*,\s*\$ea\s*\n\s*\.endif/m,
   'page-tail NOP fill is not expressed by the guarded fill-byte alignment');
$active !~ /^\s*\.if\s+\{<\*\}\s*<\s*\$fa\s*$/m
   or die "old hand-expanded page-tail conditional NOP sludge remains\n";
require_re($active,qr/^\.import\s+vcs_standard_playfield$/m,
   'application-provided playfield is not imported directly');
require_re($active,qr/^\.import\s+vcs_standard_overscan_hook$/m,
   'overscan hook is not an externally relocatable import');
require_re($active,
   qr/sta WSYNC\s+sta VBLANK\s+jsr vcs_standard_overscan_hook\s+RETURN/s,
   'overscan hook is not called after final blanking and before return');
require_re($active,
   qr/^\.export __sbpmeta\$E\$vcs_standard_renderer_drawscreen\$vcs_standard_overscan_hook$/m,
   'drawscreen-to-hook call-graph edge metadata is missing');
require_re($active,
   qr/\.proc __weak_vcs_standard_overscan_hook\s+\.export __weak_vcs_standard_overscan_hook\s+rts\s+\.endproc/s,
   'weak no-op overscan-hook fallback is missing');
require_re($active,qr/vcs_standard_pointer_workspace\s*\+\s*11/,
   'normalized source does not address the complete pointer workspace');
require_re($active,qr/\@scorepointerset:.*?txa\s+and\s+#\$F0\s+lsr\s+adc\s+#<vcs_standard_score_table/s,
   'score-pointer setup does not use the legal AND/LSR replacement');
require_re($active,
   qr/lda vcs_standard_score\+2\s+tax\s+jsr \@scorepointerset\s+stx vcs_standard_pointer_workspace\s+sty vcs_standard_pointer_workspace\+3\s+lda vcs_standard_score\+1\s+tax\s+jsr \@scorepointerset\s+stx vcs_standard_pointer_workspace\+1\s+sty vcs_standard_pointer_workspace\+4\s+lda vcs_standard_score\s+tax\s+jsr \@scorepointerset\s+stx vcs_standard_pointer_workspace\+2\s+sty vcs_standard_pointer_workspace\+5/s,
   'normalized legal score setup no longer maps little-endian BCD to display slots 0,4,3,2,1,5');
require_re($active,
   qr/lda \(vcs_standard_pointer_workspace\+\$2\),y\s+tax\s+txs\s+lda \(vcs_standard_pointer_workspace\+\$4\),y\s+tax\s+SLEEP 5/s,
   'visible score LAX replacement or five-cycle retiming changed');
$active !~ /^\s*lax\b/im or die "normalized standard renderer still uses LAX\n";
my @score_rows=($renderer_text =~ /^\s*\.byte\s+%[01]{8}\s*$/mg);
@score_rows == 88 or die "normalized score table has " . scalar(@score_rows) . " rows, expected 88\n";

my $object=File::Spec->catfile($tmp,'standard_4k_ntsc_renderer.o26');
my $map=File::Spec->catfile($tmp,'standard_4k_ntsc_renderer.map');
my ($as_exit,$as_sig,$as_out,$as_err)=run_capture(
   $assembler,'-I',$profile,'--map='.$map,'-o',$object,$renderer);
$as_exit == 0 && !$as_sig
   or die "normalized renderer assembly exited $as_exit signal $as_sig\nstdout:\n$as_out\nstderr:\n$as_err";
$as_out eq '' or die "normalized renderer assembly wrote stdout:\n$as_out";
$as_err eq '' or die "normalized renderer assembly wrote stderr:\n$as_err";
my $object_text=read_file($object);
substr($object_text,0,6) eq "\x01\x00o26\x02"
   or die "normalized renderer did not produce a current o26 object\n";
my $map_text=read_file($map);
require_re($map_text,qr/^RENDERER_CODE\s+\$[0-9A-F]{8}\s+\$00000300\b/m,
   'normalized RENDERER_CODE size/alignment changed unexpectedly');
require_re($map_text,qr/^RENDERER_RODATA\s+\$[0-9A-F]{8}\s+\$00000058\b/m,
   'normalized RENDERER_RODATA score table is not 88 bytes');
require_re($map_text,qr/\bvcs_standard_renderer_drawscreen\b/,
   'normalized object map is missing the exported renderer entry');

my $macro_smoke=File::Spec->catfile($tmp,'standard_4k_ntsc_macros_smoke.s26');
write_file($macro_smoke,<<'ASM');
.include "standard_4k_ntsc_macros.inc"
VSYNC = $00
WSYNC = $02
ptr = $80
.segment "CODE"
start:
   SLEEP 3
   VERTICAL_SYNC
   SET_POINTER ptr, target
   CLEAN_START
   RETURN
target:
   NOP
ASM
my $macro_object=File::Spec->catfile($tmp,'standard_4k_ntsc_macros_smoke.o26');
my ($macro_exit,$macro_sig,$macro_out,$macro_err)=run_capture(
   $assembler,'-I',$profile,'-o',$macro_object,$macro_smoke);
$macro_exit == 0 && !$macro_sig
   or die "normalized macro smoke exited $macro_exit signal $macro_sig\nstdout:\n$macro_out\nstderr:\n$macro_err";
$macro_out eq '' or die "normalized macro smoke wrote stdout:\n$macro_out";
$macro_err eq '' or die "normalized macro smoke wrote stderr:\n$macro_err";
my $macro_object_text=read_file($macro_object);
index($macro_object_text,"\x24\x00\xA9\x02") >= 0
   or die "SLEEP 3 did not emit legal BIT \$00 before VERTICAL_SYNC\n";

print "vcs_standard_renderer_normalization ok\n";
