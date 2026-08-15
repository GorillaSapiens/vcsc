#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 45
# expectstdout: vcs_tanks ok
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub usage { die "usage: $0 REPO TMP\n"; }
sub slurp_fh { my($f)=@_; local $/; return <$f> // ''; }
sub capture { my(@c)=@_; my$e=gensym; my$p=open3(my$i,my$o,$e,@c);close$i;my$so=slurp_fh($o);my$se=slurp_fh($e);waitpid($p,0);return($?>>8,$?&127,$so,$se); }
sub read_file { my($p)=@_;open(my$f,'<:raw',$p)or die"read $p: $!\n";local$/;my$d=<$f>;close$f;return$d//''; }
sub symbol_addr { my($m,$n)=@_; return hex($1) if $m =~ /\$([0-9A-Fa-f]{4})\s+\Q$n\E\b/; die "map missing $n\n"; }

my$repo=shift@ARGV//usage();my$tmp=shift@ARGV//usage();usage()if@ARGV;
$repo=abs_path($repo)//die"resolve repo\n";$tmp=abs_path($tmp)//die"resolve tmp\n";
my$driver=File::Spec->catfile($repo,qw(driver vcsc));
my$vcs=File::Spec->catdir($repo,qw(libraries vcs));
my$dir=File::Spec->catdir($repo,qw(examples 01_basic 13_tanks));
my$source=File::Spec->catfile($dir,'tanks.c26');
my$bin=File::Spec->catfile($tmp,'tanks.bin');my$mapfile=File::Spec->catfile($tmp,'tanks.map');
my$s=read_file($source);

$s =~ /TANKS_BLACK 0x00/ &&
$s =~ /TANKS_WHITE __builtin_ntsc_rgb\(0xff, 0xff, 0xff\)/ &&
$s =~ /TANKS_BLUE\s+__builtin_ntsc_rgb\(0x20, 0x40, 0xff\)/ &&
$s =~ /TANKS_RED\s+__builtin_ntsc_rgb\(0xff, 0x20, 0x20\)/
   or die "Tanks lost Paddleball palette\n";
$s =~ /instantiate "three_plus_three_score_component\.c26" as score/ &&
$s =~ /score_left_score\+\+/ && $s =~ /score_right_score\+\+/ &&
$s =~ /score_left_color := TANKS_BLUE/ && $s =~ /score_right_color := TANKS_RED/
   or die "Tanks lost the blue\/red score\n";
$s =~ /TANKS_TURN_REPEAT := 23/ && $s =~ /tanks_move_phase &= 3/ &&
$s =~ /tank0_spin_frames := TANKS_HIT_SPIN_FRAMES/ && $s =~ /tank1_spin_frames := TANKS_HIT_SPIN_FRAMES/
   or die "Tanks lost quarter-rate controls or hit-spin behavior\n";
$s =~ /AUDC0 := MUSIC_CONTROL_NOISE/ && $s =~ /AUDF0 := 4/ && $s =~ /AUDF0 := 20/ &&
$s =~ /TANKS_FIRE_SOUND_FRAMES := 4/ && $s =~ /TANKS_HIT_SOUND_FRAMES := 24/
   or die "Tanks lost distinct fire\/hit noise effects\n";
$s =~ /include "vcs_8k_f8sc\.c26"/ && $s =~ /superchip uint8_t tanks_barrier_pf2\[86\]/ &&
$s =~ /tanks_barrier_masks\[8\].*?0x01,0x02,0x04,0x08,0x10,0x20,0x40,0x80/s &&
$s =~ /asm lda\.ax tanks_barrier_pf2,x/ && $s =~ /asm sta PF2/ &&
$s =~ /start := 10 \+ \(r & 7\)/ && $s =~ /end := start \+ 14/
   or die "Tanks lost vertical pseudo-random playfield barriers\n";
$s =~ /asm sta GRP0;.*?asm sty GRP1;.*?asm cpx #2;.*?asm lda #\$10;\s*asm sta PF0;\s*asm lda #0;\s*asm sta PF1;\s*asm sta PF2;/s &&
$s =~ /asm cpx #86;\s*asm beq\.same \@done;/ &&
$s =~ /tanks_draw\(\);.*?PF0 := 0xff;\s*PF1 := 0xff;\s*PF2 := 0xff;\s*WSYNC := 0;\s*WSYNC := 0;\s*WSYNC := 0;\s*WSYNC := 0;/s &&
$s =~ /CTRLPF := 0x01/
   or die "Tanks lost early side-wall or dedicated 4-scanline bottom-wall geometry\n";
$s =~ /adc #<tanks_graphics/ && $s =~ /tanks_player_position_table\[160\]/ &&
$s =~ /tanks_prepare_player_positions/ && $s =~ /tanks_player_position_control\[2\]/ &&
$s =~ /tanks_draw\(\);.*?PF0 := 0;\s*PF1 := 0;\s*PF2 := 0;.*?WSYNC := 0;\s*WSYNC := 0;/s
   or die "Tanks lost corrected sprite-base or fixed-time player positioning\n";
$s =~ /CXM0P & 0x80/ && $s =~ /CXM1P & 0x80/ &&
$s =~ /CXM0FB & 0x80/ && $s =~ /CXM1FB & 0x80/ &&
$s =~ /CXP0FB & 0x80/ && $s =~ /CXP1FB & 0x80/ && $s =~ /CXPPMM & 0x80/ && $s =~ /CXCLR := 0/ &&
$s =~ /tanks_update_overscan\(void\).*?tanks_update_player_collisions\(\);.*?tanks_update_controls\(\);/s
   or die "Tanks must consume player\/playfield and player\/player collisions before controls overwrite the undo position\n";
$s =~ /controls & 0x40/ && $s =~ /controls & 0x80/ && $s =~ /controls & 0x04/ && $s =~ /controls & 0x08/ &&
$s =~ /controls & 0x10/ && $s =~ /controls & 0x20/ && $s =~ /controls & 0x01/ && $s =~ /controls & 0x02/ &&
$s =~ /INPT4 & 0x80/ && $s =~ /INPT5 & 0x80/
   or die "Tanks lost two-joystick direction\/fire mapping\n";

my($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-I',$dir,'-T',File::Spec->catfile($vcs,'vcs.cfg'),'-Map',$mapfile,$source,'-o',$bin);
$rc==0&&!$sig or die "Tanks build failed\n$out$err";
-s$bin==8192 or die "Tanks ROM is not 8192-byte F8SC\n";
my$map=read_file($mapfile);

my$cxx=$ENV{CXX}||'c++';my$mos=File::Spec->catdir($repo,qw(simulator mos6502));my$mosobj=File::Spec->catfile($mos,'mos6502.o');my@mos=-f$mosobj?($mosobj):(File::Spec->catfile($mos,'mos6502.cpp'));
my$oracle_src=File::Spec->catfile($repo,qw(test vcs_tanks.cpp));my$oracle=File::Spec->catfile($tmp,'vcs_tanks_oracle');
($rc,$sig,$out,$err)=capture($cxx,'-std=c++17','-Wall','-Wextra','-Werror','-pedantic','-O2','-DILLEGAL_OPCODES','-I',$mos,$oracle_src,@mos,'-o',$oracle);
$rc==0&&!$sig or die"Tanks oracle build failed\n$out$err";
my@symbols=qw(tank0_x tank1_x tank0_y tank1_y tank0_direction tank1_direction tank0_graphics tank1_graphics tank0_prev_x tank1_prev_x tank0_prev_y tank1_prev_y tank0_spin_frames tank1_spin_frames missile0_x missile1_x missile0_y missile1_y missile0_direction missile1_direction missile0_active missile1_active score_left_score score_right_score tanks_move_phase tanks_rng tanks_sound_frames tanks_sound_kind tanks_barrier_pf2 tanks_graphics);
my@addr=map{sprintf('0x%04x',symbol_addr($map,$_))}@symbols;
($rc,$sig,$out,$err)=capture($oracle,$bin,@addr);$rc==0&&!$sig or die"Tanks oracle run failed\n$out$err";
$out eq "vcs_tanks ok: stable early raster writes, visible missiles, oriented tanks, 3+3 score, barriers, audio/spin, TIA collisions\n" or die"unexpected Tanks oracle output: $out";
$err eq '' or die"Tanks oracle stderr: $err";
print "vcs_tanks ok\n";
