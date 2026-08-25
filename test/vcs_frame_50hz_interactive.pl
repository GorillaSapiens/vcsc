#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 60
# expectstdout: vcs_frame_50hz_interactive ok
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);
sub usage { die "usage: $0 REPO TMP\n"; }
sub slurp { my($f)=@_; local $/; return <$f> // ''; }
sub capture { my(@c)=@_; my$e=gensym; my$p=open3(my$i,my$o,$e,@c);close$i;my$so=slurp($o);my$se=slurp($e);waitpid($p,0);return($?>>8,$?&127,$so,$se); }
my$repo=shift@ARGV//usage();my$tmp=shift@ARGV//usage();usage()if@ARGV;$repo=abs_path($repo)//die"repo\n";make_path($tmp);$tmp=abs_path($tmp);
my$cxx=$ENV{CXX}||'c++';my$mos=File::Spec->catdir($repo,qw(simulator mos6502));my$obj=File::Spec->catfile($mos,'mos6502.o');my@mi=-f$obj?($obj):(File::Spec->catfile($mos,'mos6502.cpp'));
my$exe=File::Spec->catfile($tmp,'vcs_frame_50hz_interactive');my$src=File::Spec->catfile($repo,qw(test vcs_frame_50hz_interactive.cpp));
my($r,$s,$o,$e)=capture($cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,$src,@mi,'-o',$exe);$r==0&&!$s or die"harness build failed\n$o$e";
my$driver=File::Spec->catfile($repo,qw(driver vcsc));
my$vcs=File::Spec->catdir($repo,qw(libraries vcs));
for my$case(
   ['pal','all-five',[],qw(17_video_standards pal 01_all_five pal_all_five_228_interactive.c26)],
   ['pal','player-color',[],qw(17_video_standards pal 02_player_color pal_player_color_228_interactive.c26)],
   ['pal','all-five-unofficial',['-Wa,--illegals'],qw(17_video_standards pal 03_all_five_unofficial pal_all_five_unofficial_228_interactive.c26)],
   ['pal','multisprite',['-Wa,--illegals'],qw(17_video_standards pal 04_multisprite pal_multisprite_228_interactive.c26)],
   ['secam','all-five',[],qw(17_video_standards secam 01_all_five secam_all_five_228_interactive.c26)],
   ['secam','player-color',[],qw(17_video_standards secam 02_player_color secam_player_color_228_interactive.c26)],
   ['secam','all-five-unofficial',['-Wa,--illegals'],qw(17_video_standards secam 03_all_five_unofficial secam_all_five_unofficial_228_interactive.c26)],
   ['secam','multisprite',['-Wa,--illegals'],qw(17_video_standards secam 04_multisprite secam_multisprite_228_interactive.c26)]
) {
   my($standard,$family,$flags,@parts)=@$case;
   my$source=File::Spec->catfile($repo,'examples',@parts);
   my$rom=File::Spec->catfile($tmp,"$standard-$family.bin");
   ($r,$s,$o,$e)=capture($driver,'-I',$vcs,@$flags,$source,'-o',$rom);
   $r==0&&!$s or die"interactive build failed for $source\n$o$e";
   $o =~ s/\AMEMORY USAGE\n(?:  [^\n]+\n)+//;
   $o eq '' && $e eq '' or die"interactive build wrote output for $source\n$o$e";
   ($r,$s,$o,$e)=capture($exe,$rom);
   $r==0&&!$s or die"interactive frame failed for $source\n$o$e";
   $o eq "vcs_frame_50hz_interactive ok\n"&&$e eq '' or die"unexpected output\n$o$e";
}
print "vcs_frame_50hz_interactive ok\n";
