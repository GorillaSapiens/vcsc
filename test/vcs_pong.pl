#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 45
# expectstdout: vcs_pong ok
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
my$source=File::Spec->catfile($repo,qw(examples 01_basic 09_pong pong.c26));
my$component=File::Spec->catfile($vcs,'two_paddles.c26');
my$bin=File::Spec->catfile($tmp,'pong.bin');my$mapfile=File::Spec->catfile($tmp,'pong.map');

my$c=read_file($component);my$p=read_file($source);
$c =~ /parameter port := 0/ && $c =~ /TEMPLATE_position0/ && $c =~ /TEMPLATE_position1/ &&
$c =~ /TEMPLATE_button0/ && $c =~ /TEMPLATE_button1/ && $c =~ /TEMPLATE_dump/ &&
$c =~ /TEMPLATE_account_gap/ or die "two-paddle API contract missing\n";
$p =~ /three_plus_three_score_component\.c26/ && $p =~ /two_paddles\.c26/ or die "Pong lost required component composition\n";
$p =~ /score_left_color := PONG_BLUE/ && $p =~ /score_right_color := PONG_RED/ or die "Pong lost blue\/red score colors\n";
$p =~ /asm lda #\$ff;\s*asm sta PF0;\s*asm sta PF1;\s*asm sta PF2;/s or die "Pong lost full-width walls\n";
$p =~ /0x80,0x80,0x80,0x80, 0x00,0x00,0x00,0x00/ or die "Pong lost dashed center pattern\n";
$p =~ /PONG_LEFT_X := 16/ && $p =~ /PONG_RIGHT_X := 156/ &&
$p =~ /PONG_LEFT_COLLISION_X := 14/ && $p =~ /PONG_RIGHT_COLLISION_X := 152/ &&
$p =~ /PONG_LEFT_SCORE_X := 4/ && $p =~ /PONG_RIGHT_SCORE_X := 163/
   or die "Pong horizontal geometry calibration changed\n";
$p =~ /asm bit\.z CXM0P;\s*asm lda #16;\s*asm sec;.*?asm nop;\s*asm nop;\s*asm sta RESP0,x;/s &&
$p =~ /asm bit\.z CXM0P;\s*asm lda #156;\s*asm sec;.*?asm nop;\s*asm nop;\s*asm sta RESP0,x;/s
   or die "Pong lost calibrated paddle RESP timing\n";
$p =~ /pong_left_y := paddle_target_y\(paddles_position0\)/ &&
$p =~ /pong_right_y := paddle_target_y\(paddles_position1\)/ &&
$p !~ /pong_(?:left|right)_y \+= 2/ && $p !~ /pong_(?:left|right)_y -= 2/
   or die "Pong reintroduced queued paddle motion\n";
$p =~ /PONG_PADDLE_TOP_Y := 9/ && $p =~ /PONG_PADDLE_BOTTOM_Y := 159/ &&
$p =~ /PONG_PADDLE_RAW_MIN := 12/ && $p =~ /PONG_BALL_TOP_Y := 8/
   or die "Pong paddle endpoint calibration changed\n";
$p =~ /paddles_sample0\(\);\s*WSYNC := 0;/s &&
$p =~ /paddles_sample1\(\);.*?asm inx;\s*asm sta WSYNC;\s*paddles_advance_pair\(\);/s &&
$p =~ /Both paddles transition on line B/s
   or die "Pong lost split RC sampling or common paddle raster phase\n";

my($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-I',File::Spec->catdir($repo,qw(examples 01_basic 09_pong)),'-T',File::Spec->catfile($vcs,'vcs.cfg'),'-Map',$mapfile,$source,'-o',$bin);
$rc==0&&!$sig or die "Pong build failed\n$out$err";
$err eq '' or die "Pong build stderr: $err";
-s$bin==4096 or die "Pong ROM is not 4096 bytes\n";
my$map=read_file($mapfile);

# Port 1 must instantiate from the same public component API even though the
# game uses port 0.
my$port1=File::Spec->catfile($tmp,'port1.c26');open(my$f,'>:raw',$port1)or die$!;
print{$f} "include \"vcs_4k.c26\"\ninstantiate \"two_paddles.c26\" as p (port:=1)\nvoid main(void) { p_init(); p_vblank(); p_sample0(); p_sample1(); p_advance_pair(); p_account_gap(1); p_overscan(); p_dump(); }\n";close$f;
my$port1bin=File::Spec->catfile($tmp,'port1.bin');
($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,$port1,'-o',$port1bin);$rc==0&&!$sig or die"port-1 paddle API build failed\n$out$err";

my$cxx=$ENV{CXX}||'c++';my$mos=File::Spec->catdir($repo,qw(simulator mos6502));my$mosobj=File::Spec->catfile($mos,'mos6502.o');my@mos=-f$mosobj?($mosobj):(File::Spec->catfile($mos,'mos6502.cpp'));
my$oracle_src=File::Spec->catfile($repo,qw(test vcs_pong.cpp));my$oracle=File::Spec->catfile($tmp,'vcs_pong_oracle');
($rc,$sig,$out,$err)=capture($cxx,'-std=c++17','-Wall','-Wextra','-Werror','-pedantic','-O2','-DILLEGAL_OPCODES','-I',$mos,$oracle_src,@mos,'-o',$oracle);
$rc==0&&!$sig or die"Pong oracle build failed\n$out$err";
my@symbols=qw(paddles_position0 paddles_position1 paddles_valid paddles_button0 paddles_button1 pong_left_y pong_right_y pong_ball_x pong_ball_y waiting_for_serve score_left_score score_right_score);
my@addr=map{sprintf('0x%04x',symbol_addr($map,$_))}@symbols;
($rc,$sig,$out,$err)=capture($oracle,$bin,@addr);$rc==0&&!$sig or die"Pong oracle run failed\n$out$err";
$out eq "vcs_pong ok: stable frames, two-paddle RC span/buttons, serve, score, reset\n" or die"unexpected Pong oracle output: $out";
$err eq '' or die"Pong oracle stderr: $err";
print "vcs_pong ok\n";
