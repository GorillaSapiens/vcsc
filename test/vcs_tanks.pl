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
sub symbol_addr { my($m,$n)=@_; return hex($1) if $m =~ /^\s*\$([0-9A-Fa-f]{4})\s+\Q$n\E\b/m; die "map missing $n\n"; }

my$repo=shift@ARGV//usage();my$tmp=shift@ARGV//usage();usage()if@ARGV;
$repo=abs_path($repo)//die"resolve repo\n";$tmp=abs_path($tmp)//die"resolve tmp\n";
my$driver=File::Spec->catfile($repo,qw(driver vcsc));
my$vcs=File::Spec->catdir($repo,qw(libraries vcs));
my$dir=File::Spec->catdir($repo,qw(examples 01_basic 13_tanks));
my$source=File::Spec->catfile($dir,'tanks.c26');
my$bin=File::Spec->catfile($tmp,'tanks.bin');my$mapfile=File::Spec->catfile($tmp,'tanks.map');
my$s=read_file($source);

for my $line (split /\n/,$s) {
   my $statements=()=($line =~ /;/g);
   $statements<=1 or die "Tanks example must keep one statement per source line\n";
}

$s =~ /include "4K\/mapper\.c26"/ && $s !~ /F8SC\/mapper\.c26|\bcartram\b|\bbank[0-9]+\b/
   or die "Tanks must remain plain unbanked 4K with no cartridge RAM\n";
$s =~ /TANKS_BLACK 0x00/ &&
$s =~ /TANKS_WHITE __builtin_ntsc_rgb\(0xff, 0xff, 0xff\)/ &&
$s =~ /TANKS_BLUE\s+__builtin_ntsc_rgb\(0x20, 0x40, 0xff\)/ &&
$s =~ /TANKS_RED\s+__builtin_ntsc_rgb\(0xff, 0x20, 0x20\)/
   or die "Tanks lost Paddleball palette\n";
$s =~ /instantiate "three_plus_three_score_component\.c26" as score/ &&
$s =~ /score_left_score\+\+/ && $s =~ /score_right_score\+\+/ &&
$s =~ /score_left_color := TANKS_BLUE/ && $s =~ /score_right_color := TANKS_RED/
   or die "Tanks lost the blue\/red 3+3 score\n";

my($graphics_block)=$s =~ /tanks_graphics\[40\] := \{(.*?)\n\};/s;
defined $graphics_block or die "Tanks five-sprite graphics table missing\n";
my @graphics_bits=($graphics_block =~ /0b([.X]{8})/g);
@graphics_bits==40 or die "Tanks must store exactly five 8-byte canonical sprites\n";
my @graphics_lines=grep { /0b[.X]{8}/ } split /\n/,$graphics_block;
@graphics_lines==40 && !grep { !/^\s*0b[.X]{8},?\s*$/ } @graphics_lines
   or die "Tanks canonical graphics must stay one visual byte per line\n";
$s !~ /\btanks_bitmap\b/ or die "Tanks must not expand canonical sprites into a RIOT-RAM bitmap cache\n";
$s =~ /tanks_graphics_descriptor\[16\].*?0x00,0x08,0x10,0x18,0x20,0x1f,0x17,0x0f,\s*0x07,0x8f,0x97,0x9f,0xa0,0x98,0x90,0x88/s &&
$s =~ /tanks_graphics_index_xor\[2\]/ &&
$s =~ /eor\.z tanks_graphics_index_xor \+ 0.*?lda tanks_graphics,y/s &&
$s =~ /eor\.z tanks_graphics_index_xor \+ 1.*?lda tanks_graphics,y/s &&
$s =~ /sta REFP0/ && $s =~ /sta REFP1/
   or die "Tanks lost five-sprite REFP\/forward-backward 16-heading synthesis\n";

$s =~ /TANKS_DIR_NNE := 1/ && $s =~ /TANKS_DIR_NNW := 15/ &&
$s =~ /tank0_direction &= 15/ && $s =~ /tank1_direction &= 15/ &&
$s =~ /tanks_motion\[16\].*?0x50,0x52,0x51,0x61,0x01,0x21,0x11,0x12,\s*0x10,0x16,0x15,0x25,0x05,0x65,0x55,0x56/s &&
$s =~ /void tanks_move_object\(uint8_t object, uint8_t direction\)/
   or die "Tanks lost shared 16-way movement\n";
$s =~ /TANKS_TURN_REPEAT := 23/ && $s =~ /tanks_move_phase\+\+;\s*tanks_move_phase &= 3/ &&
$s =~ /tank0_spin_frames := TANKS_HIT_SPIN_FRAMES/ && $s =~ /tank1_spin_frames := TANKS_HIT_SPIN_FRAMES/
   or die "Tanks lost quarter-rate controls or hit spin\n";

$s =~ /tanks_barrier_event_row\[7\]/ && $s =~ /tanks_barrier_event_pf2\[6\]/ &&
$s =~ /tanks_barrier_event_row\[6\] := 0xff/ &&
$s =~ /tanks_barrier_masks\[8\].*?0x01,0x02,0x04,0x08,0x10,0x20,0x40,0x80/s &&
$s =~ /cmp\.ay tanks_barrier_event_row,y.*?lda\.ay tanks_barrier_event_pf2,y.*?sta PF2/s
   or die "Tanks lost compact six-event pseudo-random barriers\n";

$s =~ /AUDC0 := MUSIC_CONTROL_NOISE/ && $s =~ /AUDF0 := 4/ && $s =~ /AUDF0 := 20/ &&
$s =~ /TANKS_FIRE_SOUND_FRAMES := 4/ && $s =~ /TANKS_HIT_SOUND_FRAMES := 24/ &&
$s =~ /AUDC1 := MUSIC_CONTROL_LOW_BASS/ && $s =~ /AUDF1 := TANKS_ENGINE_FREQ/ &&
$s =~ /AUDV1 := TANKS_ENGINE_VOLUME/ && $s =~ /TANKS_ENGINE_VOLUME := 2/
   or die "Tanks lost fire\/hit effects or engine growl\n";

$s =~ /CXM0P & 0x80/ && $s =~ /CXM1P & 0x80/ &&
$s =~ /CXM0FB & 0x80/ && $s =~ /CXM1FB & 0x80/ &&
$s =~ /CXP0FB & 0x80/ && $s =~ /CXP1FB & 0x80/ && $s =~ /CXPPMM & 0x80/ && $s =~ /CXCLR := _/ &&
$s =~ /tank_pf_escape\[2\]/ && $s =~ /tanks_process_knockback\(void\).*?tanks_update_player_collisions\(\);/s &&
$s =~ /tanks_knockback_delta\[16\].*?0,23,32,23,0,23,32,23.*?16,11,0,11,16,11,0,11/s &&
$s =~ /adc #145|sbc #145/ && $s =~ /adc #75|sbc #75/
   or die "Tanks lost TIA collisions or ~32-pixel wall-wrapping knockback\n";

$s =~ /controls & 0x40/ && $s =~ /controls & 0x80/ && $s =~ /controls & 0x04/ && $s =~ /controls & 0x08/ &&
$s =~ /controls & 0x10/ && $s =~ /controls & 0x20/ && $s =~ /controls & 0x01/ && $s =~ /controls & 0x02/ &&
$s =~ /INPT4 & 0x80/ && $s =~ /INPT5 & 0x80/
   or die "Tanks lost two-joystick direction\/fire mapping\n";
$s =~ /missile0_x := tank0_x \+ 3/ && $s =~ /missile1_x := tank1_x \+ 3/ &&
$s =~ /TANKS_MISSILE_MAX_X := 159/ && $s =~ /TANKS_MISSILE_MAX_Y := 85/ &&
$s =~ /tanks_update_collisions\(\);.*?tanks_process_knockback\(\);.*?tanks_update_overscan\(\);/s
   or die "Tanks lost centered missile launch, bounds, or same-frame collision processing\n";
$s =~ /void tanks_position_missiles\(void\).*?asm sta WSYNC;\s*asm nop;\s*asm lda\.z tanks_x \+ 2;\s*asm clc;\s*asm adc #4;.*?asm sta RESM0;.*?asm sta WSYNC;\s*asm nop;\s*asm lda\.z tanks_x \+ 3;\s*asm clc;\s*asm adc #4;.*?asm sta RESM1;.*?asm sta WSYNC;\s*asm sta HMOVE;/s
   or die "Tanks lost calibrated public-X missile RESP/HMOVE positioning\n";
$s =~ /void tanks_position_players_after_score\(void\).*?tanks_pnext \+ 1.*?tanks_pnext \+ 0.*?sta REFP0.*?sta REFP1/s &&
$s =~ /asm sta GRP0;\s*asm sty GRP1/ && $s =~ /asm cpx #2;.*?asm lda #\$10;\s*asm sta PF0/s &&
$s =~ /PF0 := 0xff;\s*PF1 := 0xff;\s*PF2 := 0xff;\s*WSYNC := _;\s*WSYNC := _;\s*WSYNC := _;\s*WSYNC := _;/ &&
$s =~ /PF0 := 0;\s*PF1 := 0;\s*PF2 := 0;\s*ENAM0 := 0;\s*ENAM1 := 0;\s*WSYNC := _;\s*WSYNC := _;/
   or die "Tanks lost fixed score handoff or 192-line arena geometry\n";

my($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-I',$dir,'-Map',$mapfile,$source,'-o',$bin);
$rc==0&&!$sig or die "Tanks build failed\n$out$err";
-s$bin==4096 or die "Tanks ROM is not plain 4096-byte 4K\n";
my$map=read_file($mapfile);
$map !~ /\bcartram\b|bankcall|region=bank[0-9]/ or die "Tanks map unexpectedly contains banked\/cartridge-RAM state\n$map";

my$cxx=$ENV{CXX}||'c++';my$mos=File::Spec->catdir($repo,qw(simulator mos6502));my$mosobj=File::Spec->catfile($mos,'mos6502.o');my@mos=-f$mosobj?($mosobj):(File::Spec->catfile($mos,'mos6502.cpp'));
my$oracle_src=File::Spec->catfile($repo,qw(test vcs_tanks.cpp));my$oracle=File::Spec->catfile($tmp,'vcs_tanks_oracle');
($rc,$sig,$out,$err)=capture($cxx,'-std=c++17','-Wall','-Wextra','-Werror','-pedantic','-O2','-DILLEGAL_OPCODES','-I',$mos,$oracle_src,@mos,'-o',$oracle);
$rc==0&&!$sig or die"Tanks oracle build failed\n$out$err";

my %a;
my$x=symbol_addr($map,'tanks_x'); @a{qw(tank0_x tank1_x missile0_x missile1_x)}=($x,$x+1,$x+2,$x+3);
my$y=symbol_addr($map,'tanks_y'); @a{qw(tank0_y tank1_y missile0_y missile1_y)}=($y,$y+1,$y+2,$y+3);
my$d=symbol_addr($map,'tanks_direction'); @a{qw(tank0_direction tank1_direction missile0_direction missile1_direction)}=($d,$d+1,$d+2,$d+3);
my$px=symbol_addr($map,'tank_prev_x'); @a{qw(tank0_prev_x tank1_prev_x)}=($px,$px+1);
my$py=symbol_addr($map,'tank_prev_y'); @a{qw(tank0_prev_y tank1_prev_y)}=($py,$py+1);
my$sp=symbol_addr($map,'tank_spin_frames'); @a{qw(tank0_spin_frames tank1_spin_frames)}=($sp,$sp+1);
$a{score_left_score}=symbol_addr($map,'score_left_score'); $a{score_right_score}=symbol_addr($map,'score_right_score');
my$misc=symbol_addr($map,'tanks_misc'); @a{qw(tanks_move_phase tanks_rng tanks_sound_frames tanks_sound_kind)}=($misc,$misc+1,$misc+2,$misc+3);
for my$n(qw(tanks_barrier_event_row tanks_barrier_event_pf2 tanks_graphics tanks_graphics_descriptor tanks_graphics_index_xor)){ $a{$n}=symbol_addr($map,$n); }
my@symbols=qw(tank0_x tank1_x tank0_y tank1_y tank0_direction tank1_direction tank0_prev_x tank1_prev_x tank0_prev_y tank1_prev_y tank0_spin_frames tank1_spin_frames missile0_x missile1_x missile0_y missile1_y missile0_direction missile1_direction score_left_score score_right_score tanks_move_phase tanks_rng tanks_sound_frames tanks_sound_kind tanks_barrier_event_row tanks_barrier_event_pf2 tanks_graphics tanks_graphics_descriptor tanks_graphics_index_xor);
my@addr=map{sprintf('0x%04x',$a{$_})}@symbols;
($rc,$sig,$out,$err)=capture($oracle,$bin,@addr);$rc==0&&!$sig or die"Tanks oracle run failed\n$out$err";
$out eq "vcs_tanks ok: stable early raster writes, visible missiles, 16-way tanks, 3+3 score, engine/fire/hit audio, wall-wrapping knockback, barriers, spin, TIA collisions\n" or die"unexpected Tanks oracle output: $out";
$err eq '' or die"Tanks oracle stderr: $err";
print "vcs_tanks ok\n";
