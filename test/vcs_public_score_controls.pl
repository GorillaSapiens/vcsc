#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 120
# expectstdout: vcs_public_score_controls ok: 16 left/right six-digit and 8 two-plus-two public examples share tested color, selection, and independent-field controls
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Basename qw(basename);
use File::Glob qw(bsd_glob);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub usage { die "usage: $0 REPO TMP\n"; }
sub slurp_fh { my($fh)=@_; local $/; my $d=<$fh>; return defined($d)?$d:''; }
sub capture { my(@cmd)=@_; my $err=gensym; my $pid=open3(my $in,my $out,$err,@cmd); close($in); my $so=slurp_fh($out); my $se=slurp_fh($err); waitpid($pid,0); return ($?>>8,$?&127,$so,$se); }
sub read_file { my($p)=@_; open(my $f,'<:raw',$p) or die "read $p: $!\n"; local $/; my $d=<$f>; close($f); return defined($d)?$d:''; }
sub without_usage { my($s)=@_; $s =~ s/\AMEMORY USAGE\n(?:  [^\n]+\n)+//; return $s; }
sub map_zp { my($map,$name)=@_; $map =~ /^\s*\$([0-9A-Fa-f]{4})\s+\Q$name\E\b/m or die "map missing $name\n"; my $v=hex($1); $v<=0xff or die "$name is not zero-page\n"; return sprintf('0x%02x',$v); }

my $repo=shift @ARGV // usage(); my $tmp=shift @ARGV // usage(); usage() if @ARGV;
$repo=abs_path($repo) // die "resolve repo\n"; make_path($tmp); $tmp=abs_path($tmp) // die "resolve tmp\n";
my $driver=File::Spec->catfile($repo,qw(driver vcsc));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $cxx=$ENV{CXX} || 'c++';
my $mos=File::Spec->catdir($repo,qw(simulator mos6502));
my $mos_obj=File::Spec->catfile($mos,'mos6502.o');
my @mos_input=-f $mos_obj ? ($mos_obj) : (File::Spec->catfile($mos,'mos6502.cpp'));

my $six_harness=File::Spec->catfile($tmp,'vcs_public_six_digit_controls');
my $six_src=File::Spec->catfile($repo,qw(test vcs_multicolor_example_matrix.cpp));
my($rc,$sig,$out,$err)=capture($cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,$six_src,@mos_input,'-o',$six_harness);
$rc==0 && !$sig or die "six-digit harness build failed\n$out$err";
$out eq '' && $err eq '' or die "six-digit harness build wrote output\n$out$err";

my $split_harness=File::Spec->catfile($tmp,'vcs_public_two_plus_two_controls');
my $split_src=File::Spec->catfile($repo,qw(test vcs_two_plus_two_controls.cpp));
($rc,$sig,$out,$err)=capture($cxx,'-std=c++17','-Wall','-Wextra','-Werror','-pedantic','-O2','-DILLEGAL_OPCODES','-I',$mos,$split_src,@mos_input,'-o',$split_harness);
$rc==0 && !$sig or die "two-plus-two harness build failed\n$out$err";
$out eq '' && $err eq '' or die "two-plus-two harness build wrote output\n$out$err";

my @families=qw(04_player_color_181 06_all_five_181 07_player_color_181_unofficial 08_all_five_181_unofficial);
my @six_layouts=qw(03_left_justified_score_above 04_left_justified_score_below 05_right_justified_score_above 06_right_justified_score_below);
my @split_layouts=qw(07_two_plus_two_score_above 08_two_plus_two_score_below);
my $six_public=0; my $split_public=0;
for my $family (@families) {
   for my $layout (@six_layouts) {
      my $leaf=File::Spec->catdir($repo,'examples',$family,$layout,'01_interactive');
      my @sources=bsd_glob(File::Spec->catfile($leaf,'*.c26'));
      @sources==1 or die "$leaf does not have exactly one source\n";
      my $text=read_file($sources[0]);
      $text =~ /include "\.\.\/\.\.\/\.\.\/common\/fixed_six_digit_controls\.c26"/
         or die "$sources[0] does not use the shared mutable-color six-digit controls\n";
      ++$six_public;
   }
   for my $layout (@split_layouts) {
      my $leaf=File::Spec->catdir($repo,'examples',$family,$layout,'01_interactive');
      my @sources=bsd_glob(File::Spec->catfile($leaf,'*.c26'));
      @sources==1 or die "$leaf does not have exactly one source\n";
      my $text=read_file($sources[0]);
      $text =~ /include "\.\.\/\.\.\/\.\.\/common\/two_plus_two_controls\.c26"/
         or die "$sources[0] does not use the shared field-selection controls\n";
      ++$split_public;
   }
}
$six_public==16 or die "found $six_public six-digit control examples, expected 16\n";
$split_public==8 or die "found $split_public two-plus-two control examples, expected 8\n";

sub build_public {
   my($family,$layout,$tag)=@_;
   my $leaf=File::Spec->catdir($repo,'examples',$family,$layout,'01_interactive');
   my @sources=bsd_glob(File::Spec->catfile($leaf,'*.c26'));
   my $bin=File::Spec->catfile($tmp,"$tag.bin");
   my $mapfile=File::Spec->catfile($tmp,"$tag.map");
   my @extra=$family =~ /unofficial/ ? ('-Wa,--illegals') : ();
   my($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-I',$leaf,'-Map',$mapfile,@extra,$sources[0],'-o',$bin);
   $rc==0 && !$sig or die "$tag build failed\n$out$err";
   without_usage($out) eq '' && $err eq '' or die "$tag build wrote output\n$out$err";
   return ($bin,read_file($mapfile));
}

for my $case (
   ['03_left_justified_score_above','left'],
   ['05_right_justified_score_above','right'],
) {
   my($bin,$map)=build_public('04_player_color_181',$case->[0],$case->[1]);
   my @args=($six_harness,$bin,'above',map { map_zp($map,$_) }
      qw(game_object_x game_player0_y game_player1_y game_ball_y selected_object select_switch_ready score_score selected_score_digit right_joystick_ready score_color));
   ($rc,$sig,$out,$err)=capture(@args);
   $rc==0 && !$sig or die "$case->[1] runtime failed\n$out$err";
   $out =~ /^vcs_multicolor_example_matrix above ok: interactive controls and reset across \d+ frames\n$/
      or die "$case->[1] unexpected runtime output: $out";
   $err eq '' or die "$case->[1] runtime stderr: $err";
}

my($split_bin,$split_map)=build_public('04_player_color_181','07_two_plus_two_score_above','two_plus_two');
my @split_args=($split_harness,$split_bin,map { map_zp($split_map,$_) }
   qw(score_left_score score_right_score score_left_color score_right_color score_left_x score_right_x selected_score_field right_score_fire_ready right_joystick_ready));
($rc,$sig,$out,$err)=capture(@split_args);
$rc==0 && !$sig or die "two-plus-two runtime failed\n$out$err";
$out =~ /^vcs_two_plus_two_controls ok: both fields selected, highlighted, moved, and changed independently across \d+ frames\n$/
   or die "unexpected two-plus-two runtime output: $out";
$err eq '' or die "two-plus-two runtime stderr: $err";

print "vcs_public_score_controls ok: 16 left/right six-digit and 8 two-plus-two public examples share tested color, selection, and independent-field controls\n";
