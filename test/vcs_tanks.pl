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
$s =~ /TANKS_DIR_NNE := 1/ && $s =~ /TANKS_DIR_NNW := 15/ &&
$s =~ /tank0_direction &= 15/ && $s =~ /tank1_direction &= 15/ &&
$s =~ /tank0_spin_frames := TANKS_HIT_SPIN_FRAMES/ && $s =~ /tank1_spin_frames := TANKS_HIT_SPIN_FRAMES/
   or die "Tanks lost quarter-rate controls or hit-spin behavior\n";
$s =~ /AUDC0 := MUSIC_CONTROL_NOISE/ && $s =~ /AUDF0 := 4/ && $s =~ /AUDF0 := 20/ &&
$s =~ /TANKS_FIRE_SOUND_FRAMES := 4/ && $s =~ /TANKS_HIT_SOUND_FRAMES := 24/ &&
$s =~ /AUDC1 := MUSIC_CONTROL_LOW_BASS/ && $s =~ /AUDF1 := TANKS_ENGINE_FREQ/ &&
$s =~ /AUDV1 := TANKS_ENGINE_VOLUME/ && $s =~ /TANKS_ENGINE_VOLUME := 2/
   or die "Tanks lost fire\/hit effects or low-volume engine growl\n";
$s =~ /include "vcs_8k_f8sc\.c26"/ && $s =~ /cartram uint8_t tanks_barrier_pf2\[86\]/ &&
$s !~ /\bbank[0-9]+\b/ &&
$s =~ /tanks_barrier_masks\[8\].*?0x01,0x02,0x04,0x08,0x10,0x20,0x40,0x80/s &&
$s =~ /asm lda\.ax tanks_barrier_pf2,x/ && $s =~ /asm sta PF2/ &&
$s =~ /r := tanks_random\(\) & 3/ && $s =~ /if \(r == 3\) \{ r := 1; \}/ &&
$s =~ /start := 12 \+ r/ && $s =~ /start := 36 \+ r/ &&
$s =~ /start := 60 \+ r/ && $s =~ /end := start \+ 14/ &&
$s =~ /mask := tanks_random\(\);\s*mask := tanks_barrier_masks\[\(mask >> 3\) & 7\]/
   or die "Tanks lost balanced pseudo-random playfield barriers\n";
$s =~ /asm sta GRP0;.*?asm sty GRP1;.*?asm cpx #2;.*?asm lda #\$10;\s*asm sta PF0;\s*asm lda #0;\s*asm sta PF1;\s*asm sta PF2;/s &&
$s =~ /asm cpx #86;\s*asm beq\.same \@done;/ &&
$s =~ /tanks_draw\(\);.*?PF0 := 0xff;\s*PF1 := 0xff;\s*PF2 := 0xff;\s*WSYNC := 0;\s*WSYNC := 0;\s*WSYNC := 0;\s*WSYNC := 0;/s &&
$s =~ /CTRLPF := 0x01/
   or die "Tanks lost early side-wall or dedicated 4-scanline bottom-wall geometry\n";
$s =~ /tank0_graphics := tanks_graphics;\s*tank0_graphics \+= tank0_direction << 3;/ &&
$s =~ /tank1_graphics := tanks_graphics;\s*tank1_graphics \+= tank1_direction << 3;/ &&
$s =~ /tanks_player_position_table\[160\]/ &&
$s =~ /tanks_player_position_control\[0\] := tanks_player_position_table\[tank0_x\]/ &&
$s =~ /tanks_player_position_control\[1\] := tanks_player_position_table\[tank1_x\]/ &&
$s =~ /tanks_draw\(\);.*?PF0 := 0;\s*PF1 := 0;\s*PF2 := 0;.*?WSYNC := 0;\s*WSYNC := 0;/s
   or die "Tanks lost high-level sprite-base preparation or fixed-time player positioning\n";
$s =~ /CXM0P & 0x80/ && $s =~ /CXM1P & 0x80/ &&
$s =~ /CXM0FB & 0x80/ && $s =~ /CXM1FB & 0x80/ &&
$s =~ /CXP0FB & 0x80/ && $s =~ /CXP1FB & 0x80/ && $s =~ /CXPPMM & 0x80/ && $s =~ /CXCLR := 0/ &&
$s =~ /cartram uint8_t tank0_pf_escape/ && $s =~ /cartram uint8_t tank1_pf_escape/ &&
$s =~ /if \(!tank0_pf_escape\).*?tank0_x := tank0_prev_x/s &&
$s =~ /if \(!tank1_pf_escape\).*?tank1_x := tank1_prev_x/s &&
$s =~ /else \{ tank0_pf_escape := 0; \}/ && $s =~ /else \{ tank1_pf_escape := 0; \}/ &&
$s =~ /tanks_process_knockback\(void\).*?tanks_update_player_collisions\(\);/s &&
$s =~ /tanks_apply_knockback\(&tank0_x, &tank0_y, tanks_knock_direction\);\s*tank0_pf_escape := 1;/s &&
$s =~ /tanks_apply_knockback\(&tank1_x, &tank1_y, tanks_knock_direction\);\s*tank1_pf_escape := 1;/s &&
$s =~ /vcs_ntsc_begin_overscan\(\);\s*tanks_process_knockback\(\);\s*tanks_update_overscan\(\);/s
   or die "Tanks must consume player collisions and allow knockback escape from playfield geometry\n";
$s =~ /TANKS_KNOCKBACK_X_CARDINAL := 32/ && $s =~ /TANKS_KNOCKBACK_X_DIAGONAL := 23/ &&
$s =~ /TANKS_KNOCKBACK_Y_CARDINAL := 16/ && $s =~ /TANKS_KNOCKBACK_Y_DIAGONAL := 11/ &&
$s =~ /tanks_knockback_offsets\[8\].*?0,1,7,0,1,7,2,6/s &&
$s =~ /TANKS_PLAYER_X_SPAN := 145/ && $s =~ /TANKS_PLAYER_Y_SPAN := 75/ &&
$s =~ /tanks_apply_knockback.*?tanks_knock_x -= TANKS_PLAYER_X_SPAN.*?tanks_knock_y -= TANKS_PLAYER_Y_SPAN/s &&
$s !~ /tanks_try_knockback|knock_pf_blocked|tanks_player_pf2_overlap/ &&
$s =~ /tank1_knockback_pending := \(\(\(missile0_direction \+ 1\) >> 1\) & 7\) \+ 1/ &&
$s =~ /tank0_knockback_pending := \(\(\(missile1_direction \+ 1\) >> 1\) & 7\) \+ 1/
   or die "Tanks lost away-side wall-wrapping hit knockback\n";
$s =~ /controls & 0x40/ && $s =~ /controls & 0x80/ && $s =~ /controls & 0x04/ && $s =~ /controls & 0x08/ &&
$s =~ /controls & 0x10/ && $s =~ /controls & 0x20/ && $s =~ /controls & 0x01/ && $s =~ /controls & 0x02/ &&
$s =~ /INPT4 & 0x80/ && $s =~ /INPT5 & 0x80/
   or die "Tanks lost two-joystick direction\/fire mapping\n";
$s =~ /missile0_x := tank0_x \+ 8/ && $s =~ /missile1_x := tank1_x \+ 8/ &&
$s =~ /renders M0\/M1.*?five Atari pixels left/s
   or die "Tanks lost physical-center missile positioning calibration\n";
my($graphics_block)=$s =~ /tanks_graphics\[128\] := \{(.*?)\n\};/s;
defined $graphics_block or die "Tanks graphics table missing\n";
my @graphics_rows=grep {/0b/} split /\n/,$graphics_block;
@graphics_rows==128 && !grep { $_ !~ /^\s*0b[.X]{8},\s*$/ } @graphics_rows
   or die "Tanks graphics must keep exactly one visual 0b dot\/X byte per source line\n";
my @graphics_bits=map { /0b([.X]{8})/ ? $1 : () } @graphics_rows;
my @expected_graphics=qw(
........ ...X.... ...X.... XX.X.XX. XXXXXXX. XXXXXXX. XX...XX. XX...XX.
..X..X.. .XX..X.. .XXXX..X XXXXXXXX XXXXXXXX .X..XXX. ....XXX. .....X..
...XX..X ..XXX.X. .XXXXX.. XXXXXXXX XX.XXXXX ....XXX. ...XXX.. ...XX...
...XXX.. .XXXX... XXXXX.XX .XXXXX.. ...XXX.. ...XXXXX ..XXXXX. ...XX...
XXXXX... XXXXX... ..XX.... ..XXXXX. ..XX.... XXXXX... XXXXX... ........
...XX... ..XXXXX. ...XXXXX ...XXX.. .XXXXX.. XXXXX.XX .XXXX... ...XXX..
...XX... ...XXX.. ....XXX. XX.XXXXX XXXXXXXX .XXXXX.. ..XXX.X. ...XX..X
.....X.. ....XXX. .X..XXX. XXXXXXXX XXXXXXXX .XXXX..X .XX..X.. ..X..X..
.XX...XX .XX...XX .XXXXXXX .XXXXXXX .XX.X.XX ....X... ....X... ........
..X..... .XXX.... .XXX..X. XXXXXXXX XXXXXXXX X..XXXX. ..X..XX. ..X..X..
...XX... ..XXX... .XXX.... XXXXX.XX XXXXXXXX ..XXXXX. .X.XXX.. X..XX...
...XX... .XXXXX.. XXXXX... ..XXX... ..XXXXX. XX.XXXXX ...XXXX. ..XXX...
........ ...XXXXX ...XXXXX ....XX.. .XXXXX.. ....XX.. ...XXXXX ...XXXXX
..XXX... ...XXXX. XX.XXXXX ..XXXXX. ..XXX... XXXXX... .XXXXX.. ...XX...
X..XX... .X.XXX.. ..XXXXX. XXXXXXXX XXXXX.XX .XXX.... ..XXX... ...XX...
..X..X.. ..X..XX. X..XXXX. XXXXXXXX XXXXXXXX .XXX..X. .XXX.... ..X.....
);
join(' ',@graphics_bits) eq join(' ',@expected_graphics)
   or die "Tanks graphics no longer match the canonical N/NNE/NE silhouettes and their 16-way transforms\n";
$s =~ /tanks_angle_steps\[16\].*?0,1,0,1,0,1,0,1,0,1,0,1,0,1,0,0/s &&
$s =~ /tanks_motion\[16\].*?0x50,0x52,0x51,0x61,0x01,0x21,0x11,0x12,\s*0x10,0x16,0x15,0x25,0x05,0x65,0x55,0x56/s &&
$s =~ /tanks_move_object\(x, y, direction\)/
   or die "Tanks lost logical-grid 16-way movement support\n";

my($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-I',$dir,'-T',File::Spec->catfile($vcs,'vcs.cfg'),'-Map',$mapfile,$source,'-o',$bin);
$rc==0&&!$sig or die "Tanks build failed\n$out$err";
-s$bin==8192 or die "Tanks ROM is not 8192-byte F8SC\n";
my$map=read_file($mapfile);
$map =~ /pinned\s+CODE\.__vcsc_function\$main\s+region=bank0/m &&
$map =~ /automatic\s+CODE\.__vcsc_function\$tanks_update_overscan\s+region=bank1/m &&
$map =~ /automatic\s+CODE\.__vcsc_function\$tanks_process_knockback\s+region=bank[01]/m
   or die "Tanks automatic F8SC code placement did not keep startup home and use both banks\n$map";
$map =~ /^\s+cartram\s+read_start=\$F080 write_start=\$F000 size=\$0080 type=rw shared=yes\b/m &&
$map =~ /^\s+ZERO\s+BSS\.cartram\.__vcsc_object\$tanks_barrier_pf2\s+read=\$F080\s+write=\$F000\s+size=\$0056/m
   or die "Tanks explicit Superchip RAM placement/init aliasing changed\n$map";

my$cxx=$ENV{CXX}||'c++';my$mos=File::Spec->catdir($repo,qw(simulator mos6502));my$mosobj=File::Spec->catfile($mos,'mos6502.o');my@mos=-f$mosobj?($mosobj):(File::Spec->catfile($mos,'mos6502.cpp'));
my$oracle_src=File::Spec->catfile($repo,qw(test vcs_tanks.cpp));my$oracle=File::Spec->catfile($tmp,'vcs_tanks_oracle');
($rc,$sig,$out,$err)=capture($cxx,'-std=c++17','-Wall','-Wextra','-Werror','-pedantic','-O2','-DILLEGAL_OPCODES','-I',$mos,$oracle_src,@mos,'-o',$oracle);
$rc==0&&!$sig or die"Tanks oracle build failed\n$out$err";
my@symbols=qw(tank0_x tank1_x tank0_y tank1_y tank0_direction tank1_direction tank0_graphics tank1_graphics tank0_prev_x tank1_prev_x tank0_prev_y tank1_prev_y tank0_spin_frames tank1_spin_frames missile0_x missile1_x missile0_y missile1_y missile0_direction missile1_direction missile0_active missile1_active score_left_score score_right_score tanks_move_phase tanks_rng tanks_sound_frames tanks_sound_kind tanks_barrier_pf2 tanks_graphics);
my@addr=map{sprintf('0x%04x',symbol_addr($map,$_))}@symbols;
($rc,$sig,$out,$err)=capture($oracle,$bin,@addr);$rc==0&&!$sig or die"Tanks oracle run failed\n$out$err";
$out eq "vcs_tanks ok: stable early raster writes, visible missiles, 16-way tanks, 3+3 score, engine/fire/hit audio, wall-wrapping knockback, barriers, spin, TIA collisions\n" or die"unexpected Tanks oracle output: $out";
$err eq '' or die"Tanks oracle stderr: $err";
print "vcs_tanks ok\n";
