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
   my($s)=@_; $s =~ s/\ACARTRIDGE ROM USAGE\n(?:  [^\n]+\n)+RAM USAGE\n(?:  [^\n]+\n)+//; return $s;
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
my $cfg=File::Spec->catfile($vcs,qw(kernels standard_4k_ntsc vcs_standard_4k_ntsc.cfg));
my $source=File::Spec->catfile($repo,qw(examples 05_multicolor_full_static multicolor_full_static.c26));
my $fixture=File::Spec->catfile($repo,qw(test fixtures player_color_192 smoke.c26));
my $bin=File::Spec->catfile($tmp,'multicolor_full_static.bin');
my $mapfile=File::Spec->catfile($tmp,'multicolor_full_static.map');
my $fixture_bin=File::Spec->catfile($tmp,'player_color_192_smoke.bin');
my $fixture_map=File::Spec->catfile($tmp,'player_color_192_smoke.map');

my $text=read_file($source);
require_re($text,qr/^include "frame_ntsc\.c26"$/m,
   'example 05 does not use the NTSC frame scheduler');
require_re($text,qr/^include "color_ntsc\.c26"$/m,
   'example 05 does not use named NTSC colors');
require_re($text,qr/^include "playfield\.c26"$/m,
   'example 05 does not use visual playfield rows');
require_re($text,qr/template "kernels\/player_color_192\/player_color_192\.c26" as game/,
   'example 05 does not use the full 192-line player-color kernel');
$text !~ /six_glyph_component|score_draw|score_/ or die "example 05 unexpectedly contains score ownership\n";
my @pfrows=$text =~ /VCS_PLAYFIELD_ROW\s*\(/g;
@pfrows==12 or die "example 05 has ".scalar(@pfrows)." playfield rows, expected 12\n";
my @visual=$text =~ /0b[.X]{8}(?![.X])/g;
@visual>=16 or die "example 05 lacks sixteen visual sprite rows\n";
for my $name (qw(
   VCS_NTSC_GOLDENROD VCS_NTSC_SANDY_BROWN VCS_NTSC_LIGHT_CORAL
   VCS_NTSC_ORCHID VCS_NTSC_VIOLET VCS_NTSC_MEDIUM_PURPLE
   VCS_NTSC_MEDIUM_BLUE VCS_NTSC_ROYAL_BLUE VCS_NTSC_SKY_BLUE_2
   VCS_NTSC_SKY_BLUE VCS_NTSC_AQUAMARINE VCS_NTSC_PALE_GREEN
)) {
   $text =~ /\b\Q$name\E\b/ or die "example 05 does not use $name\n";
}

my($rc,$sig,$out,$err)=capture(
   $driver,'-I',$vcs,'-T',$cfg,'-Map',$mapfile,$source,'-o',$bin);
$rc==0 && !$sig or die "example 05 build failed\n$out$err";
without_usage($out) eq '' && $err eq '' or die "example 05 build wrote output\n$out$err";
($rc,$sig,$out,$err)=capture(
   $driver,'-I',$vcs,'-T',$cfg,'-Map',$fixture_map,$fixture,'-o',$fixture_bin);
$rc==0 && !$sig or die "player-color 192 smoke build failed\n$out$err";
without_usage($out) eq '' && $err eq '' or die "player-color 192 smoke build wrote output\n$out$err";
for my $rom ($bin,$fixture_bin) {
   length(read_file($rom))==4096 or die "$rom is not a 4096-byte ROM\n";
}
read_file($bin) eq read_file($fixture_bin)
   or die "example 05 no longer builds the verified player-color 192 smoke cartridge\n";

my $map=read_file($mapfile);
my $cxx=$ENV{CXX} || 'c++';
my $mos=File::Spec->catdir($repo,qw(simulator mos6502));
my $mos_obj=File::Spec->catfile($mos,'mos6502.o');
my @mos_input=-f $mos_obj ? ($mos_obj) : (File::Spec->catfile($mos,'mos6502.cpp'));

my $pixel_src=File::Spec->catfile($repo,qw(test vcs_player_color_181.cpp));
my $pixel_exe=File::Spec->catfile($tmp,'multicolor_full_static_pixels');
($rc,$sig,$out,$err)=capture(
   $cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,$pixel_src,@mos_input,'-o',$pixel_exe);
$rc==0 && !$sig or die "example 05 pixel harness build failed\n$out$err";
$out eq '' && $err eq '' or die "example 05 pixel harness build wrote output\n$out$err";
my @zp=map { map_zp($map,$_) } qw(game_object_x game_player0_y game_player1_y game_ball_y);
($rc,$sig,$out,$err)=capture($pixel_exe,'static',$bin,@zp);
$rc==0 && !$sig or die "example 05 pixel raster failed\n$out$err";
$out eq "vcs_player_color_181 static ok: exact P0/P1 row colors, P0/P1/BL position and pixel endpoints, no missiles\n"
   or die "unexpected example 05 pixel output: $out";
$err eq '' or die "example 05 pixel stderr: $err";

my $display_src=File::Spec->catfile($repo,qw(test vcs_multicolor_display_raster.cpp));
my $display_exe=File::Spec->catfile($tmp,'multicolor_full_static_display');
($rc,$sig,$out,$err)=capture(
   $cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,$display_src,@mos_input,'-o',$display_exe);
$rc==0 && !$sig or die "example 05 display harness build failed\n$out$err";
$out eq '' && $err eq '' or die "example 05 display harness build wrote output\n$out$err";
my @symbols=map { map_symbol($map,$_) }
   qw(game_playfield p0_graphics p1_graphics game_player0_colors game_player1_colors);
($rc,$sig,$out,$err)=capture($display_exe,$bin,'full',@symbols);
$rc==0 && !$sig or die "example 05 display raster failed\n$out$err";
$out eq "vcs_multicolor_display_raster full ok: exact PF rows, glyph bytes/colors, Ball, and score ownership\n"
   or die "unexpected example 05 display output: $out";
$err eq '' or die "example 05 display stderr: $err";

my $phase_src=File::Spec->catfile($repo,qw(test vcs_playfield_phase.cpp));
my $phase_exe=File::Spec->catfile($tmp,'multicolor_full_static_playfield');
($rc,$sig,$out,$err)=capture(
   $cxx,'-std=c++17','-O2','-I',$mos,$phase_src,@mos_input,'-o',$phase_exe);
$rc==0 && !$sig or die "example 05 playfield harness build failed\n$out$err";
$out eq '' && $err eq '' or die "example 05 playfield harness build wrote output\n$out$err";
($rc,$sig,$out,$err)=capture($phase_exe,$bin);
$rc==0 && !$sig or die "example 05 playfield timing failed\n$out$err";
$out eq "vcs_playfield_phase ok: 161 scanlines at cycles 21/28, 22/29, or 24/31,38,45\n"
   or die "unexpected example 05 playfield output: $out";
$err eq '' or die "example 05 playfield stderr: $err";

print "vcs_multicolor_full_static ok: public example 05 matches the verified 192-line smoke ROM, exact display raster, and 262-line frames\n";
