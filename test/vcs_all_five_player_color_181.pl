#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 30
# expectstdout: vcs_all_five_player_color_181 ok
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub usage { die "usage: $0 REPO TMP\n"; }
sub slurp_fh { my($fh)=@_; local $/; return <$fh> // ''; }
sub capture { my(@cmd)=@_; my$err=gensym; my$pid=open3(my$in,my$out,$err,@cmd); close$in; my$so=slurp_fh($out); my$se=slurp_fh($err); waitpid($pid,0); return($?>>8,$?&127,$so,$se); }
sub read_file { my($p)=@_; open(my$f,'<:raw',$p) or die "read $p: $!\n"; local$/; my$d=<$f>//''; close$f; return$d; }
sub write_file { my($p,$d)=@_; open(my$f,'>:raw',$p) or die "write $p: $!\n"; print{$f}$d; close$f or die "close $p: $!\n"; }
sub without_usage { my($o)=@_; $o =~ s/\AMEMORY USAGE\n(?:  [^\n]+\n)+//; return$o; }
sub bss_size { my($m,$n)=@_; $m =~ /^\s+BSS\.__vcsc_object\$\Q$n\E\s+run=\$[0-9A-Fa-f]{4}\s+size=\$([0-9A-Fa-f]{4})\b/m or die "map missing BSS $n\n"; return hex$1; }

my$repo=shift@ARGV // usage(); my$tmp=shift@ARGV // usage(); usage() if@ARGV;
$repo=abs_path($repo) or die "resolve repo\n"; $tmp=abs_path($tmp) or die "resolve tmp\n";
my$driver=File::Spec->catfile($repo,qw(driver vcsc));
my$vcs=File::Spec->catdir($repo,qw(libraries vcs));
my$cfg=File::Spec->catfile($vcs,qw(renderers standard_4k_ntsc vcs_standard_4k_ntsc.cfg));
my$component=File::Spec->catfile($vcs,qw(renderers all_five_player_color_181 all_five_player_color_181.c26));
my$example_root=File::Spec->catdir($repo,qw(examples 16_all_five_player_color_181));
my@jobs=(
 ['above',File::Spec->catfile($example_root,qw(01_score_above 01_static all_five_player_color_181_score_above.c26)),3754,336],
 ['below',File::Spec->catfile($example_root,qw(02_score_below 01_static all_five_player_color_181_score_below.c26)),3754,336],
);
my(%bin,%map,%source);
for my$j(@jobs){
   my($n,$src,$rom_used,$rom_free)=@$j;
   $source{$n}=read_file($src);
   $bin{$n}=File::Spec->catfile($tmp,"all_five_player_color_181_$n.bin");
   $map{$n}=File::Spec->catfile($tmp,"all_five_player_color_181_$n.map");
   my($r,$s,$o,$e)=capture($driver,'-I',$vcs,'-T',$cfg,'-Map',$map{$n},$src,'-o',$bin{$n});
   $r==0&&!$s or die "$n public example build failed\n$o$e";
   without_usage($o) eq ''&&$e eq '' or die "$n public example build wrote output\n$o$e";
   -s$bin{$n}==4096 or die "$n public example is not 4K\n";
   my$m=read_file($map{$n});
   $m =~ /^  [Rr][Oo][Mm]\s+used=\Q$rom_used\E bytes .* free=\Q$rom_free\E bytes/m
      or die "$n public example ROM footprint changed\n";
   $m =~ /^  ram\s+used=114 bytes .* free=14 bytes/m
      or die "$n public example RAM footprint changed\n";
   $source{$n} =~ /instantiate "renderers\/all_five_player_color_181\/all_five_player_color_181\.c26" as game/
      or die "$n public example does not instantiate the combined 181 renderer\n";
   $source{$n} =~ /page const uint8_t game_player0_colors\[8\]/ &&
   $source{$n} =~ /page const uint8_t game_player1_colors\[8\]/
      or die "$n public example lost player color tables\n";
   $source{$n} =~ /score_score\s*:=\s*123456;/
      or die "$n public example lost fixed score\n";
}
$source{above} =~ /score_draw\(\);\s*vcs_ntsc_component_handoff\(\);\s*game_draw\(\);/s
   or die "score-above example lost component order\n";
$source{below} =~ /game_draw\(\);\s*vcs_ntsc_component_handoff\(\);\s*score_draw\(\);/s
   or die "score-below example lost component order\n";

my$interactive_common=File::Spec->catfile($repo,qw(examples common all_five_player_color_181_interactive_common.c26));
my$interactive_common_text=read_file($interactive_common);
my$canonical_181_common=read_file(File::Spec->catfile($repo,qw(examples common all_five_181_interactive_common.c26)));
sub playfield_rows {
   my($text)=@_;
   my@rows=($text =~ /(VCS_PLAYFIELD_ROW\([^\n]+\))/g);
   return join("\n",@rows);
}
my$canonical_playfield=playfield_rows($canonical_181_common);
$canonical_playfield ne '' or die "canonical 181 common playfield rows missing\n";
playfield_rows($interactive_common_text) eq $canonical_playfield
   or die "181 combined interactive playfield diverged from canonical all-five 181 pattern\n";
for my$n(qw(above below)) {
   playfield_rows($source{$n}) eq $canonical_playfield
      or die "$n static 181 combined playfield diverged from canonical all-five 181 pattern\n";
}
$interactive_common_text =~ /Game Select cycles P0, P1, M0, M1, Ball/ &&
$interactive_common_text =~ /game_object_x\[selected_object\]/ &&
$interactive_common_text =~ /object_y\[selected_object\]/ &&
$interactive_common_text =~ /score_score\s*:=\s*123456;/
   or die "181 combined interactive controls changed\n";
my@interactive_jobs=(
 ['above',File::Spec->catfile($example_root,qw(01_score_above 02_interactive all_five_player_color_181_score_above_interactive.c26))],
 ['below',File::Spec->catfile($example_root,qw(02_score_below 02_interactive all_five_player_color_181_score_below_interactive.c26))],
);
my(%interactive_bin,%interactive_source);
for my$j(@interactive_jobs){
   my($n,$isrc)=@$j;
   $interactive_source{$n}=read_file($isrc);
   $interactive_bin{$n}=File::Spec->catfile($tmp,"all_five_player_color_181_${n}_interactive.bin");
   my$imap=File::Spec->catfile($tmp,"all_five_player_color_181_${n}_interactive.map");
   my($r,$s,$o,$e)=capture($driver,'-I',$vcs,'-T',$cfg,'-Map',$imap,$isrc,'-o',$interactive_bin{$n});
   $r==0&&!$s or die "$n interactive example build failed\n$o$e";
   without_usage($o) eq ''&&$e eq '' or die "$n interactive example build wrote output\n$o$e";
   -s$interactive_bin{$n}==4096 or die "$n interactive example is not 4K\n";
   my$im=read_file($imap);
   $im =~ /^  [Rr][Oo][Mm]\s+used=4058 bytes .* free=32 bytes/m
      or die "$n interactive example ROM footprint changed\n";
   $im =~ /^  ram\s+used=123 bytes .* free=5 bytes/m
      or die "$n interactive example RAM footprint changed\n";
   $interactive_source{$n} =~ /include "\.\.\/\.\.\/\.\.\/common\/all_five_player_color_181_interactive_common\.c26"/
      or die "$n interactive example lost shared controls\n";
}
$interactive_source{above} =~ /score_draw\(\);\s*vcs_ntsc_component_handoff\(\);\s*game_draw\(\);/s
   or die "interactive score-above example lost component order\n";
$interactive_source{below} =~ /game_draw\(\);\s*vcs_ntsc_component_handoff\(\);\s*score_draw\(\);/s
   or die "interactive score-below example lost component order\n";

my$src=read_file($component); my$m=read_file($map{above});
$src =~ /TEMPLATE_VISIBLE_SCANLINES\s*:=\s*181/ or die "visible-line contract changed\n";
$src =~ /TEMPLATE_DRAW_SUCCESSOR_ON_RETURN_LINE\s*:=\s*1/ or die "successor handoff contract changed\n";
$src =~ /TEMPLATE_PLAYFIELD_BYTES\s*:=\s*44/ && $src =~ /TEMPLATE_PLAYFIELD_ROWS\s*:=\s*11/
   or die "181 playfield contract changed\n";
$src =~ /TEMPLATE_WORKSPACE_BYTES\s*:=\s*21/ or die "workspace contract changed\n";
$src =~ /TEMPLATE_PUBLIC_RAM_BYTES\s*:=\s*21/ or die "public RAM contract changed\n";
$src =~ /TEMPLATE_PRIVATE_RAM_BYTES\s*:=\s*67/ or die "private RAM contract changed\n";
$src =~ /TEMPLATE_MODULE_RAM_BYTES\s*:=\s*88/ or die "module RAM contract changed\n";
$src =~ /extern const uint8_t TEMPLATE_player0_colors\[8\]/ &&
$src =~ /extern const uint8_t TEMPLATE_player1_colors\[8\]/
   or die "player color tables missing\n";
$src =~ /uint8_t TEMPLATE_object_masks\[46\]/ && $src =~ /uint8_t TEMPLATE_row_cache\[21\]/
   or die "private mask/cache storage changed\n";
$src =~ /page const uint8_t TEMPLATE_reposition_table\[16\]/ &&
$src =~ /\@TEMPLATE_prepare_player_position/ &&
$src =~ /asm cpy #\$fe;.*?asm inx;.*?asm sbc #\$70;/s &&
$src =~ /asm cpy #\$f1;.*?asm sbc #\$60;/s
   or die "score-safe visible-entry player positioning changed\n";
$src !~ /TEMPLATE_player_position_table\[160\]/ &&
$src !~ /TEMPLATE_player_handoff_hmp\[16\]/
   or die "redundant/expanded player-position table returned\n";
$src =~ /asm tsx;.*?asm stx\.z TEMPLATE_row_cache \+ 20;/s &&
$src =~ /asm ldx\.z TEMPLATE_row_cache \+ 20;\s*asm txs;/s
   or die "stack-rowbase save/restore changed\n";
$src =~ /asm bit\.z TEMPLATE_row_cache \+ 19;\s*asm bpl\.same \@TEMPLATE_player1_position_entry;/s &&
$src =~ /asm bit\.z TEMPLATE_row_cache \+ 18;\s*asm bpl\.same \@TEMPLATE_player0_position_entry;/s
   or die "one-cycle player RESP gap correction changed\n";
$src =~ /sta ENABL;.*?sta GRP1;.*?sta VDELBL;/s
   or die "terminal path no longer flushes delayed Ball zero through GRP1\n";
my$code=$src; $code =~ s{//[^\n]*}{}g; $code =~ s{/\*.*?\*/}{}gs;
$code !~ /\b(?:lax|dcp|sax|isc|isb|rla|rra|slo|sre|anc|alr|arr|axs|xaa|ahx|shx|shy|tas|las)\b/i
   or die "official 181 combined renderer contains unofficial opcode\n";
$code !~ /\b(?:VSYNC|VBLANK|TIM1T|TIM8T|TIM64T|T1024T|INTIM|TIMINT)\b/
   or die "181 combined renderer touches scheduler-owned frame/timer state\n";

my@public=qw(game_object_x game_player0_y game_player1_y game_missile1_height game_missile1_y game_ball_y game_player0_graphics game_player1_graphics game_player0_height game_player1_height game_missile0_height game_missile0_y game_ball_height game_player0_nusiz game_player1_nusiz);
my@private=qw(game_object_masks game_row_cache);
my$pub=0;$pub+=bss_size($m,$_) for@public; my$priv=0;$priv+=bss_size($m,$_) for@private;
$pub==21 or die "linked public renderer RAM=$pub expected 21\n";
$priv==67 or die "linked private renderer RAM=$priv expected 67\n";
$pub+$priv==88 or die "linked renderer RAM is not 88 bytes\n";

my$cxx=$ENV{CXX}||'c++'; my$mos=File::Spec->catdir($repo,qw(simulator mos6502)); my$mo=File::Spec->catfile($mos,'mos6502.o'); my@mi=-f$mo?($mo):(File::Spec->catfile($mos,'mos6502.cpp'));
my$timing=File::Spec->catfile($tmp,'afpc181_timing');
my($r,$s,$o,$e)=capture($cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,File::Spec->catfile($repo,qw(test vcs_frame_timing.cpp)),@mi,'-o',$timing);
$r==0&&!$s or die "timing harness build failed\n$o$e";
for my$n(qw(above below)){
   ($r,$s,$o,$e)=capture($timing,$bin{$n},'50','--no-audio','--raw-lines','264');
   $r==0&&!$s or die "$n frame timing failed\n$o$e";
   $o eq "vcs_frame_timing ok: 47 frames at 262 lines, 0 AUDV0 writes\n"
      or die "bad $n frame timing output: $o";
   $e eq '' or die "$n frame timing stderr: $e";
   ($r,$s,$o,$e)=capture($timing,$interactive_bin{$n},'50','--no-audio','--raw-lines','264');
   $r==0&&!$s or die "$n interactive frame timing failed\n$o$e";
   $o eq "vcs_frame_timing ok: 47 frames at 262 lines, 0 AUDV0 writes\n"
      or die "bad $n interactive frame timing output: $o";
   $e eq '' or die "$n interactive frame timing stderr: $e";
}

# Sweep all five Y coordinates through the complete byte range.  This locks the
# active/inactive selector balance and the temporary S-as-row-base scheme across
# every row-boundary phase rather than certifying only one static scene.
my$vertical=$source{above};
$vertical =~ s/(vcs_ntsc_begin_vblank\(\);\s*)/$1      asm inc.z game_player0_y;\n      asm dec.z game_player1_y;\n      asm inc.z game_missile0_y;\n      asm dec.z game_missile1_y;\n      asm inc.z game_ball_y;\n/s
   or die "could not create 181 vertical sweep fixture\n";
my$vertical_src=File::Spec->catfile($tmp,'afpc181_vertical.c26');
my$vertical_bin=File::Spec->catfile($tmp,'afpc181_vertical.bin');
write_file($vertical_src,$vertical);
($r,$s,$o,$e)=capture($driver,'-I',$vcs,'-T',$cfg,$vertical_src,'-o',$vertical_bin);
$r==0&&!$s or die "vertical sweep build failed\n$o$e";
without_usage($o) eq ''&&$e eq '' or die "vertical sweep build wrote output\n$o$e";
($r,$s,$o,$e)=capture($timing,$vertical_bin,'300','--no-audio','--raw-lines','264');
$r==0&&!$s or die "vertical sweep timing failed\n$o$e";
$o eq "vcs_frame_timing ok: 297 frames at 262 lines, 0 AUDV0 writes\n"
   or die "bad vertical sweep timing output: $o";
$e eq '' or die "vertical sweep timing stderr: $e";

# Sweep both players through every supported horizontal coordinate. The public
# controls clamp at 0..159; keep incrementing until 159 and then hold there so
# the maximum coarse-position path is exercised repeatedly without wrapping to
# unsupported byte values. Physical one-pixel continuity is checked in Stella.
my$horizontal=$source{above};
$horizontal =~ s/game_PLAYER0_X\s*:=\s*20;/game_PLAYER0_X := 0;/ or die "could not reset P0 X for horizontal sweep\n";
$horizontal =~ s/game_PLAYER1_X\s*:=\s*130;/game_PLAYER1_X := 0;/ or die "could not reset P1 X for horizontal sweep\n";
$horizontal =~ s/(vcs_ntsc_begin_vblank\(\);\s*)/$1      if (game_object_x[0] < 159) { game_object_x[0]++; }\n      if (game_object_x[1] < 159) { game_object_x[1]++; }\n/s
   or die "could not create 181 horizontal sweep fixture\n";
my$horizontal_src=File::Spec->catfile($tmp,'afpc181_horizontal.c26');
my$horizontal_bin=File::Spec->catfile($tmp,'afpc181_horizontal.bin');
write_file($horizontal_src,$horizontal);
($r,$s,$o,$e)=capture($driver,'-I',$vcs,'-T',$cfg,$horizontal_src,'-o',$horizontal_bin);
$r==0&&!$s or die "horizontal sweep build failed\n$o$e";
without_usage($o) eq ''&&$e eq '' or die "horizontal sweep build wrote output\n$o$e";
($r,$s,$o,$e)=capture($timing,$horizontal_bin,'180','--no-audio','--raw-lines','264');
$r==0&&!$s or die "horizontal sweep timing failed\n$o$e";
$o eq "vcs_frame_timing ok: 177 frames at 262 lines, 0 AUDV0 writes\n"
   or die "bad horizontal sweep timing output: $o";
$e eq '' or die "horizontal sweep timing stderr: $e";

# Reuse the established all-five 181 score-above certification scene with
# constant row colors. This makes the independent all-five object oracle check
# the new component without depending on the public example's decorative glyphs.
my$cert=read_file(File::Spec->catfile($repo,qw(test fixtures all_five_181 static_score_above.c26)));
$cert =~ s/instantiate "renderers\/all_five\/all_five\.c26" as game \(lines:=181\)/page const uint8_t game_player0_colors[8] := { 0x0e,0x0e,0x0e,0x0e,0x0e,0x0e,0x0e,0x0e };\npage const uint8_t game_player1_colors[8] := { 0xc8,0xc8,0xc8,0xc8,0xc8,0xc8,0xc8,0xc8 };\ninstantiate "renderers\/all_five_player_color_181\/all_five_player_color_181.c26" as game/
   or die "could not retarget certification fixture\n";
$cert =~ s/^\s*game_player0_color\s*:=\s*0x0e;\s*\n//m or die "could not remove certification P0 solid color\n";
$cert =~ s/^\s*game_player1_color\s*:=\s*0xc8;\s*\n//m or die "could not remove certification P1 solid color\n";
$cert =~ s/^\s*game_playfield_position\s*:=\s*8;\s*\n//m or die "could not remove certification playfield position\n";
my$cert_src=File::Spec->catfile($tmp,'afpc181_cert_above.c26'); my$cert_bin=File::Spec->catfile($tmp,'afpc181_cert_above.bin');
write_file($cert_src,$cert);
($r,$s,$o,$e)=capture($driver,'-I',$vcs,'-T',$cfg,$cert_src,'-o',$cert_bin);
$r==0&&!$s or die "certification fixture build failed\n$o$e";
without_usage($o) eq ''&&$e eq '' or die "certification fixture build wrote output\n$o$e";
my$comp=File::Spec->catfile($tmp,'afpc181_composition');
($r,$s,$o,$e)=capture($cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,File::Spec->catfile($repo,qw(test vcs_all_five_composition.cpp)),@mi,'-o',$comp);
$r==0&&!$s or die "composition harness build failed\n$o$e";
($r,$s,$o,$e)=capture($comp,$cert_bin,'above','static','post-resp-player');
$r==0&&!$s or die "score-above object raster failed\n$o$e";
$o eq "vcs_all_five_composition static above ok\n" or die "bad object-raster output: $o";
$e eq '' or die "object-raster stderr: $e";

print "vcs_all_five_player_color_181 ok\n";
