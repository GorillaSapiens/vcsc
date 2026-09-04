#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_all_five_player_color_192 ok
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
sub without_usage { my($o)=@_; $o =~ s/\AMEMORY USAGE\n(?:  [^\n]+\n)+//; return$o; }
sub bss_size { my($m,$n)=@_; $m =~ /^\s+BSS\.__vcsc_object\$\Q$n\E\s+run=\$[0-9A-Fa-f]{4}\s+size=\$([0-9A-Fa-f]{4})\b/m or die "map missing BSS $n\n"; return hex$1; }
sub map_symbol { my($m,$n)=@_; $m =~ /^\s*\$([0-9A-Fa-f]{4})\s+\Q$n\E\b/m or die "map missing $n\n"; my$v=hex$1; $v<=0xff or die "$n not zero page\n"; return$v; }

my$repo=shift@ARGV // usage(); my$tmp=shift@ARGV // usage(); usage() if@ARGV;
$repo=abs_path($repo) or die "resolve repo\n"; $tmp=abs_path($tmp) or die "resolve tmp\n";
my$driver=File::Spec->catfile($repo,qw(driver vcsc));
my$vcs=File::Spec->catdir($repo,qw(libraries vcs));
my$component=File::Spec->catfile($vcs,qw(renderers all_five_player_color_192 all_five_player_color_192.c26));
my$fixture_dir=File::Spec->catdir($repo,qw(test fixtures all_five_player_color_192));
my@jobs=(
 ['smoke','smoke.c26'],
 ['motion','motion.c26'],
 ['vertical','vertical_motion.c26'],
);
my(%bin,%map);
for my$j(@jobs){my($n,$f)=@$j; $bin{$n}=File::Spec->catfile($tmp,"all_five_player_color_192_$n.bin"); $map{$n}=File::Spec->catfile($tmp,"all_five_player_color_192_$n.map"); my($r,$s,$o,$e)=capture($driver,'-I',$vcs,'-Map',$map{$n},File::Spec->catfile($fixture_dir,$f),'-o',$bin{$n}); $r==0&&!$s or die "$n build failed\n$o$e"; without_usage($o) eq ''&&$e eq '' or die "$n build wrote output\n$o$e"; -s$bin{$n}==4096 or die "$n ROM not 4K\n"; }

my$public_example=File::Spec->catfile($repo,qw(examples 15_all_five_player_color_192 01_interactive all_five_player_color_192_interactive.c26));
my$public_src=read_file($public_example);
$public_src =~ /instantiate "renderers\/all_five_player_color_192\/all_five_player_color_192\.c26" as game/
   or die "public example does not instantiate combined renderer
";
$public_src =~ /page const uint8_t game_player0_colors\[8\]/ &&
$public_src =~ /page const uint8_t game_player1_colors\[8\]/
   or die "public example lost player color tables
";
$public_src =~ /SELECTED_OBJECT_COUNT\s+5/ &&
$public_src =~ /SELECTED_MISSILE0/ && $public_src =~ /SELECTED_MISSILE1/ && $public_src =~ /SELECTED_BALL/
   or die "public example no longer selects all five objects
";
my$public_bin=File::Spec->catfile($tmp,'all_five_player_color_192_interactive.bin');
my$public_map=File::Spec->catfile($tmp,'all_five_player_color_192_interactive.map');
my($pr,$ps,$po,$pe)=capture($driver,'-I',$vcs,'-Map',$public_map,$public_example,'-o',$public_bin);
$pr==0&&!$ps or die "public example build failed
$po$pe";
without_usage($po) eq ''&&$pe eq '' or die "public example build wrote output
$po$pe";
-s$public_bin==4096 or die "public example ROM not 4K
";
my$public_map_text=read_file($public_map);
$public_map_text =~ /^  rom\s+used=3590 bytes .* free=500 bytes/m
   or die "public example ROM footprint changed
";
$public_map_text =~ /^  ram\s+used=97 bytes .* free=31 bytes/m
   or die "public example RAM footprint changed
";

my$src=read_file($component); my$m=read_file($map{smoke});
$src =~ /TEMPLATE_VISIBLE_SCANLINES\s*:=\s*192/ or die "visible-line contract changed\n";
$src =~ /TEMPLATE_PUBLIC_RAM_BYTES\s*:=\s*21/ or die "public RAM contract changed\n";
$src =~ /TEMPLATE_PRIVATE_RAM_BYTES\s*:=\s*62/ or die "private RAM contract changed\n";
$src =~ /TEMPLATE_MODULE_RAM_BYTES\s*:=\s*83/ or die "module RAM contract changed\n";
$src =~ /extern const uint8_t TEMPLATE_player0_colors\[8\]/ or die "P0 color table missing\n";
$src =~ /extern const uint8_t TEMPLATE_player1_colors\[8\]/ or die "P1 color table missing\n";
$src =~ /uint8_t TEMPLATE_row_cache\[14\]/ or die "14-byte row cache changed\n";
$src =~ /asm bcc\.same \@TEMPLATE_A_u7_p0_active;/ or die "A pair-7 fixed color handoff missing\n";
$src =~ /asm bcc\.same \@TEMPLATE_B_u7_p0_active;/ or die "B pair-7 fixed color handoff missing\n";
my$code=$src; $code =~ s{//[^\n]*}{}g; $code =~ s{/\*.*?\*/}{}gs;
$code !~ /\b(?:lax|dcp|sax|isc|isb|rla|rra|slo|sre|anc|alr|arr|axs|xaa|ahx|shx|shy|tas|las)\b/i or die "official renderer contains unofficial opcode\n";
my@public=qw(game_object_x game_player0_y game_player1_y game_missile1_height game_missile1_y game_ball_y game_player0_graphics game_player1_graphics game_player0_height game_player1_height game_missile0_height game_missile0_y game_ball_height game_player0_nusiz game_player1_nusiz);
my@private=qw(game_object_masks game_row_cache);
my$pub=0;$pub+=bss_size($m,$_) for@public; my$priv=0;$priv+=bss_size($m,$_) for@private;
$pub==21 or die "linked public RAM=$pub expected 21\n"; $priv==62 or die "linked private RAM=$priv expected 62\n";

my$cxx=$ENV{CXX}||'c++'; my$mos=File::Spec->catdir($repo,qw(simulator mos6502)); my$mo=File::Spec->catfile($mos,'mos6502.o'); my@mi=-f$mo?($mo):(File::Spec->catfile($mos,'mos6502.cpp'));
my$timing=File::Spec->catfile($tmp,'afpc192_timing'); my($r,$s,$o,$e)=capture($cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,File::Spec->catfile($repo,qw(test vcs_frame_timing.cpp)),@mi,'-o',$timing); $r==0&&!$s or die "timing harness build failed\n$o$e";
($r,$s,$o,$e)=capture($timing,$bin{smoke},'50','--no-audio','--raw-lines','264'); $r==0&&!$s or die "static timing failed\n$o$e"; $o eq "vcs_frame_timing ok: 47 frames at 262 lines, 1 AUDV0 writes\n" or die "bad static timing: $o";
($r,$s,$o,$e)=capture($timing,$bin{vertical},'300','--no-audio','--raw-lines','264'); $r==0&&!$s or die "vertical sweep timing failed\n$o$e"; $o eq "vcs_frame_timing ok: 297 frames at 262 lines, 1 AUDV0 writes\n" or die "bad vertical timing: $o";

my$comp=File::Spec->catfile($tmp,'afpc192_composition'); ($r,$s,$o,$e)=capture($cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,File::Spec->catfile($repo,qw(test vcs_all_five_composition.cpp)),@mi,'-o',$comp); $r==0&&!$s or die "composition harness build failed\n$o$e";
($r,$s,$o,$e)=capture($comp,$bin{smoke},'none','static'); $r==0&&!$s or die "static object raster failed\n$o$e"; $o eq "vcs_all_five_composition static none ok\n" or die "bad static object output: $o";
my$mm=read_file($map{motion}); my@a=(map_symbol($mm,'game_object_x'),map_symbol($mm,'game_player0_y'),map_symbol($mm,'game_player1_y'),map_symbol($mm,'game_missile0_y'),map_symbol($mm,'game_missile1_y'),map_symbol($mm,'game_ball_y'),map_symbol($mm,'motion_frame'));
($r,$s,$o,$e)=capture($comp,$bin{motion},'none','motion',@a); $r==0&&!$s or die "full-range motion failed\n$o$e"; $o eq "vcs_all_five_composition motion none ok\n" or die "bad motion output: $o";

print "vcs_all_five_player_color_192 ok\n";
