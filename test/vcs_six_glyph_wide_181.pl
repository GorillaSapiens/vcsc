#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 90
# expectstdout: vcs_six_glyph_wide_181 ok: wide score above and below preserve the official 181-line gameplay raster in exact 262-line frames
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Glob qw(bsd_glob);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub usage { die "usage: $0 REPO TMP\n"; }
sub slurp_fh { my($fh)=@_; local $/; return <$fh> // ''; }
sub capture {
   my(@cmd)=@_; my $err=gensym; my $pid=open3(my $in,my $out,$err,@cmd); close($in);
   my $so=slurp_fh($out); my $se=slurp_fh($err); waitpid($pid,0);
   return ($?>>8,$?&127,$so,$se);
}
sub read_file {
   my($path)=@_; open(my $fh,'<:raw',$path) or die "read $path: $!\n";
   local $/; my $text=<$fh>; close($fh); return $text // '';
}
sub without_usage { my($s)=@_; $s =~ s/\AMEMORY USAGE\n(?:  [^\n]+\n)+//; return $s; }
sub map_zp {
   my($map,$name)=@_;
   $map =~ /^\s*\$([0-9A-Fa-f]{4})\s+\Q$name\E\b/m or die "map missing $name\n";
   my $address=hex($1); $address<=0xff or die "$name is not in zero page\n";
   return sprintf('0x%02x',$address);
}

my $repo=shift @ARGV // usage();
my $tmp=shift @ARGV // usage();
usage() if @ARGV;
$repo=abs_path($repo) // die "resolve repo\n";
make_path($tmp);
$tmp=abs_path($tmp) // die "resolve tmp\n";

my $driver=File::Spec->catfile($repo,qw(driver vcsc));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $cxx=$ENV{CXX} || 'c++';
my $mos=File::Spec->catdir($repo,qw(simulator mos6502));
my $mos_obj=File::Spec->catfile($mos,'mos6502.o');
my @mos_input=-f $mos_obj ? ($mos_obj) : (File::Spec->catfile($mos,'mos6502.cpp'));

my $wide_src=File::Spec->catfile($repo,qw(test vcs_six_glyph_wide_raster.cpp));
my $wide_exe=File::Spec->catfile($tmp,'wide_181_score_raster');
my($rc,$sig,$out,$err)=capture($cxx,'-std=c++17','-Wall','-Wextra','-Werror','-pedantic','-O2',
   '-DILLEGAL_OPCODES','-I',$mos,$wide_src,@mos_input,'-o',$wide_exe);
$rc==0 && !$sig or die "wide raster harness build failed\n$out$err";
$out eq '' && $err eq '' or die "wide raster harness build wrote output\n$out$err";

my $game_src=File::Spec->catfile($repo,qw(test vcs_player_color_181.cpp));
my $game_exe=File::Spec->catfile($tmp,'wide_181_gameplay_raster');
($rc,$sig,$out,$err)=capture($cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,
   $game_src,@mos_input,'-o',$game_exe);
$rc==0 && !$sig or die "181-line raster harness build failed\n$out$err";
$out eq '' && $err eq '' or die "181-line raster harness build wrote output\n$out$err";

for my $case (
   ['above','11_wide_score_above',40],
   ['below','12_wide_score_below',221],
) {
   my($order,$directory,$entry)=@$case;
   my $leaf=File::Spec->catdir($repo,'examples','04_player_color_181',$directory,'01_interactive');
   -d $leaf or die "missing public wide-score leaf $leaf\n";
   my @sources=bsd_glob(File::Spec->catfile($leaf,'*.c26'));
   @sources==1 or die "$leaf has ".scalar(@sources)." editable sources, expected one\n";
   my $source_text=read_file($sources[0]);
   $source_text =~ /template\s+"six_glyph_wide_component\.c26"\s+as\s+score\b/
      or die "$sources[0] does not instantiate the wide score\n";
   $source_text =~ /template\s+"renderers\/player_color_181\/player_color_181\.c26"\s+as\s+game\b/
      or die "$sources[0] does not instantiate player_color_181\n";
   my $draw_order=$order eq 'above'
      ? qr/score_draw\(\);.*vcs_ntsc_component_handoff\(\);.*game_draw\(\);/s
      : qr/game_draw\(\);.*vcs_ntsc_component_handoff\(\);.*score_draw\(\);/s;
   $source_text =~ $draw_order or die "$sources[0] has the wrong $order draw order\n";
   $source_text =~ /update_object_selection\(\);.*move_selected_object\(\);.*update_score_controls\(\);/s
      or die "$sources[0] does not use the standard player-color interactive controls\n";
   $source_text =~ /SELECTED_PLAYER0.*SELECTED_PLAYER1.*SELECTED_BALL/s
      && $source_text =~ /right_joystick_countdown := 19;/
      && $source_text =~ /asm eor right_joystick_previous;/
      && $source_text =~ /asm adc #\$10;.*asm sta score_color;/s
      or die "$sources[0] lost Game Select object cycling or filtered right-joystick score controls\n";

   my $tag="wide_181_$order";
   my $bin=File::Spec->catfile($tmp,"$tag.bin");
   my $mapfile=File::Spec->catfile($tmp,"$tag.map");
   ($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-Map',$mapfile,$sources[0],'-o',$bin);
   $rc==0 && !$sig or die "$tag build failed\n$out$err";
   without_usage($out) eq '' && $err eq '' or die "$tag build wrote output\n$out$err";
   -s $bin==4096 or die "$tag is not a 4K cartridge\n";

   my $map=read_file($mapfile);
   $map =~ /rom\s+used=2856 bytes/ or die "$tag ROM accounting changed\n";
   $map =~ /ram\s+used=109 bytes.*objects=101 bytes hardware-stack=8 bytes/
      or die "$tag RAM accounting changed\n";

   ($rc,$sig,$out,$err)=capture($wide_exe,$bin,$entry,'123456');
   $rc==0 && !$sig or die "$tag wide score raster failed\n$out$err";
   $out eq "vcs_six_glyph_wide_raster ok: exact 88x8 score schedule and 262-line frames\n"
      or die "unexpected $tag wide raster output: $out";
   $err eq '' or die "$tag wide raster stderr: $err";

   my @game_zp=map { map_zp($map,$_) }
      qw(game_object_x game_player0_y game_player1_y game_ball_y);
   ($rc,$sig,$out,$err)=capture($game_exe,'static',$bin,@game_zp,"interactive-$order");
   $rc==0 && !$sig or die "$tag gameplay composition failed\n$out$err";
   $out eq "vcs_player_color_181 composition static $order ok\n"
      or die "unexpected $tag gameplay output: $out";
   $err eq '' or die "$tag gameplay stderr: $err";
}

print "vcs_six_glyph_wide_181 ok: wide score above and below preserve the official 181-line gameplay raster in exact 262-line frames\n";
