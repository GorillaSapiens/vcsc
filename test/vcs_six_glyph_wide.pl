#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 45
# expectstdout: vcs_six_glyph_wide ok
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use Digest::SHA qw(sha256_hex);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub usage { die "usage: $0 REPO TMP\n"; }
sub slurp_fh { my($f)=@_; local $/; return <$f> // ''; }
sub capture {
   my(@c)=@_; my $e=gensym; my $p=open3(my $i,my $o,$e,@c); close($i);
   my $so=slurp_fh($o); my $se=slurp_fh($e); waitpid($p,0);
   return ($?>>8,$?&127,$so,$se);
}
sub read_file {
   my($p)=@_; open(my $f,'<:raw',$p) or die "read $p: $!\n";
   local $/; my $d=<$f>; close($f); return $d // '';
}
sub write_file {
   my($p,$d)=@_; open(my $f,'>:raw',$p) or die "write $p: $!\n";
   print {$f} $d or die "write $p: $!\n"; close($f) or die "close $p: $!\n";
}
sub without_usage { my($s)=@_; $s =~ s/\AMEMORY USAGE\n(?:  [^\n]+\n)+//; return $s; }

my $repo=shift @ARGV // usage(); my $tmp=shift @ARGV // usage(); usage() if @ARGV;
$repo=abs_path($repo) // die "resolve repo\n";
$tmp=abs_path($tmp) // die "resolve tmp\n";
my $driver=File::Spec->catfile($repo,qw(driver vcsc));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $component=File::Spec->catfile($vcs,'six_glyph_wide_component.c26');
my $centered=File::Spec->catfile($vcs,'six_glyph_component.c26');
my $fixture=File::Spec->catfile($repo,qw(test fixtures vcs_examples 05_wide_score golden.c26));
my $reference=File::Spec->catfile($repo,qw(test fixtures vcs_examples 05_wide_score reference_stella_7.0.png));
my $public=File::Spec->catfile($repo,qw(examples 01_basic 06_wide_score wide_score.c26));
my $bin=File::Spec->catfile($tmp,'wide_score.bin');
my $map=File::Spec->catfile($tmp,'wide_score.map');
my $public_bin=File::Spec->catfile($tmp,'wide_score_public.bin');
my $public_map=File::Spec->catfile($tmp,'wide_score_public.map');
my $compat_src=File::Spec->catfile($tmp,'wide_score_compat.c26');
my $compat_bin=File::Spec->catfile($tmp,'wide_score_compat.bin');
my $compat_map=File::Spec->catfile($tmp,'wide_score_compat.map');

my $source=read_file($component);
for my $contract (
   'TEMPLATE_GLYPH_ORIGIN_0 := 36', 'TEMPLATE_GLYPH_ORIGIN_1 := 52',
   'TEMPLATE_GLYPH_ORIGIN_2 := 68', 'TEMPLATE_GLYPH_ORIGIN_3 := 84',
   'TEMPLATE_GLYPH_ORIGIN_4 := 100', 'TEMPLATE_GLYPH_ORIGIN_5 := 116',
   'TEMPLATE_GLYPH_WIDTH := 8', 'TEMPLATE_GLYPH_ORIGIN_PITCH := 16') {
   index($source,$contract)>=0 or die "wide component lost contract '$contract'\n";
}
$source =~ /parameter\s+glyph_rows\s*:=\s*8/ &&
$source =~ /#elif TEMPLATE_glyph_rows == 8\s*\nalias TEMPLATE_VISIBLE_SCANLINES_VALUE 11/ &&
$source =~ /TEMPLATE_VISIBLE_SCANLINES\s*:=\s*TEMPLATE_VISIBLE_SCANLINES_VALUE/ &&
$source =~ /TEMPLATE_DRAW_COMPLETE_SCANLINES\s*:=\s*TEMPLATE_VISIBLE_SCANLINES_VALUE/
   or die "wide component lost glyph_rows default-height contract\n";
$source =~ /asm lda #\$06;\s*asm sta NUSIZ0;\s*asm sta NUSIZ1;/s
   or die "wide component lost three-medium-copy setup\n";
$source =~ /parameter\s+compact_font\s*:=\s*1/ &&
$source =~ /#if TEMPLATE_compact_font.*uint16_t\s+TEMPLATE_pointers\[5\].*uint8_t\s+TEMPLATE_offset2.*#else.*uint16_t\s+TEMPLATE_pointers\[6\].*uint8_t\s+TEMPLATE_row.*#endif/s
   or die "wide component lost compact/full-pointer storage modes\n";
$source =~ /recommend uint8_t TEMPLATE_color := 0x0e;/
   && $source =~ /asm lda TEMPLATE_color;\s*asm sta COLUP0;\s*asm sta COLUP1;/s
   or die "wide component lost mutable color support\n";
$source =~ /VDELP0 := 1;.*VDELP1 := 1;/s
   or die "wide component lost the delayed-player pipeline\n";
sha256_hex(read_file($centered)) eq '48fca77d69ddbb12a087f11d4c4dfbc145572570a4ec95957f160a89dc9d1e5f'
   or die "centered six-glyph component changed while adding the wide profile\n";

my($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-Map',$map,$fixture,'-o',$bin);
$rc==0 && !$sig or die "wide fixture build failed\n$out$err";
without_usage($out) eq '' && $err eq '' or die "wide fixture build wrote output\n$out$err";
-s $bin==4096 or die "wide fixture is not 4096 bytes\n";
my $map_text=read_file($map);
$map_text =~ /rom\s+used=1245 bytes/ or die "wide fixture ROM accounting changed\n";
$map_text =~ /ram\s+used=27 bytes.*objects=23 bytes hardware-stack=4 bytes/ or die "wide fixture RAM accounting changed\n";
$map_text =~ /score_pointers\s+run=\$[0-9A-Fa-f]+ size=\$000A/ or die "wide pointer allocation changed\n";
$map_text =~ /score_offset2\s+run=\$[0-9A-Fa-f]+ size=\$0001/ or die "wide offset allocation changed\n";
$map_text !~ /score_row\b/ or die "wide row allocation returned\n";
$map_text =~ /score_delayed\s+run=\$[0-9A-Fa-f]+ size=\$0001/ or die "wide delayed-byte allocation changed\n";
$map_text =~ /BSS\.__vcsc_object\$score_score\s+run=\$[0-9A-Fa-f]+ size=\$0003/ or die "wide packed-BCD score allocation changed\n";
$map_text =~ /score_color\s+load=\$[0-9A-Fa-f]+ run=\$[0-9A-Fa-f]+ size=\$0001/ or die "wide mutable color allocation changed\n";

my $compat_text=read_file($fixture);
$compat_text =~ s/instantiate\s+"six_glyph_wide_component\.c26"\s+as\s+score/instantiate "six_glyph_wide_component.c26" as score (compact_font:=0)/
   or die "wide fixture instantiate was not found for compatibility probe\n";
write_file($compat_src,$compat_text);
($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-Map',$compat_map,$compat_src,'-o',$compat_bin);
$rc==0 && !$sig or die "wide full-pointer compatibility build failed\n$out$err";
without_usage($out) eq '' && $err eq '' or die "wide full-pointer compatibility build wrote output\n$out$err";
my $compat_map_text=read_file($compat_map);
$compat_map_text =~ /score_pointers\s+run=\$[0-9A-Fa-f]+ size=\$000C/
   or die "wide full-pointer compatibility allocation is not six pointers\n";
$compat_map_text =~ /score_row\s+run=\$[0-9A-Fa-f]+ size=\$0001/
   or die "wide full-pointer compatibility row allocation is missing\n";
$compat_map_text !~ /score_offset2\b/
   or die "wide full-pointer compatibility still allocated compact offset storage\n";

($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-T',File::Spec->catfile($vcs,'vcs.cfg'),'-Map',$public_map,$public,'-o',$public_bin);
$rc==0 && !$sig or die "public wide example build failed\n$out$err";
without_usage($out) eq '' && $err eq '' or die "public wide example wrote output\n$out$err";
-s $public_bin==2048 or die "public wide example is not 2048 bytes\n";
my $public_map_text=read_file($public_map);
$public_map_text =~ /rom\s+used=1321 bytes/ or die "public wide example ROM accounting changed\n";
$public_map_text =~ /ram\s+used=33 bytes.*objects=29 bytes hardware-stack=4 bytes/ or die "public wide example RAM accounting changed\n";

my $cxx=$ENV{CXX} || 'c++';
my $mos=File::Spec->catdir($repo,qw(simulator mos6502));
my $mos_obj=File::Spec->catfile($mos,'mos6502.o');
my @mos_input=-f $mos_obj ? ($mos_obj) : (File::Spec->catfile($mos,'mos6502.cpp'));
my $hsrc=File::Spec->catfile($repo,qw(test vcs_six_glyph_wide_raster.cpp));
my $harness=File::Spec->catfile($tmp,'vcs_six_glyph_wide_raster');
($rc,$sig,$out,$err)=capture($cxx,'-std=c++17','-Wall','-Wextra','-Werror','-pedantic','-O2',
   '-DILLEGAL_OPCODES','-I',$mos,$hsrc,@mos_input,'-o',$harness);
$rc==0 && !$sig or die "wide raster harness build failed\n$out$err";
$out eq '' && $err eq '' or die "wide raster harness build wrote output\n$out$err";
($rc,$sig,$out,$err)=capture($harness,$bin,'131','123456');
$rc==0 && !$sig or die "wide exact raster schedule failed\n$out$err";
$out eq "vcs_six_glyph_wide_raster ok: exact 88x8 score schedule and 262-line frames\n"
   or die "unexpected wide raster output: $out";
$err eq '' or die "wide raster stderr: $err";

($rc,$sig,$out,$err)=capture($harness,$compat_bin,'131','123456');
$rc==0 && !$sig or die "wide full-pointer exact raster schedule failed\n$out$err";
$out eq "vcs_six_glyph_wide_raster ok: exact 88x8 score schedule and 262-line frames\n"
   or die "unexpected wide full-pointer raster output: $out";
$err eq '' or die "wide full-pointer raster stderr: $err";

my $digest=File::Spec->catfile($repo,qw(test stella_png_rgb_digest.pl));
($rc,$sig,$out,$err)=capture($^X,$digest,$reference);
$rc==0 && !$sig or die "wide reference digest failed\n$out$err";
$out eq "320 x 228 89214b459cb1fae3b5c558c622a060e9cf7aa84957e0d1cb34385eab812d6b02\n"
   or die "wide reviewed Stella reference changed: $out";
$err eq '' or die "wide reference digest stderr: $err";

print "vcs_six_glyph_wide ok\n";
