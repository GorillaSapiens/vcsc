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

my $repo=shift @ARGV // usage();
my $tmp=shift @ARGV // usage();
usage() if @ARGV;
$repo=abs_path($repo) // die "resolve repo\n";
make_path($tmp);
$tmp=abs_path($tmp) // die "resolve tmp\n";

my $driver=File::Spec->catfile($repo,qw(driver vcsc));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $profile=File::Spec->catdir($vcs,qw(kernels faithful_legacy_playercolors));
my $cfg=File::Spec->catfile($profile,'faithful_legacy_playercolors.cfg');
my $source=File::Spec->catfile($repo,qw(examples 05_multicolor_full_static multicolor_full_static.c26));
my $oracle=File::Spec->catfile($repo,qw(test oracles pristine_basic_v1.9_playercolors faithful_legacy_playercolors.bin));
my $bin=File::Spec->catfile($tmp,'multicolor_full_static.bin');
my $map=File::Spec->catfile($tmp,'multicolor_full_static.map');

my $text=read_file($source);
require_re($text,qr/^include "color_ntsc\.c26"$/m,
   'example 05 does not use named NTSC colors');
require_re($text,qr/^include "playfield\.c26"$/m,
   'example 05 does not use visual playfield rows');
require_re($text,qr/template "kernels\/faithful_legacy_playercolors\/faithful_legacy_playercolors\.c26" as legacy/,
   'example 05 does not use the oracle-backed faithful legacy kernel');
require_re($text,qr/^uint8_t legacy_playfield\[48\]/m,
   'example 05 playfield is not RAM-backed');
my @pfrows=$text =~ /VCS_PLAYFIELD_ROW\s*\(/g;
@pfrows==12 or die "example 05 has ".scalar(@pfrows)." playfield rows, expected 12\n";
my @visual=$text =~ /0b[.X]{8}(?![.X])/g;
@visual>=16 or die "example 05 lacks sixteen visual sprite rows\n";
for my $name (qw(
   VCS_NTSC_GRAY_92 VCS_NTSC_GOLDENROD VCS_NTSC_SANDY_BROWN
   VCS_NTSC_LIGHT_CORAL VCS_NTSC_ORCHID VCS_NTSC_VIOLET
   VCS_NTSC_MEDIUM_PURPLE VCS_NTSC_DARK_BLUE VCS_NTSC_ROYAL_BLUE
   VCS_NTSC_SKY_BLUE_2 VCS_NTSC_SKY_BLUE VCS_NTSC_AQUAMARINE
   VCS_NTSC_PALE_GREEN
)) {
   $text =~ /\b\Q$name\E\b/ or die "example 05 does not use $name\n";
}

my($rc,$sig,$out,$err)=capture(
   $driver,'-I',$vcs,'-Wa,--illegals','-T',$cfg,'-Map',$map,$source,'-o',$bin);
$rc==0 && !$sig or die "example 05 build failed\n$out$err";
without_usage($out) eq '' && $err eq '' or die "example 05 build wrote output\n$out$err";
length(read_file($bin))==4096 or die "example 05 did not produce a 4096-byte ROM\n";
length(read_file($oracle))==4096 or die "pristine oracle is not a 4096-byte ROM\n";

my $cxx=$ENV{CXX} || 'c++';
my $mos=File::Spec->catdir($repo,qw(simulator mos6502));
my $mos_obj=File::Spec->catfile($mos,'mos6502.o');
my @mos_input=-f $mos_obj ? ($mos_obj) : (File::Spec->catfile($mos,'mos6502.cpp'));
my $hsrc=File::Spec->catfile($repo,qw(test vcs_faithful_legacy_compare.cpp));
my $harness=File::Spec->catfile($tmp,'vcs_multicolor_full_static_compare');
($rc,$sig,$out,$err)=capture(
   $cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,$hsrc,@mos_input,'-o',$harness);
$rc==0 && !$sig or die "oracle comparator build failed\n$out$err";
$out eq '' && $err eq '' or die "oracle comparator build wrote output\n$out$err";

($rc,$sig,$out,$err)=capture($harness,$oracle,$bin,'264','264');
$rc==0 && !$sig or die "example 05 differs from pristine BASIC oracle\n$out$err";
$out eq "vcs_faithful_legacy_compare ok: 1230 events and 42 stable frames per ROM\n"
   or die "unexpected oracle comparison output: $out";
$err eq '' or die "oracle comparator stderr: $err";

($rc,$sig,$out,$err)=capture($harness,$bin,'264','--sprites');
$rc==0 && !$sig or die "example 05 sprite oracle failed\n$out$err";
$out eq "vcs_faithful_legacy_compare sprite oracle ok: 8 P0 rows, 8 P1 rows, exact row colors\n"
   or die "unexpected sprite-oracle output: $out";
$err eq '' or die "sprite-oracle stderr: $err";

print "vcs_multicolor_full_static ok: public example 05 matches pristine BASIC oracle: 1230 visible events, 264-line frames, exact sprites\n";
