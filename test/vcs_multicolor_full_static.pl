#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 10
# expectstdout: vcs_multicolor_full_static ok: player_color_192 interactive example starts with a 262-line exact asymmetric raster containing P0, P1, Ball, and no missiles
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub usage { die "usage: $0 REPO TMP\n"; }
sub slurp_fh { my($fh)=@_; local $/; my $d=<$fh>; return defined($d)?$d:''; }
sub capture {
   my(@cmd)=@_; my $err=gensym; my $pid=open3(my $in,my $out,$err,@cmd); close($in);
   my $so=slurp_fh($out); my $se=slurp_fh($err); waitpid($pid,0);
   return ($? >> 8,$? & 127,$so,$se);
}
sub read_file {
   my($p)=@_; open(my $f,'<:raw',$p) or die "read $p: $!\n";
   local $/; my $d=<$f>; close($f); return defined($d)?$d:'';
}
sub without_usage {
   my($s)=@_; $s =~ s/\AMEMORY USAGE\n(?:  [^\n]+\n)+//; return $s;
}
sub require_re { my($s,$re,$why)=@_; $s =~ $re or die "$why\n"; }
sub map_zp {
   my($map,$name)=@_;
   $map =~ /^\s*\$([0-9A-Fa-f]{4})\s+\Q$name\E\b/m or die "map missing $name\n";
   my $v=hex($1); $v<=0xff or die "$name is not zero-page\n";
   return sprintf('0x%02x',$v);
}
sub map_symbol {
   my($map,$name)=@_;
   $map =~ /^\s*\$([0-9A-Fa-f]{4})\s+\Q$name\E\b/m or die "map missing $name\n";
   return sprintf('0x%04x',hex($1));
}

my $repo=shift @ARGV // usage();
my $tmp=shift @ARGV // usage();
usage() if @ARGV;
$repo=abs_path($repo) // die "resolve repository\n";
make_path($tmp);
$tmp=abs_path($tmp) // die "resolve temporary directory\n";

my $driver=File::Spec->catfile($repo,qw(driver vcsc));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $cfg=File::Spec->catfile($vcs,qw(renderers standard_4k_ntsc vcs_standard_4k_ntsc.cfg));
my $source=File::Spec->catfile($repo,qw(examples 03_player_color_192 01_interactive player_color_192_interactive.c26));
my $bin=File::Spec->catfile($tmp,'multicolor_full_static.bin');
my $mapfile=File::Spec->catfile($tmp,'multicolor_full_static.map');

my $text=read_file($source);
require_re($text,qr/^include "frame_ntsc\.c26"$/m,
   'player_color_192 interactive example does not use the NTSC frame scheduler');
require_re($text,qr/^include "color_ntsc\.c26"$/m,
   'player_color_192 interactive example does not use named NTSC colors');
require_re($text,qr/^include "playfield\.c26"$/m,
   'player_color_192 interactive example does not use visual playfield rows');
require_re($text,qr/template "renderers\/player_color_192\/player_color_192\.c26" as game/,
   'player_color_192 interactive example does not use the full 192-line player-color renderer');
$text !~ /six_glyph_component|score_draw|score_/ or die "player_color_192 interactive example unexpectedly contains score ownership\n";
my @pfrows=$text =~ /VCS_PLAYFIELD_ROW\s*\(/g;
@pfrows==12 or die "player_color_192 interactive example has ".scalar(@pfrows)." playfield rows, expected 12\n";
my @visual=$text =~ /0b[.X]{8}(?![.X])/g;
@visual>=16 or die "player_color_192 interactive example lacks sixteen visual sprite rows\n";
for my $name (qw(
   VCS_NTSC_GOLDENROD VCS_NTSC_SANDY_BROWN VCS_NTSC_LIGHT_CORAL
   VCS_NTSC_ORCHID VCS_NTSC_VIOLET VCS_NTSC_MEDIUM_PURPLE
   VCS_NTSC_MEDIUM_BLUE VCS_NTSC_ROYAL_BLUE VCS_NTSC_SKY_BLUE_2
   VCS_NTSC_SKY_BLUE VCS_NTSC_AQUAMARINE VCS_NTSC_PALE_GREEN
)) {
   $text =~ /\b\Q$name\E\b/ or die "player_color_192 interactive example does not use $name\n";
}

my($rc,$sig,$out,$err)=capture(
   $driver,'-I',$vcs,'-T',$cfg,'-Map',$mapfile,$source,'-o',$bin);
$rc==0 && !$sig or die "player_color_192 interactive example build failed\n$out$err";
without_usage($out) eq '' && $err eq '' or die "player_color_192 interactive example build wrote output\n$out$err";
length(read_file($bin))==4096 or die "player_color_192 interactive example ROM is not 4096 bytes\n";

my $map=read_file($mapfile);
my $cxx=$ENV{CXX} || 'c++';
my $mos=File::Spec->catdir($repo,qw(simulator mos6502));
my $mos_obj=File::Spec->catfile($mos,'mos6502.o');
my @mos_input=-f $mos_obj ? ($mos_obj) : (File::Spec->catfile($mos,'mos6502.cpp'));

my $pixel_src=File::Spec->catfile($repo,qw(test vcs_player_color_192.cpp));
my $pixel_exe=File::Spec->catfile($tmp,'multicolor_full_static_pixels');
($rc,$sig,$out,$err)=capture(
   $cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,$pixel_src,@mos_input,'-o',$pixel_exe);
$rc==0 && !$sig or die "player_color_192 interactive example pixel harness build failed\n$out$err";
$out eq '' && $err eq '' or die "player_color_192 interactive example pixel harness build wrote output\n$out$err";
my @zp=map { map_zp($map,$_) } qw(game_object_x game_player0_y game_player1_y game_ball_y);
($rc,$sig,$out,$err)=capture($pixel_exe,'static-alien',$bin,@zp);
$rc==0 && !$sig or die "player_color_192 interactive example pixel raster failed\n$out$err";
$out eq "vcs_player_color_192 static ok: exact 192-line frame, VBLANK positioning, P0/P1 rows, Ball, and no missiles\n"
   or die "unexpected player_color_192 interactive example pixel output: $out";
$err eq '' or die "player_color_192 interactive example pixel stderr: $err";

my $display_src=File::Spec->catfile($repo,qw(test vcs_multicolor_display_raster.cpp));
my $display_exe=File::Spec->catfile($tmp,'multicolor_full_static_display');
($rc,$sig,$out,$err)=capture(
   $cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,$display_src,@mos_input,'-o',$display_exe);
$rc==0 && !$sig or die "player_color_192 interactive example display harness build failed\n$out$err";
$out eq '' && $err eq '' or die "player_color_192 interactive example display harness build wrote output\n$out$err";
my @display_symbols=map { map_symbol($map,$_) }
   qw(game_playfield p0_graphics p1_graphics game_player0_colors game_player1_colors);
($rc,$sig,$out,$err)=capture($display_exe,$bin,'full',@display_symbols);
$rc==0 && !$sig or die "player_color_192 interactive example display raster failed\n$out$err";
$out eq "vcs_multicolor_display_raster full ok: exact PF rows, glyph bytes/colors, Ball, and score ownership\n"
   or die "unexpected player_color_192 interactive example display output: $out";
$err eq '' or die "player_color_192 interactive example display stderr: $err";

print "vcs_multicolor_full_static ok: player_color_192 interactive example starts with a 262-line exact asymmetric raster containing P0, P1, Ball, and no missiles\n";
