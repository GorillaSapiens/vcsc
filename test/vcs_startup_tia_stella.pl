#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# serial
# timeout: 300
# expectstdout: stock startup TIA randomization passed
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use Digest::SHA qw(sha256_hex);
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
sub slurp { my($p)=@_; open(my$f,'<:raw',$p)or die"read $p: $!\n"; local$/; my$d=<$f>; close$f; return $d; }
sub png_image_digest {
   my($p)=@_; my$png=slurp($p); substr($png,0,8) eq "\x89PNG\r\n\x1a\n" or die"not PNG $p\n";
   my$off=8; my$image='';
   while($off<length($png)){
      $off+12<=length($png) or die"truncated PNG $p\n";
      my$n=unpack('N',substr($png,$off,4)); my$t=substr($png,$off+4,4);
      $off+=8; $off+$n+4<=length($png) or die"truncated PNG chunk $p\n";
      my$d=substr($png,$off,$n); $off+=$n+4;
      $image.=$t.$d if $t eq 'IHDR' || $t eq 'PLTE' || $t eq 'IDAT';
      last if $t eq 'IEND';
   }
   return sha256_hex($image);
}

@ARGV==2 or die "usage: $0 REPO TMP\n";
my$repo=abs_path($ARGV[0])or die"resolve repo\n"; my$tmp=$ARGV[1]; make_path($tmp); $tmp=abs_path($tmp);
my$stella=findexe($ENV{VCSC_STELLA}||$ENV{STELLA}||'stella')or die"set STELLA or VCSC_STELLA\n";
require File::Spec->catfile($repo,qw(test stella_test_lib.pl));
my$xvfb=findexe($ENV{VCSC_XVFB}||$ENV{XVFB}||'Xvfb')or die"Xvfb required\n"; my$perl=findexe('perl')or die"perl required\n";
my$driver=File::Spec->catfile($repo,qw(driver vcsc)); my$vcs=File::Spec->catdir($repo,qw(libraries vcs)); my$keys=File::Spec->catfile($repo,qw(test stella_snapshot_keys.pl));

my$display=360+($$%40); $display++ while -e "/tmp/.X11-unix/X$display"; my$d=":$display";
my$xpid=fork(); defined$xpid or die"fork Xvfb\n"; if(!$xpid){open(STDOUT,'>:raw',"$tmp/xvfb.log");open(STDERR,'>&STDOUT');exec($xvfb,$d,'-ac','-screen','0','1024x768x24');die$!}
select undef,undef,undef,.2;
local$ENV{DISPLAY}=$d; local$ENV{XAUTHORITY}='/dev/null'; local$ENV{SDL_AUDIODRIVER}='dummy';

my$frame=<<'FRAME';
void main(void) {
   while (1) {
      vcs_ntsc_vsync();
      vcs_ntsc_begin_vblank();
      vcs_ntsc_end_vblank();
      vcs_ntsc_wait_scanlines(VCS_NTSC_VISIBLE_SCANLINES`uint8_t);
      asm nop;
      vcs_ntsc_begin_overscan();
      vcs_ntsc_end_overscan();
   }
}
FRAME
my%decl=(
   simple => "uint8_t byte;\n",
   data   => "uint8_t initialized := 7;\n",
   full   => "noinit uint8_t preserved;\n",
   control=> "uint8_t byte;\n",
);

sub build_source {
   my($name)=@_;
   my$extra='';
   if($name eq 'control') {
      $extra=<<'CLEAR';
void clear_visible_tia(void) {
   COLUBK := 0;
   PF0 := 0; PF1 := 0; PF2 := 0;
   AUDV0 := 0; AUDV1 := 0;
   GRP0 := 0; GRP1 := 0;
   ENAM0 := 0; ENAM1 := 0; ENABL := 0;
   VDELP0 := 0; VDELP1 := 0; VDELBL := 0;
}
CLEAR
      (my$f=$frame)=~s/vcs_ntsc_begin_vblank\(\);/vcs_ntsc_begin_vblank();\n      clear_visible_tia();/;
      return "include \"vcs.c26\"\ninclude \"frame_ntsc.c26\"\n$decl{$name}$extra$f";
   }
   return "include \"vcs.c26\"\ninclude \"frame_ntsc.c26\"\n$decl{$name}$frame";
}

sub snapshot {
   my($name)=@_;
   my$src="$tmp/$name.c26"; my$rom="$tmp/$name.bin";
   write_file($src,build_source($name));
   ok("build $name",$driver,'-I',$vcs,$src,'-o',$rom);
   my$snap="$tmp/snap-$name"; my$user="$tmp/user-$name"; make_path($snap,$user); unlink glob("$snap/*.png");
   my@cmd=($stella,vcsc_stella_palette_args($repo,$user),
      '-plr.bankrandom','0','-plr.ramrandom','0','-plr.tiarandom','1',
      '-dev.settings','1','-dev.bankrandom','0','-dev.ramrandom','0','-dev.cpurandom','0','-dev.tiarandom','1','-dev.hsrandom','0','-dev.tiadriven','0',
      '-video','software','-turbo','1','-audio.enabled','0','-format','NTSC','-bs','4K',
      '-snapsavedir',$snap,'-snapname',$name,'-sssingle','1','-ss1x','1','-exitlauncher','0','-confirmexit','0','-userdir',$user,$rom);
   my$pid=fork(); defined$pid or die"fork Stella\n"; if(!$pid){open(STDOUT,'>:raw',"$tmp/$name.stella.log");open(STDERR,'>&STDOUT');exec@cmd;die$!}
   select undef,undef,undef,.35;
   ok("snapshot $name",$perl,$keys);
   my@png; for(1..60){@png=grep{-s$_}glob("$snap/*.png");last if@png==1;select undef,undef,undef,.05}
   terminate($pid); @png==1 or die"$name Stella produced ".scalar(@png)." snapshots\n";
   return png_image_digest($png[0]);
}

my$control=snapshot('control');
for my$name(qw(simple data full)) {
   my$hash=snapshot($name);
   $hash eq $control or die "$name startup leaked randomized TIA state: $hash != $control\n";
}
terminate($xpid);
print "stock startup TIA randomization passed\n";
