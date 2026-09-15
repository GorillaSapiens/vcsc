#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 45
# expectstdout: vcs_joystick ok
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
my$dir=File::Spec->catdir($repo,qw(examples 03_controllers joystick));
my$src=File::Spec->catfile($dir,'joystick.c26');
my$make=File::Spec->catfile($dir,'Makefile');
my$readme=File::Spec->catfile($dir,'README.md');

my$s=read_file($src);
$s =~ /directions := SWCHA;/ && $s =~ /fire_input := INPT4;/
   or die "joystick tutorial must sample SWCHA and INPT4 directly\n";
for my $mask (qw(10 20 40 80)) {
   $s =~ /!\(directions & 0x\Q$mask\E\)/
      or die "joystick tutorial lost active-low direction mask 0x$mask\n";
}
$s =~ /!\(fire_input & 0x80\)/
   or die "joystick tutorial lost active-low INPT4 fire test\n";
my$count=()=$s=~/draw_input_band\(color\);/g;
$count==5 or die "joystick tutorial must draw exactly five input bands, got $count\n";
$s =~ /for \(uint8_t scanline := 38; scanline; scanline--\)/ &&
$s =~ /Five 38-line bands are 190 visible lines/ &&
$s =~ /COLUBK := JOYSTICK_BLANK_COLOR;\s*WSYNC := _;\s*WSYNC := _;/s
   or die "joystick tutorial lost its 192-line visible layout\n";
$s !~ /player_color|all_five|multisprite|score\.c26/
   or die "joystick tutorial unexpectedly depends on a reusable renderer/component\n";

my$m=read_file($make);
$m =~ /^ROOT \?= \.\.\/\.\.\/\.\.$/m && $m =~ /^play:\s*\n\tstella \*\.bin/m
   or die "joystick Makefile source-tree root or play target regressed\n";
my$r=read_file($readme);
$r =~ /SWCHA/ && $r =~ /INPT4/ && $r =~ /0x10.*UP/s && $r =~ /0x80.*RIGHT/s && $r =~ /active-low/i
   or die "joystick README lost controller wiring explanation\n";

my$bin=File::Spec->catfile($tmp,'joystick.bin');
my$map=File::Spec->catfile($tmp,'joystick.map');
my($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-Map',$map,$src,'-o',$bin);
$rc==0&&!$sig or die "joystick build failed\n$out$err";
$err eq '' or die "joystick build stderr: $err";
-s$bin==4096 or die "joystick tutorial is not a 4K ROM\n";

print "vcs_joystick ok\n";
