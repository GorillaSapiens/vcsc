#!/usr/bin/perl
use strict;
use warnings;
use Cwd qw(abs_path);
use Digest::SHA qw(sha256_hex);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub usage { die "usage: $0 REPO TMP\n"; }
sub slurp_fh { my($fh)=@_; local $/; my $d=<$fh>; return defined($d)?$d:''; }
sub capture {
   my(@cmd)=@_; my $err=gensym;
   my $pid=open3(my $in,my $out,$err,@cmd); close($in);
   my $so=slurp_fh($out); my $se=slurp_fh($err);
   waitpid($pid,0); return ($?>>8,$?&127,$so,$se);
}
sub read_file {
   my($path)=@_; open(my $fh,'<:raw',$path) or die "read $path: $!\n";
   local $/; my $d=<$fh>; close($fh); return defined($d)?$d:'';
}
sub without_usage {
   my($s)=@_;
   $s =~ s/\ACARTRIDGE ROM USAGE\n(?:  [^\n]+\n)+RAM USAGE\n(?:  [^\n]+\n)+//;
   return $s;
}
sub require_re { my($s,$re,$why)=@_; $s =~ $re or die "$why\n"; }
sub map_symbol {
   my($map,$name)=@_;
   $map =~ /^\s*\$([0-9A-Fa-f]{4})\s+\Q$name\E\b/m
      or die "map missing $name\n";
   return sprintf('0x%04x',hex($1));
}
sub build {
   my($driver,$vcs,$source,$bin,$map)=@_;
   my($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-Map',$map,$source,'-o',$bin);
   $rc==0 && !$sig or die "build failed for $source\n$out$err";
   without_usage($out) eq '' && $err eq '' or die "build wrote output for $source\n$out$err";
   length(read_file($bin))==4096 or die "$source did not produce a 4096-byte ROM\n";
}

my $repo=shift @ARGV // usage();
my $tmp=shift @ARGV // usage();
usage() if @ARGV;
$repo=abs_path($repo) // die "resolve repo\n";
make_path($tmp);
$tmp=abs_path($tmp) // die "resolve tmp\n";

my $driver=File::Spec->catfile($repo,qw(driver vcsc));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $example=File::Spec->catdir($repo,qw(examples 05_multicolor_full_static));
my $source=File::Spec->catfile($example,'multicolor_full_static.c26');
my $fixture=File::Spec->catdir($repo,qw(test fixtures vcs_examples 05_multicolor_full_static));
my $golden=File::Spec->catfile($fixture,'golden.c26');
my $reference=File::Spec->catfile($fixture,'reference_stella_7.0.png');
my $bin=File::Spec->catfile($tmp,'multicolor_full_static.bin');
my $map=File::Spec->catfile($tmp,'multicolor_full_static.map');
my $goldbin=File::Spec->catfile($tmp,'multicolor_full_static_golden.bin');
my $goldmap=File::Spec->catfile($tmp,'multicolor_full_static_golden.map');

my $text=read_file($source);
require_re($text,qr/^include "color_ntsc\.c26"$/m,'example 05 does not use named NTSC colors');
require_re($text,qr/^include "playfield\.c26"$/m,'example 05 does not use visual playfield rows');
require_re($text,qr/template "kernels\/player_color_192\/player_color_192\.c26" as game/,
   'example 05 does not use the full-height player-color kernel');
$text !~ /six_glyph_component/ or die "example 05 unexpectedly links a score component\n";
my @pfrows=$text =~ /VCS_PLAYFIELD_ROW\s*\(/g;
@pfrows==12 or die "example 05 has ".scalar(@pfrows)." playfield rows, expected 12\n";
require_re($text,qr/0b\.\.XXXX\.\./,'example 05 lost the readable A glyph');
require_re($text,qr/0b\.XXXXX\.\./,'example 05 lost the readable B glyph');
for my $locked (
   [qr/game_PLAYER0_X\s*:=\s*44\s*;/,'P0 X'],
   [qr/game_PLAYER1_X\s*:=\s*108\s*;/,'P1 X'],
   [qr/game_BALL_X\s*:=\s*78\s*;/,'Ball X'],
   [qr/game_player0_y\s*:=\s*48\s*;/,'P0 Y'],
   [qr/game_player1_y\s*:=\s*48\s*;/,'P1 Y'],
   [qr/game_ball_y\s*:=\s*50\s*;/,'Ball Y'],
   [qr/COLUBK\s*:=\s*VCS_NTSC_MEDIUM_BLUE\s*;/,'background'],
   [qr/COLUPF\s*:=\s*VCS_NTSC_GOLDENROD\s*;/,'playfield color'],
) { require_re($text,$locked->[0],"example 05 changed $locked->[1]"); }
require_re(read_file(File::Spec->catfile($vcs,'color_ntsc.c26')),
   qr/VCS_NTSC_MEDIUM_BLUE\s+__builtin_ntsc_rgb\(0x24,\s*0x28,\s*0xb0\).*TIA 0x84/,
   'named medium-blue alias no longer folds to TIA $84');

build($driver,$vcs,$source,$bin,$map);
build($driver,$vcs,$golden,$goldbin,$goldmap);

my $cxx=$ENV{CXX} || 'c++';
my $mos=File::Spec->catdir($repo,qw(simulator mos6502));
my $mos_obj=File::Spec->catfile($mos,'mos6502.o');
my @mos_input=-f $mos_obj ? ($mos_obj) : (File::Spec->catfile($mos,'mos6502.cpp'));

my $trace_src=File::Spec->catfile($repo,qw(test vcs_visible_trace_compare.cpp));
my $trace=File::Spec->catfile($tmp,'vcs_visible_trace_compare');
my($rc,$sig,$out,$err)=capture($cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,
   $trace_src,@mos_input,'-o',$trace);
$rc==0 && !$sig or die "trace comparator build failed\n$out$err";
$out eq '' && $err eq '' or die "trace comparator build wrote output\n$out$err";
($rc,$sig,$out,$err)=capture($trace,$goldbin,$bin,262,262);
$rc==0 && !$sig or die "example 05 differs from its raw-byte golden trace\n$out$err";
$out eq "vcs_visible_trace_compare ok: 1132 events and 42 stable frames per ROM\n"
   or die "unexpected trace result: $out";
$err eq '' or die "trace comparator stderr: $err";

my $raster_src=File::Spec->catfile($repo,qw(test vcs_multicolor_display_raster.cpp));
my $raster=File::Spec->catfile($tmp,'vcs_multicolor_display_raster');
($rc,$sig,$out,$err)=capture($cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,
   $raster_src,@mos_input,'-o',$raster);
$rc==0 && !$sig or die "display-raster harness build failed\n$out$err";
$out eq '' && $err eq '' or die "display-raster harness build wrote output\n$out$err";
my $map_text=read_file($map);
my @symbols=map { map_symbol($map_text,$_) }
   qw(game_playfield p0_graphics p1_graphics game_player0_colors game_player1_colors);
($rc,$sig,$out,$err)=capture($raster,$bin,'full',@symbols);
$rc==0 && !$sig or die "example 05 display-raster verification failed\n$out$err";
$out eq "vcs_multicolor_display_raster full ok: exact PF rows, glyph bytes/colors, Ball, and score ownership\n"
   or die "unexpected display-raster result: $out";
$err eq '' or die "display-raster stderr: $err";

my $png=read_file($reference);
substr($png,0,8) eq "\x89PNG\r\n\x1a\n" or die "example 05 reference is not PNG\n";
my($width,$height)=unpack('NN',substr($png,16,8));
$width==320 && $height==228 or die "example 05 reference is ${width}x${height}, expected 320x228\n";
sha256_hex($png) eq '54c455652f0859094429296244781a7f1e835696f3647c5dafa6cc184baa5bf5'
   or die "reviewed example 05 Stella reference changed\n";

print "vcs_multicolor_full_static ok: raw-byte trace, all 12 PF rows, A/B colors, Ball, and reviewed Stella image\n";
