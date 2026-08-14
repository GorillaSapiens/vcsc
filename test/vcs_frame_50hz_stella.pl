#!/usr/bin/perl

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use POSIX qw(:sys_wait_h);
use Symbol qw(gensym);

sub slurp_fh { my($f)=@_; local $/; return <$f> // ''; }
sub capture { my(@c)=@_; my$e=gensym; my$p=open3(my$i,my$o,$e,@c); close$i; my$so=slurp_fh($o); my$se=slurp_fh($e); waitpid($p,0); return($?>>8,$?&127,$so,$se); }
sub ok { my($label,@c)=@_; my($r,$s,$o,$e)=capture(@c); $r==0&&!$s or die "$label failed rc=$r sig=$s\n@c\n$o$e"; return($o,$e); }
sub findexe { my($n)=@_; return abs_path($n) if $n=~m{/}&&-x$n; for(split(/:/,$ENV{PATH}//'')){my$p="$_/$n";return abs_path($p)if-x$p} return undef; }
sub terminate { my($p)=@_; return unless$p; kill 'TERM',$p; for(1..20){my$d=waitpid($p,WNOHANG);return if$d==$p||$d==-1;select undef,undef,undef,.05} kill 'KILL',$p;waitpid($p,0); }
sub write_file { my($p,$d)=@_; open(my$f,'>:raw',$p)or die"write $p: $!\n"; print{$f}$d; close$f or die$!; }
sub png_dimensions {
   my($p)=@_; open(my$f,'<:raw',$p)or die"read $p: $!\n"; read($f,my$h,24)==24 or die"short PNG $p\n"; close$f;
   substr($h,0,8) eq "\x89PNG\r\n\x1a\n" or die"not PNG $p\n";
   return unpack('NN',substr($h,16,8));
}

@ARGV==2 or die "usage: $0 REPO TMP\n";
my$repo=abs_path($ARGV[0])or die"resolve repo\n"; my$tmp=$ARGV[1]; make_path($tmp); $tmp=abs_path($tmp);
my$stella=$ENV{VCSC_STELLA}||$ENV{STELLA}||findexe('stella')or die"set STELLA or VCSC_STELLA\n";
my$xvfb=findexe('Xvfb')or die"Xvfb required\n"; my$perl=findexe('perl')or die"perl required\n";
my$driver=File::Spec->catfile($repo,qw(driver vcsc)); my$vcs=File::Spec->catdir($repo,qw(libraries vcs)); my$keys=File::Spec->catfile($repo,qw(test stella_snapshot_keys.pl));

for my$standard(qw(pal secam)) {
   my$upper=uc($standard); my$src="$tmp/$standard.c26"; my$rom="$tmp/$standard.bin";
   write_file($src,<<"SRC");
include "vcs.c26"
include "frame_${standard}.c26"
void main(void) {
   while (1) {
      vcs_${standard}_vsync();
      vcs_${standard}_begin_vblank();
      COLUBK := 0;
      COLUPF := 0;
      COLUP0 := 0;
      COLUP1 := 0;
      PF0 := 0; PF1 := 0; PF2 := 0;
      GRP0 := 0; GRP1 := 0; ENAM0 := 0; ENAM1 := 0; ENABL := 0;
      vcs_${standard}_end_vblank();
      vcs_${standard}_wait_scanlines(VCS_${upper}_VISIBLE_SCANLINES`uint8_t);
      asm nop;
      vcs_${standard}_begin_overscan();
      vcs_${standard}_end_overscan();
   }
}
SRC
   ok("build $standard frame",$driver,'-I',$vcs,$src,'-o',$rom);
   my$display=320+($$%40); $display++ while -e "/tmp/.X11-unix/X$display"; my$d=":$display";
   my$xpid=fork(); defined$xpid or die"fork Xvfb\n"; if(!$xpid){open(STDOUT,'>:raw',"$tmp/$standard.xvfb.log");open(STDERR,'>&STDOUT');exec($xvfb,$d,'-ac','-screen','0','1024x768x24');die$!}
   select undef,undef,undef,.2;
   local$ENV{DISPLAY}=$d; local$ENV{XAUTHORITY}='/dev/null'; local$ENV{HOME}="$tmp/home-$standard"; local$ENV{SDL_AUDIODRIVER}='dummy'; make_path($ENV{HOME});
   my$snap="$tmp/snap-$standard"; my$user="$tmp/user-$standard"; make_path($snap,$user); unlink glob("$snap/*.png");
   my$format=$standard eq 'pal' ? 'PAL' : 'SECAM';
   my@cmd=($stella,'-video','software','-turbo','1','-audio.enabled','0','-format',$format,'-bs','4K','-snapsavedir',$snap,'-snapname',$standard,'-sssingle','1','-ss1x','1','-exitlauncher','0','-confirmexit','0','-userdir',$user,$rom);
   my$pid=fork(); defined$pid or die"fork Stella\n"; if(!$pid){open(STDOUT,'>:raw',"$tmp/$standard.stella.log");open(STDERR,'>&STDOUT');exec@cmd;die$!}
   ok("snapshot $standard frame",$perl,$keys);
   my@png; for(1..40){@png=grep{-s$_}glob("$snap/*.png");last if@png==1;select undef,undef,undef,.05}
   terminate($pid); terminate($xpid); @png==1 or die"$standard Stella produced ".scalar(@png)." snapshots\n";
   my($w,$h)=png_dimensions($png[0]); $w==320 && $h==274 or die"$standard snapshot is ${w}x${h}, expected 320x274 PAL/SECAM 50 Hz viewport\n";
}
print "vcs_frame_50hz_stella ok\n";
