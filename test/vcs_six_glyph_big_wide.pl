#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 45
# expectstdout: vcs_six_glyph_big_wide ok: exact 88x16 score schedule and 262-line frames
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub slurp_fh { my($fh)=@_; local $/; return <$fh> // ''; }
sub capture {
   my(@cmd)=@_; my $err=gensym; my $pid=open3(my $in,my $out,$err,@cmd); close($in);
   my $so=slurp_fh($out); my $se=slurp_fh($err); waitpid($pid,0);
   return ($?>>8,$?&127,$so,$se);
}
sub read_file {
   my($path)=@_; open(my $fh,'<:raw',$path) or die "read $path: $!\n";
   local $/; my $data=<$fh>; close($fh); return $data // '';
}
sub without_usage { my($s)=@_; $s =~ s/\AMEMORY USAGE\n(?:  [^\n]+\n)+//; return $s; }

my $repo=abs_path(shift @ARGV // die "usage: $0 REPO TMP\n");
my $tmp=shift @ARGV // die "usage: $0 REPO TMP\n";
@ARGV and die "usage: $0 REPO TMP\n";
make_path($tmp); $tmp=abs_path($tmp) // die "resolve tmp\n";
my $driver=File::Spec->catfile($repo,qw(driver vcsc));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $component=File::Spec->catfile($vcs,'six_glyph_big_wide_component.c26');
my $public=File::Spec->catfile($repo,qw(examples 01_basic 07_big_wide_score big_wide_score.c26));
my $bin=File::Spec->catfile($tmp,'big_wide_score.bin');
my $map=File::Spec->catfile($tmp,'big_wide_score.map');

my $source=read_file($component);
for my $contract (
   'TEMPLATE_GLYPH_ORIGIN_0 := 36', 'TEMPLATE_GLYPH_ORIGIN_1 := 52',
   'TEMPLATE_GLYPH_ORIGIN_2 := 68', 'TEMPLATE_GLYPH_ORIGIN_3 := 84',
   'TEMPLATE_GLYPH_ORIGIN_4 := 100', 'TEMPLATE_GLYPH_ORIGIN_5 := 116',
   'TEMPLATE_GLYPH_WIDTH := 8',
   'TEMPLATE_GLYPH_ORIGIN_PITCH := 16') {
   index($source,$contract)>=0 or die "big-wide component lost contract '$contract'\n";
}
$source =~ /parameter\s+glyph_rows\s*:=\s*16/ &&
$source =~ /TEMPLATE_GLYPH_HEIGHT\s*:=\s*TEMPLATE_glyph_rows/ &&
$source =~ /#elif TEMPLATE_glyph_rows == 16\s*\nalias TEMPLATE_VISIBLE_SCANLINES_VALUE 19/ &&
$source =~ /TEMPLATE_VISIBLE_SCANLINES\s*:=\s*TEMPLATE_VISIBLE_SCANLINES_VALUE/ &&
$source =~ /TEMPLATE_DRAW_COMPLETE_SCANLINES\s*:=\s*TEMPLATE_VISIBLE_SCANLINES_VALUE/
   or die "big-wide component lost glyph_rows default-height contract\n";
$source =~ /uint16_t\s+TEMPLATE_pointers\[6\].*uint8_t\s+TEMPLATE_row.*uint8_t\s+TEMPLATE_delayed/s
   or die "big-wide component lost six-pointer/row/delayed storage\n";
$source =~ /#elif TEMPLATE_glyph_rows == 16\s*\n\s*asm lda #15;.*asm sta\.a TEMPLATE_row;.*asm bpl\.same \@TEMPLATE_draw_loop;/s
   or die "big-wide component lost sixteen-row cycle-counted loop\n";
$source =~ /asm lda #\$06;\s*asm sta NUSIZ0;\s*asm sta NUSIZ1;/s
   or die "big-wide component lost wide copy geometry\n";

my($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-T',File::Spec->catfile($vcs,'vcs.cfg'),'-Map',$map,$public,'-o',$bin);
$rc==0 && !$sig or die "big-wide example build failed\n$out$err";
without_usage($out) eq '' && $err eq '' or die "big-wide example wrote output\n$out$err";
-s $bin==2048 or die "big-wide public example is not 2048 bytes\n";
my $map_text=read_file($map);
$map_text =~ /rom\s+used=1112 bytes/ or die "big-wide ROM accounting changed\n";
$map_text =~ /ram\s+used=35 bytes.*objects=31 bytes hardware-stack=4 bytes/ or die "big-wide RAM accounting changed\n";
$map_text =~ /score_pointers\s+run=\$[0-9A-Fa-f]+ size=\$000C/ or die "big-wide pointer allocation changed\n";
$map_text =~ /score_row\s+run=\$[0-9A-Fa-f]+ size=\$0001/ or die "big-wide row allocation changed\n";
$map_text =~ /score_delayed\s+run=\$[0-9A-Fa-f]+ size=\$0001/ or die "big-wide delayed allocation changed\n";

my $cxx=$ENV{CXX} || 'c++';
my $mos=File::Spec->catdir($repo,qw(simulator mos6502));
my $mos_obj=File::Spec->catfile($mos,'mos6502.o');
my @mos_input=-f $mos_obj ? ($mos_obj) : (File::Spec->catfile($mos,'mos6502.cpp'));
my $hsrc=File::Spec->catfile($repo,qw(test vcs_six_glyph_big_wide_raster.cpp));
my $harness=File::Spec->catfile($tmp,'vcs_six_glyph_big_wide_raster');
($rc,$sig,$out,$err)=capture($cxx,'-std=c++17','-Wall','-Wextra','-Werror','-pedantic','-O2',
   '-DILLEGAL_OPCODES','-I',$mos,$hsrc,@mos_input,'-o',$harness);
$rc==0 && !$sig or die "big-wide raster harness build failed\n$out$err";
$out eq '' && $err eq '' or die "big-wide raster harness wrote output\n$out$err";
($rc,$sig,$out,$err)=capture($harness,$bin,'127','123456');
$rc==0 && !$sig or die "big-wide exact raster failed\n$out$err";
$out eq "vcs_six_glyph_big_wide_raster ok: exact 88x16 score schedule and 262-line frames\n"
   or die "unexpected big-wide raster output: $out";
$err eq '' or die "big-wide raster stderr: $err";

print "vcs_six_glyph_big_wide ok: exact 88x16 score schedule and 262-line frames\n";
