#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 45
# expectstdout: vcs_joystick ok
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
sub map_symbol { my($map,$name)=@_; $map =~ /^\s*\$([0-9A-Fa-f]{4})\s+\Q$name\E\b/m or die "map missing $name\n"; return hex($1); }

my$repo=shift@ARGV//usage();my$tmp=shift@ARGV//usage();usage()if@ARGV;
$repo=abs_path($repo)//die"resolve repo\n";$tmp=abs_path($tmp)//die"resolve tmp\n";
my$driver=File::Spec->catfile($repo,qw(driver vcsc));
my$vcs=File::Spec->catdir($repo,qw(libraries vcs));
my$dir=File::Spec->catdir($repo,qw(examples 03_controllers joystick));
my$src=File::Spec->catfile($dir,'joystick.c26');
my$make=File::Spec->catfile($dir,'Makefile');
my$readme=File::Spec->catfile($dir,'README.md');

my$s=read_file($src);
$s =~ /instantiate\s+"renderers\/player_color\/player_color\.c26"\s+as\s+game\s+\(lines:=192\)/
   or die "joystick tutorial must use the full-height player-color renderer\n";
$s =~ /COLUBK\s*:=\s*JOYSTICK_BLACK;/ &&
$s =~ /alias\s+JOYSTICK_RED\s+__builtin_ntsc_rgb/ &&
$s =~ /alias\s+JOYSTICK_BLUE\s+__builtin_ntsc_rgb/
   or die "joystick tutorial lost black background or red/blue player colors\n";

my @normal=(
   '........',
   '........',
   '..XXXX..',
   '..XXXX..',
   '..XXXX..',
   '..XXXX..',
   '........',
   '........',
);
my @outline=(
   '.XXXXXX.',
   'X......X',
   'X.XXXX.X',
   'X.XXXX.X',
   'X.XXXX.X',
   'X.XXXX.X',
   'X......X',
   '.XXXXXX.',
);
my $normal_pattern=join('\\s*,\\s*',map { '0b'.quotemeta($_) } @normal);
my $outline_pattern=join('\\s*,\\s*',map { '0b'.quotemeta($_) } @outline);
$s =~ /joystick_graphics\[16\]\s*:=\s*\{\s*$normal_pattern\s*,\s*$outline_pattern\s*\}/s
   or die "joystick tutorial lost exact 8-row normal/fire bitmap layout\n";
$s !~ /game_player0_height\s*:=\s*3;/ &&
$s !~ /game_player1_height\s*:=\s*3;/ &&
$s =~ /game_player0_height\s*:=\s*7;/ &&
$s =~ /game_player1_height\s*:=\s*7;/
   or die "joystick tutorial must keep both normal and fire sprites at 8 rows\n";

$s =~ /uint8_t\s+joysticks\s*:=\s*SWCHA;/
   or die "joystick tutorial must sample SWCHA directly\n";
for my $mask (qw(40 80 10 20 04 08 01 02)) {
   $s =~ /!\(joysticks & 0x\Q$mask\E\)/
      or die "joystick tutorial lost active-low direction mask 0x$mask\n";
}
$s =~ /!\(INPT4 & 0x80\)/ && $s =~ /!\(INPT5 & 0x80\)/
   or die "joystick tutorial must use both active-low fire buttons\n";
$s =~ /game_PLAYER0_X--/ && $s =~ /game_PLAYER0_X\+\+/ &&
$s =~ /game_player0_y--/ && $s =~ /game_player0_y\+\+/ &&
$s =~ /game_PLAYER1_X--/ && $s =~ /game_PLAYER1_X\+\+/ &&
$s =~ /game_player1_y--/ && $s =~ /game_player1_y\+\+/
   or die "joystick tutorial lost independent two-player movement\n";

my$m=read_file($make);
$m =~ /^ROOT \?= \.\.\/\.\.\/\.\.$/m &&
$m =~ /renderers\/player_color\/player_color\.c26/ &&
$m =~ /^play:\s*\n\tstella -userdir "\$\(CURDIR\)" "\$\(CURDIR\)"\/\*\.bin/m
   or die "joystick Makefile dependencies, source-tree root, or play target regressed\n";
my$r=read_file($readme);
$r =~ /left joystick moves the red square/i &&
$r =~ /right joystick moves the\s+blue square/i &&
$r =~ /INPT4/ && $r =~ /INPT5/ &&
$r =~ /0x10.*UP/s && $r =~ /0x80.*RIGHT/s &&
$r =~ /0x01.*UP/s && $r =~ /0x08.*RIGHT/s &&
$r =~ /active low/i
   or die "joystick README lost two-controller wiring explanation\n";

my$bin=File::Spec->catfile($tmp,'joystick.bin');
my$map=File::Spec->catfile($tmp,'joystick.map');
my($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-Map',$map,$src,'-o',$bin);
$rc==0&&!$sig or die "joystick build failed\n$out$err";
$err eq '' or die "joystick build stderr: $err";
-s$bin==4096 or die "joystick tutorial is not a 4K ROM\n";

# Exercise the built cartridge for several synchronized frames.  The second
# controlled frame presses left+up on port 0 and right+down on port 1 while
# holding both fire buttons.  The public renderer state must therefore move
# independently and select the outlined 8-row bitmap for both players.
my$map_text=read_file($map);
my$object_x=map_symbol($map_text,'game_object_x');
my$p0_y=map_symbol($map_text,'game_player0_y');
my$p1_y=map_symbol($map_text,'game_player1_y');
my$p0_graphics=map_symbol($map_text,'game_player0_graphics');
my$p1_graphics=map_symbol($map_text,'game_player1_graphics');
my$p0_height=map_symbol($map_text,'game_player0_height');
my$p1_height=map_symbol($map_text,'game_player1_height');
my$graphics=map_symbol($map_text,'joystick_graphics');
my$outline=$graphics+8;

my$cxx=$ENV{CXX}||'c++';
my$mos=File::Spec->catdir($repo,qw(simulator mos6502));
my$frame_src=File::Spec->catfile($repo,qw(test vcs_frame_timing.cpp));
my$frame_exe=File::Spec->catfile($tmp,'vcs_joystick_runtime');
my$mos_obj=File::Spec->catfile($mos,'mos6502.o');
my@mos_input=-f$mos_obj?($mos_obj):(File::Spec->catfile($mos,'mos6502.cpp'));
($rc,$sig,$out,$err)=capture($cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,$frame_src,@mos_input,'-o',$frame_exe);
$rc==0&&!$sig or die "joystick runtime harness build failed\n$out$err";
$err eq '' or die "joystick runtime harness build stderr: $err";

my@runtime=(
   $frame_exe,$bin,'10','--no-audio','--raw-lines','264','--minimum-checked-frames','1','--released-inputs',
   '--frame-sequence','0x0280','0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xa5,0xff',
   '--frame-sequence','0x003c','0x80,0x80,0x80,0x80,0x80,0x80,0x80,0x00,0x80',
   '--frame-sequence','0x003d','0x80,0x80,0x80,0x80,0x80,0x80,0x80,0x00,0x80',
   '--expect-memory',sprintf('0x%04x',$object_x+0),'39',
   '--expect-memory',sprintf('0x%04x',$object_x+1),'113',
   '--expect-memory',sprintf('0x%04x',$p0_y),'43',
   '--expect-memory',sprintf('0x%04x',$p1_y),'45',
   '--expect-memory',sprintf('0x%04x',$p0_height),'7',
   '--expect-memory',sprintf('0x%04x',$p1_height),'7',
   '--expect-memory',sprintf('0x%04x',$p0_graphics),sprintf('0x%02x',$outline&0xff),
   '--expect-memory',sprintf('0x%04x',$p0_graphics+1),sprintf('0x%02x',($outline>>8)&0xff),
   '--expect-memory',sprintf('0x%04x',$p1_graphics),sprintf('0x%02x',$outline&0xff),
   '--expect-memory',sprintf('0x%04x',$p1_graphics+1),sprintf('0x%02x',($outline>>8)&0xff),
);
($rc,$sig,$out,$err)=capture(@runtime);
$rc==0&&!$sig or die "joystick runtime behavior failed\n$out$err";
$err eq '' or die "joystick runtime stderr: $err";

print "vcs_joystick ok\n";
