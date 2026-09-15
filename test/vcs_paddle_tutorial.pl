#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 45
# expectstdout: vcs_paddle_tutorial ok
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub usage { die "usage: $0 REPO TMP\n"; }
sub slurp_fh { my($f)=@_; local $/; return <$f> // ''; }
sub capture { my(@c)=@_; my$e=gensym; my$p=open3(my$i,my$o,$e,@c);close$i;my$so=slurp_fh($o);my$se=slurp_fh($e);waitpid($p,0);return($?>>8,$?&127,$so,$se); }
sub read_file { my($p)=@_;open(my$f,'<:raw',$p)or die"read $p: $!\n";local$/;my$d=<$f>;close$f;return$d//''; }

my$repo=shift@ARGV//usage();my$tmp=shift@ARGV//usage();usage()if@ARGV;
$repo=abs_path($repo)//die"resolve repo\n";$tmp=abs_path($tmp)//die"resolve tmp\n";
my$driver=File::Spec->catfile($repo,qw(driver vcsc));
my$vcs=File::Spec->catdir($repo,qw(libraries vcs));
my$dir=File::Spec->catdir($repo,qw(examples 03_controllers paddle));
my$src=File::Spec->catfile($dir,'paddle.c26');
my$make=File::Spec->catfile($dir,'Makefile');
my$readme=File::Spec->catfile($dir,'README.md');

my$s=read_file($src);
$s =~ /instantiate "two_paddles\.c26" as paddles \(port:=0\)/
   or die "paddle tutorial must use the left-port paddle timing component\n";
$s =~ /display_position := paddles_position0;/ && $s =~ /display_button := paddles_button0;/
   or die "paddle tutorial must display stable raw position and button state\n";
$s =~ /paddles_init\(\)/ && $s =~ /paddles_vblank\(\)/ &&
$s =~ /paddles_sample0\(\)/ && $s =~ /paddles_sample1\(\)/ &&
$s =~ /paddles_advance_pair\(\)/ && $s =~ /paddles_account_gap\(2\)/ &&
$s =~ /paddles_overscan\(\)/ && $s =~ /paddles_dump\(\)/
   or die "paddle tutorial lost the RC measurement lifecycle\n";
my$count=()=$s=~/draw_value_band\(bit[0-7]_color\);/g;
$count==8 or die "paddle tutorial must draw eight raw-value bit bands, got $count\n";
$s =~ /for \(uint8_t pair := 11; pair; pair--\)/ &&
$s =~ /for \(uint8_t pair := 8; pair; pair--\)/ &&
$s =~ /Eight 22-line binary-value bands plus one 16-line button band/
   or die "paddle tutorial lost its 192-line visible layout\n";
$s =~ /prepare_display\(\);\s*paddles_vblank\(\);/s
   or die "paddle tutorial must freeze display state before current-frame paddle sampling\n";

my$m=read_file($make);
$m =~ /^ROOT \?= \.\.\/\.\.\/\.\.$/m && $m =~ /two_paddles\.c26/ &&
$m =~ /^play:\s*\n\tstella \*\.bin/m
   or die "paddle tutorial Makefile dependencies or play target regressed\n";
my$r=read_file($readme);
$r =~ /RC charge time/i && $r =~ /INPT0\.7/ && $r =~ /VBLANK\.7/ &&
$r =~ /SWCHA.*bit 7/s && $r =~ /active-low/i && $r =~ /two-NTSC-scanline units/i
   or die "paddle tutorial README lost raw timing/button explanation\n";

my$bin=File::Spec->catfile($tmp,'paddle.bin');
my$map=File::Spec->catfile($tmp,'paddle.map');
my($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-Map',$map,$src,'-o',$bin);
$rc==0&&!$sig or die "paddle tutorial build failed\n$out$err";
$err eq '' or die "paddle tutorial build stderr: $err";
-s$bin==4096 or die "paddle tutorial is not a 4K ROM\n";

print "vcs_paddle_tutorial ok\n";
