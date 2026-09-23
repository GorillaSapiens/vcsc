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
$s =~ /instantiate "components\/four_paddles\.c26" as paddles/
   or die "paddle tutorial must use the four-paddle timing component\n";
$s =~ /X=20,60,100,140/ &&
$s =~ /asm lda #26;.*?asm ldx #2;.*?asm lda #67;.*?asm ldx #3;.*?asm lda #107;.*?asm ldx #1;.*?asm lda #146;/s
   or die "paddle tutorial lost the four equally spaced fixed X positions\n";
$s =~ /alias PADDLE_PLAYER_ON 0xc0/ && $s =~ /alias PADDLE_MISSILE_ON 0x02/ &&
$s =~ /NUSIZ0 := 0x10;/ && $s =~ /NUSIZ1 := 0x10;/
   or die "paddle tutorial markers are no longer two pixels wide\n";
for my$i(0..3) {
   $s =~ /paddles_button$i/ or die "paddle tutorial lost button $i\n";
   $s =~ /paddles_position$i/ or die "paddle tutorial lost position $i\n";
   $s =~ /inline void paddle_sample$i\(void\).*?INPT$i.*?sty\.z paddles_active$i/s
      or die "paddle tutorial lost fixed-phase visible probe $i\n";
}
$s =~ /if \(paddles_button0\).*?paddle0_pattern_odd := 0;/s &&
$s =~ /if \(paddles_button1\).*?paddle1_pattern_even := 0;/s &&
$s =~ /if \(paddles_button2\).*?paddle2_pattern_odd := 0;/s &&
$s =~ /if \(paddles_button3\).*?paddle3_pattern_even := 0;/s
   or die "paddle tutorial lost per-button dotted marker patterns\n";
$s =~ /asm ldx #\$d0;/ && $s =~ /asm inx;\s*asm beq\.same \@done;\s*asm jmp \@group;/s &&
$s =~ /Forty-eight groups|48 groups/
   or die "paddle tutorial lost its 48x4=192 visible raster\n";
$s =~ /paddles_vblank\(\)/ && $s =~ /paddles_account_gap\(3\)/ &&
$s =~ /paddles_overscan\(\)/ && $s =~ /paddles_dump\(\)/
   or die "paddle tutorial lost the RC measurement lifecycle\n";

my$m=read_file($make);
(my$m_flat=$m) =~ s/\\[ \t]*\r?\n[ \t]*//g;
$m_flat =~ s/ -dev\.(?:settings|stats|detectedinfo|ramrandom|bankrandom) 1//g;
$m =~ /^ROOT \?= \.\.\/\.\.\/\.\.$/m && $m =~ /four_paddles\.c26/ &&
$m !~ /two_paddles\.c26/ &&
$m_flat =~ /^play:\s*\n\techo WARNING: ignoring user specific settings\n\tstella -dev\.tv\.jitter 0 -basedir "\$\(CURDIR\)" -userdir "\$\(CURDIR\)" "\$\(CURDIR\)"\/\*\.bin/m
   or die "paddle tutorial Makefile dependencies or play target regressed\n";
my$r=read_file($readme);
$r =~ /X=20, 60, 100, and\s+140/s && $r =~ /2 pixels wide and 8 pixels tall/i &&
$r =~ /solid/i && $r =~ /dotted/i && $r =~ /INPT0.*INPT3/s &&
$r =~ /VBLANK\.7/ && $r =~ /SWCHA/
   or die "paddle tutorial README lost the visible four-paddle contract\n";

my$bin=File::Spec->catfile($tmp,'paddle.bin');
my$map=File::Spec->catfile($tmp,'paddle.map');
my($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-Map',$map,$src,'-o',$bin);
$rc==0&&!$sig or die "paddle tutorial build failed\n$out$err";
$err eq '' or die "paddle tutorial build stderr: $err";
-s$bin==4096 or die "paddle tutorial is not a 4K ROM\n";

print "vcs_paddle_tutorial ok\n";
