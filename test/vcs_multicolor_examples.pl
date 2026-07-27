#!/usr/bin/perl
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub usage { die "usage: $0 REPO TMP\n"; }
sub slurp_fh { my($fh)=@_; local $/; my $d=<$fh>; return defined($d)?$d:''; }
sub capture { my(@cmd)=@_; my $err=gensym; my $pid=open3(my $in,my $out,$err,@cmd); close($in); my $so=slurp_fh($out); my $se=slurp_fh($err); waitpid($pid,0); return ($?>>8,$?&127,$so,$se); }
sub read_file { my($p)=@_; open(my $f,'<:raw',$p) or die "read $p: $!\n"; local $/; my $d=<$f>; close($f); return defined($d)?$d:''; }
sub without_usage { my($s)=@_; $s =~ s/\ACARTRIDGE ROM USAGE\n(?:  [^\n]+\n)+RAM USAGE\n(?:  [^\n]+\n)+//; return $s; }
sub map_zp { my($map,$name)=@_; $map =~ /^\s*\$([0-9A-Fa-f]{4})\s+\Q$name\E\b/m or die "map missing $name\n"; my $v=hex($1); $v<=0xff or die "$name is not zero-page\n"; return sprintf('0x%02x',$v); }

my $repo=shift @ARGV // usage(); my $tmp=shift @ARGV // usage(); usage() if @ARGV;
$repo=abs_path($repo) // die "resolve repo\n"; make_path($tmp); $tmp=abs_path($tmp) // die "resolve tmp\n";
my $driver=File::Spec->catfile($repo,qw(driver vcsc));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my @cases=(
 ['06_multicolor_score_above_static','multicolor_score_above_static','above','static'],
 ['08_multicolor_full_dynamic_x_motion','multicolor_full_dynamic_x_motion','full','x'],
 ['09_multicolor_score_above_dynamic_x_motion','multicolor_score_above_dynamic_x_motion','above','x'],
 ['10_multicolor_score_below_dynamic_x_motion','multicolor_score_below_dynamic_x_motion','below','x'],
 ['11_multicolor_full_dynamic_x_and_y_motion','multicolor_full_dynamic_x_and_y_motion','full','xy'],
 ['12_multicolor_score_above_dynamic_x_and_y_motion','multicolor_score_above_dynamic_x_and_y_motion','above','xy'],
 ['13_multicolor_score_below_dynamic_x_and_y_motion','multicolor_score_below_dynamic_x_and_y_motion','below','xy'],
);

my $cxx=$ENV{CXX} || 'c++';
my $mos=File::Spec->catdir($repo,qw(simulator mos6502));
my $mos_obj=File::Spec->catfile($mos,'mos6502.o');
my @mos_input=-f $mos_obj ? ($mos_obj) : (File::Spec->catfile($mos,'mos6502.cpp'));
my $hsrc=File::Spec->catfile($repo,qw(test vcs_multicolor_example_matrix.cpp));
my $harness=File::Spec->catfile($tmp,'vcs_multicolor_example_matrix');
my($rc,$sig,$out,$err)=capture($cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,$hsrc,@mos_input,'-o',$harness);
$rc==0 && !$sig or die "matrix harness build failed\n$out$err";
$out eq '' && $err eq '' or die "matrix harness wrote output\n$out$err";

for my $case (@cases) {
   my($dir,$stem,$placement,$motion)=@$case;
   my $src=File::Spec->catfile($repo,'examples',$dir,"$stem.c26");
   my $text=read_file($src);
   $text =~ /^include "color_ntsc\.c26"$/m or die "$dir lacks named NTSC colors\n";
   $text =~ /0b[.X]{8}(?![.X])/ or die "$dir lacks visual sprite glyphs\n";
   if ($placement eq 'full') {
      $text =~ /player_color_192/ or die "$dir does not use player_color_192\n";
      $text !~ /six_glyph_component/ or die "$dir unexpectedly contains a score\n";
   } else {
      $text =~ /player_color_181/ && $text =~ /six_glyph_component/ or die "$dir lacks 181+score composition\n";
      my $score=index($text,'score_draw();'); my $game=index($text,'game_draw();');
      $score>=0 && $game>=0 or die "$dir lacks component draws\n";
      ($placement eq 'above' ? $score<$game : $game<$score) or die "$dir draw order is wrong\n";
      $text =~ /vcs_ntsc_component_handoff\(\)/ or die "$dir lacks component handoff\n";
   }
   if ($motion eq 'static') {
      $text !~ /update_[xy]_motion/ or die "$dir should be static\n";
   } elsif ($motion eq 'x') {
      $text =~ /update_x_motion\(\)/ && $text !~ /update_y_motion\(\)/ or die "$dir is not X-only\n";
   } else {
      $text =~ /update_x_motion\(\)/ && $text =~ /update_y_motion\(\)/ or die "$dir is not X/Y motion\n";
   }
   my $bin=File::Spec->catfile($tmp,"$stem.bin"); my $map=File::Spec->catfile($tmp,"$stem.map");
   ($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-Map',$map,$src,'-o',$bin);
   $rc==0 && !$sig or die "$dir build failed\n$out$err";
   without_usage($out) eq '' && $err eq '' or die "$dir build wrote output\n$out$err";
   length(read_file($bin))==4096 or die "$dir ROM is not 4096 bytes\n";
   my $m=read_file($map);
   my @zp=map { map_zp($m,$_) } qw(game_object_x game_player0_y game_player1_y game_ball_y);
   ($rc,$sig,$out,$err)=capture($harness,$bin,$motion,@zp);
   $rc==0 && !$sig or die "$dir runtime failed\n$out$err";
   $out =~ /^vcs_multicolor_example_matrix \Q$motion\E ok: 8\d stable frames\n$/ or die "$dir unexpected runtime output: $out";
   $err eq '' or die "$dir runtime stderr: $err";
}
print "vcs_multicolor_examples ok: examples 06 and 08-13 nonvisual build, frame, and RAM-motion smoke only; examples 05 and 07 are display-certified separately\n";
