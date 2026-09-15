#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_heart_score_examples ok
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub slurp_fh { my($fh)=@_; local $/; return <$fh> // ''; }
sub capture { my(@c)=@_; my$e=gensym; my$p=open3(my$i,my$o,$e,@c); close$i; my$so=slurp_fh($o); my$se=slurp_fh($e); waitpid($p,0); return($?>>8,$?&127,$so,$se); }
sub read_file { my($p)=@_; open(my$f,'<:raw',$p) or die "read $p: $!\n"; local$/; my$d=<$f>; close$f; return $d // ''; }
sub without_usage { my($s)=@_; $s =~ s/\AMEMORY USAGE\n(?:  [^\n]+\n)+//; return $s; }

@ARGV==2 or die "usage: $0 REPO TMP\n";
my $repo=abs_path($ARGV[0]) or die "resolve repo\n";
my $tmp=$ARGV[1]; make_path($tmp); $tmp=abs_path($tmp) or die "resolve tmp\n";
my $driver=File::Spec->catfile($repo,qw(driver vcsc));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $dir=File::Spec->catdir($repo,qw(examples 01_basic 14_heart_score));
my $controls=read_file(File::Spec->catfile($repo,qw(examples common heart_score_controls.c26)));
my $common=read_file(File::Spec->catfile($repo,qw(examples common heart_score_player_color_181_common.c26)));

$controls =~ /right_joystick_ready\s*:=\s*0x0f/ or die "right joystick edge latch is missing\n";
$controls =~ /SWCHA\s*&\s*0x0f/ or die "right joystick does not read the low SWCHA nibble\n";
$controls =~ /right_joystick_ready\s*&\s*0x01/ or die "right joystick UP handling is missing\n";
$controls =~ /right_joystick_ready\s*&\s*0x02/ or die "right joystick DOWN handling is missing\n";
$controls =~ /score_score\s*<\s*score_boxes/ or die "heart increment is not capped by box capacity\n";
$controls =~ /right_joystick_ready\s*&\s*0x04/ or die "right joystick LEFT box handling is missing\n";
$controls =~ /right_joystick_ready\s*&\s*0x08/ or die "right joystick RIGHT box handling is missing\n";
$controls =~ /score_boxes\s*<\s*11/ or die "heart box increment is not capped at 11\n";
$controls =~ /clamp_score_to_boxes\(\);/ or die "box decrement does not clamp health\n";
$common =~ /game_PLAYER0_X\s*:=\s*44/ && $common =~ /game_PLAYER1_X\s*:=\s*108/
   or die "player-color composition scene is missing\n";
$common =~ /update_score_controls\(\);/ or die "composition scene does not update heart controls\n";
$common =~ /update_object_selection\(\);/ && $common =~ /move_selected_object\(\);/
   or die "heart composition demo lacks left-joystick object controls\n";
$common =~ /SELECTED_PLAYER0/ && $common =~ /SELECTED_PLAYER1/ && $common =~ /SELECTED_BALL/
   or die "heart composition demo does not cycle P0, P1, and Ball\n";
$common =~ /SWCHA\s*&\s*0x40/ && $common =~ /SWCHA\s*&\s*0x80/ &&
$common =~ /SWCHA\s*&\s*0x10/ && $common =~ /SWCHA\s*&\s*0x20/
   or die "heart composition demo does not read the left joystick directions\n";

for my $kind (qw(above below)) {
   my $src=File::Spec->catfile($dir,"heart_score_${kind}_interactive.c26");
   my $text=read_file($src);
   $text =~ /^include "F8\/mapper\.c26"$/m or die "$kind demo is not an F8 cartridge\n";
   $text =~ /instantiate "renderers\/player_color\/player_color\.c26" as game \(lines:=181\)/
      or die "$kind demo does not use maintained player_color_181\n";
   $text =~ /instantiate "heart_score_component\.c26" as score \(banked:=1\)/
      or die "$kind demo does not instantiate banked heart score\n";
   $text =~ /vcs_ntsc_component_handoff\(\);/ && $text =~ /vcs_ntsc_wait_component_scanlines\(4\);/
      or die "$kind demo does not use the measured four-line component gap\n";
   my $score=index($text,'score_draw();');
   my $game=index($text,'game_draw();');
   $score>=0 && $game>=0 or die "$kind demo lacks component draws\n";
   ($kind eq 'above' ? $score<$game : $game<$score) or die "$kind demo draw order is wrong\n";

   my $bin=File::Spec->catfile($tmp,"heart_score_${kind}_interactive.bin");
   my $map=File::Spec->catfile($tmp,"heart_score_${kind}_interactive.map");
   my($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-Map',$map,$src,'-o',$bin);
   $rc==0 && !$sig or die "$kind demo build failed\n$out$err";
   without_usage($out) eq '' && $err eq '' or die "$kind demo build wrote output\n$out$err";
   -s $bin == 8192 or die "$kind demo is not an 8192-byte F8 ROM\n";
   my $mt=read_file($map);
   $mt =~ /^\s+CODE\.bank1\.__vcsc_function\$score_dispatch\s+.*\bbank=bank1\b.*\bplacement=pinned\b/m
      or die "$kind demo does not pin the heart dispatcher in F8 bank1\n";
   $mt =~ /^\s+CODE\.__vcsc_function\$score_renderer_0\s+.*\bbank=bank1\b/m
      or die "$kind demo heart renderer is not in F8 bank1\n";
   $mt =~ /^\s+CODE\.__vcsc_function\$main\s+.*\bbank=bank0\b.*\bplacement=pinned\b/m
      or die "$kind demo main is not pinned in F8 bank0\n";
}

print "vcs_heart_score_examples ok\n";
