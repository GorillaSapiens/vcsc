#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 60
# expectstdout: vcs_four_player_paddleball ok
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
my$source=File::Spec->catfile($repo,qw(examples 01_basic 10_four_player_paddleball four_player_paddleball.c26));
my$component=File::Spec->catfile($vcs,'four_paddles.c26');
my$two=File::Spec->catfile($vcs,'two_paddles.c26');
my$bin=File::Spec->catfile($tmp,'four_player_paddleball.bin');
my$mapfile=File::Spec->catfile($tmp,'four_player_paddleball.map');

my$c=read_file($component);my$t=read_file($two);my$p=read_file($source);
$c =~ /TEMPLATE_position0/ && $c =~ /TEMPLATE_position1/ && $c =~ /TEMPLATE_position2/ && $c =~ /TEMPLATE_position3/ &&
$c =~ /TEMPLATE_button0/ && $c =~ /TEMPLATE_button1/ && $c =~ /TEMPLATE_button2/ && $c =~ /TEMPLATE_button3/ &&
$c =~ /TEMPLATE_sample0/ && $c =~ /TEMPLATE_sample1/ && $c =~ /TEMPLATE_sample2/ && $c =~ /TEMPLATE_sample3/ &&
$c =~ /same two-scanline raw units as two_paddles\.c26/ && $c =~ /TEMPLATE_dump/ &&
$c =~ /TEMPLATE_score_sample0/ && $c =~ /TEMPLATE_score_sample1/ &&
$c =~ /TEMPLATE_score_latch23_fixed/ && $c =~ /TEMPLATE_score_commit_latched23/ &&
$c =~ /TEMPLATE_score_advance_pair/ && $c =~ /TEMPLATE_score_account_a/
   or die "four-paddle API contract missing\n";
$t =~ /parameter port := 0/ && $t =~ /TEMPLATE_position0/ && $t =~ /TEMPLATE_position1/ && $t =~ /TEMPLATE_button0/ && $t =~ /TEMPLATE_button1/
   or die "two-paddle subset API regressed\n";

$p =~ /include "4K\/mapper\.c26"/ && $p =~ /instantiate "four_paddles\.c26" as paddles/ or die "four-player example lost 4K\/four-paddle composition\n";
$p =~ /inline void score_paddle_sample0\(void\) \{ paddles_score_sample0\(\); \}/ &&
$p =~ /inline void score_paddle_sample1\(void\) \{ paddles_score_sample1\(\); \}/ &&
$p =~ /inline void score_paddle_latch23_fixed\(void\) \{ paddles_score_latch23_fixed\(\); \}/ &&
$p =~ /inline void score_paddle_advance_pair\(void\) \{ paddles_score_advance_pair\(\); \}/ &&
$p =~ /instantiate "three_plus_three_score_component\.c26" as score \(paddle_samples:=4\)/ &&
$p =~ /paddles_score_commit_latched23\(\);.*?asm lda #9;\s*paddles_score_account_a\(\);/s
   or die "four-player Paddleball no longer samples all four paddles through the score renderer\n";
$p =~ /paddle 0\s+.*P0.*paddle 1\s+.*M0/s && $p =~ /paddle 2\s+.*P1.*paddle 3\s+.*M1/s
   or die "four-player team\/object allocation changed\n";
$p =~ /paddles_sample0\(\);\s*WSYNC := _;/s &&
$p =~ /paddles_sample1\(\);.*?asm inx;.*?asm sta WSYNC;\s*asm sta PF2;.*?paddles_advance_pair\(\);/s &&
$p =~ /paddles_sample2\(\);\s*WSYNC := _;/s &&
$p =~ /paddles_sample3\(\);.*?asm inx;.*?asm sta WSYNC;\s*asm sta PF2;.*?paddles_advance_pair\(\);/s
   or die "four-player renderer lost one-sample-per-scanline schedule\n";
$p !~ /paddleball_pf2_pairs|paddleball_reposition_table/ &&
$p =~ /asm txa;\s*asm and #4;\s*asm cmp #4;\s*asm lda #0;\s*asm ror;/s &&
$p =~ /uint8_t ball_remainder := paddleball_ball_x;/ &&
$p =~ /while \(ball_remainder >= 15\) \{ ball_remainder -= 15; \}/ &&
$p =~ /paddleball_ball_fine := \(ball_remainder \^ 7\) << 4;/
   or die "four-player renderer regained regular lookup tables or lost high-level fine-motion preparation\n";
$p =~ /paddleball_position_ball.*?asm sta HMCLR;.*?asm sta HMP0,x;.*?asm sta WSYNC;\s*asm sta HMOVE;/s
   or die "four-player Ball positioning lost pre-HMOVE HMCLR\n";
$p =~ /Lines 0\.\.2: black score-to-wall gap and fixed P0\/P1 restoration\.(.*?)\/\/ Start the wall/s
   or die "four-player fixed player restore block not found\n";
my $player_restore = $1;
$player_restore =~ /asm sta HMCLR;/ && $player_restore =~ /asm sta RESP0,x;/ &&
$player_restore !~ /asm .*\bHMP[01]\b/ && $player_restore !~ /asm .*\bHMOVE\b/
   or die "four-player fixed player restore must be coarse-only with cleared HM state\n";
$p =~ /asm \@pair01:;(.*?)\/\/ Line 176:/s or die "four-player gameplay loop not found\n";
$1 !~ /HMOVE/ or die "four-player gameplay loop must not strobe HMOVE\n";
$p =~ /blue_outer_hit := CXP0FB & 0x40/ && $p =~ /blue_inner_hit := CXM0FB & 0x40/ &&
$p =~ /red_outer_hit := CXP1FB & 0x40/ && $p =~ /red_inner_hit := CXM1FB & 0x40/
   or die "four-player example lost P0\/M0\/P1\/M1 Ball collision latches\n";
$p =~ /paddles_button0 \|\| paddles_button1/ && $p =~ /paddles_button2 \|\| paddles_button3/
   or die "four-player team serve buttons changed\n";
$p !~ /\bbank[0-9]+\b/ or die "four-player example unexpectedly requires bankswitching\n";

my($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-I',File::Spec->catdir($repo,qw(examples 01_basic 10_four_player_paddleball)),'-T',File::Spec->catfile($vcs,'vcs.cfg'),'-Map',$mapfile,$source,'-o',$bin);
$rc==0&&!$sig or die "four-player Paddleball build failed\n$out$err";
$err eq '' or die "four-player Paddleball build stderr: $err";
-s$bin==4096 or die "four-player Paddleball ROM is not 4096 bytes\n";
my$map=read_file($mapfile);
$map =~ /^\s*rom\s+used=(\d+) bytes/m or die "four-player 4K ROM accounting missing\n";
$1 <= 4090 or die "four-player Paddleball exceeds the 4K usable ROM budget\n";
my $position_base=symbol_addr($map,'paddles_position0');
my $active_base=symbol_addr($map,'paddles_active0');
for my $i (0..3) {
   symbol_addr($map,"paddles_position$i") == $position_base + $i
      or die "four-paddle position group is not contiguous\n";
   symbol_addr($map,"paddles_active$i") == $active_base + $i
      or die "four-paddle active group is not contiguous\n";
}

my$cxx=$ENV{CXX}||'c++';my$mos=File::Spec->catdir($repo,qw(simulator mos6502));my$mosobj=File::Spec->catfile($mos,'mos6502.o');my@mos=-f$mosobj?($mosobj):(File::Spec->catfile($mos,'mos6502.cpp'));
my$oracle_src=File::Spec->catfile($repo,qw(test vcs_four_player_paddleball.cpp));my$oracle=File::Spec->catfile($tmp,'vcs_four_player_paddleball_oracle');
($rc,$sig,$out,$err)=capture($cxx,'-std=c++17','-Wall','-Wextra','-Werror','-pedantic','-O2','-DILLEGAL_OPCODES','-I',$mos,$oracle_src,@mos,'-o',$oracle);
$rc==0&&!$sig or die "four-player oracle build failed\n$out$err";

my@symbols=qw(paddles_position0 paddles_position1 paddles_position2 paddles_position3 paddles_button0 paddles_button1 paddles_button2 paddles_button3 paddles_valid paddleball_p0_y paddleball_m0_y paddleball_p1_y paddleball_m1_y);
my@addr=map{sprintf('0x%04x',symbol_addr($map,$_))}@symbols;
($rc,$sig,$out,$err)=capture($oracle,$bin,@addr);
$rc==0&&!$sig or die "four-player oracle run failed\n$out$err";
$out eq "vcs_four_player_paddleball ok: stable 4K raster, four independent RC channels and buttons\n" or die "unexpected four-player oracle output: $out";
$err eq '' or die "four-player oracle stderr: $err";
print "vcs_four_player_paddleball ok\n";
