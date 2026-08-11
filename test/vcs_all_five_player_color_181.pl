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
 ['above',File::Spec->catfile($example_root,qw(01_score_above 01_static all_five_player_color_181_score_above.c26)),4048,42],
 ['below',File::Spec->catfile($example_root,qw(02_score_below 01_static all_five_player_color_181_score_below.c26)),3967,123],
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
   $m =~ /^  ram\s+used=107 bytes .* free=21 bytes/m
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

my$src=read_file($component); my$m=read_file($map{above});
$src =~ /TEMPLATE_VISIBLE_SCANLINES\s*:=\s*181/ or die "visible-line contract changed\n";
$src =~ /TEMPLATE_DRAW_SUCCESSOR_ON_RETURN_LINE\s*:=\s*1/ or die "successor handoff contract changed\n";
$src =~ /TEMPLATE_PLAYFIELD_BYTES\s*:=\s*44/ && $src =~ /TEMPLATE_PLAYFIELD_ROWS\s*:=\s*11/
   or die "181 playfield contract changed\n";
$src =~ /TEMPLATE_WORKSPACE_BYTES\s*:=\s*16/ or die "workspace contract changed\n";
$src =~ /TEMPLATE_PUBLIC_RAM_BYTES\s*:=\s*21/ or die "public RAM contract changed\n";
$src =~ /TEMPLATE_PRIVATE_RAM_BYTES\s*:=\s*60/ or die "private RAM contract changed\n";
$src =~ /TEMPLATE_MODULE_RAM_BYTES\s*:=\s*81/ or die "module RAM contract changed\n";
$src =~ /extern const uint8_t TEMPLATE_player0_colors\[8\]/ &&
$src =~ /extern const uint8_t TEMPLATE_player1_colors\[8\]/
   or die "player color tables missing\n";
$src =~ /uint8_t TEMPLATE_object_masks\[44\]/ && $src =~ /uint8_t TEMPLATE_row_cache\[16\]/
   or die "private mask/cache storage changed\n";
$src =~ /page const uint8_t TEMPLATE_player_position_motion\[15\]/
   or die "compact visible-entry player motion table changed\n";
$src !~ /TEMPLATE_player_position_table\[160\]/
   or die "expanded 160-byte player-position table returned\n";
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
$priv==60 or die "linked private renderer RAM=$priv expected 60\n";
$pub+$priv==81 or die "linked renderer RAM is not 81 bytes\n";

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
}

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
($r,$s,$o,$e)=capture($comp,$cert_bin,'above','static');
$r==0&&!$s or die "score-above object raster failed\n$o$e";
$o eq "vcs_all_five_composition static above ok\n" or die "bad object-raster output: $o";
$e eq '' or die "object-raster stderr: $e";

print "vcs_all_five_player_color_181 ok\n";
