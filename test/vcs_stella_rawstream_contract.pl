#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 120
# expectstdout: vcs_stella_rawstream_contract ok
# expectexit: 0
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use Digest::SHA qw(sha256_hex);
my($repo,$tmp)=@ARGV;$repo=abs_path($repo);make_path($tmp);$tmp=abs_path($tmp);
require "$repo/test/stella_test_lib.pl";
sub slurp{open my$f,'<:raw',$_[0]or die$!;local$/;return<$f>;}
sub save{open my$f,'>:raw',$_[0]or die$!;print$f $_[1];close$f;}
sub run{open my$f,'-|',@_ or die"exec @_: $!";local$/;my$s=<$f>//'';close$f or die"command failed: @_\n$s";return$s;}
sub findexe{my$n=shift;return abs_path($n)if-x$n;for(split/:/,$ENV{PATH}//''){return abs_path("$_/$n")if-x"$_/$n";}die"required executable: $n";}
my$stella=findexe($ENV{VCSC_STELLA}||$ENV{STELLA}||'stella');
my$xvfb=findexe($ENV{VCSC_XVFB}||$ENV{XVFB}||'Xvfb');
my(undef,$display)=vcsc_reserve_x_display(392,10);
my$xp=fork();defined$xp or die$!;
if(!$xp){open STDOUT,'>',"$tmp/xvfb.log"or die$!;open STDERR,'>&STDOUT';exec($xvfb,$display,'-ac','-screen','0','1024x768x24');die$!;}
vcsc_xvfb_assert_ready($display,$xp);
local$ENV{DISPLAY}=$display;local$ENV{SDL_AUDIODRIVER}='dummy';
vcsc_stella_private_env("$tmp/help");
my$help=run($stella,'-help');$help=~/^\s+-rawstream\s+<file>/m or die"$stella must support upstream -rawstream\n";
my$helpers=slurp("$repo/test/stella_png_sequence.pl");$helpers=~s/\n\@ARGV>=2.*\z//s or die'PNG boundary';eval$helpers;die$@if$@;
save("$tmp/probe.c26",<<'ROM');
include "vcs.c26"
include "frame_ntsc.c26"
uint8_t phase;
void main(void) {
   phase:=0;
   while(1) {
      vcs_ntsc_vsync();
      vcs_ntsc_begin_vblank();
      // All TIA writes stay in VBLANK, preserving the deterministic ROM fix.
      phase++;
      if(phase&1){COLUBK:=0x46;}else{COLUBK:=0x84;}
      PF0:=0;PF1:=0;PF2:=0;GRP0:=0;GRP1:=0;ENAM0:=0;ENAM1:=0;ENABL:=0;
      vcs_ntsc_end_vblank();
      asm .repeat 192;
      asm sta WSYNC;
      asm .endrepeat;
      vcs_ntsc_begin_overscan();
      vcs_ntsc_end_overscan();
   }
}
ROM
run("$repo/driver/vcsc",'-I',"$repo/libraries/vcs","$tmp/probe.c26",'-o',"$tmp/probe.bin");
my$palette=slurp("$repo/test/fixtures/stella/stella.pal");
my@expected=map{
   # The pinned user palette still goes through Stella's presentation transform
   # (PaletteHandler::adjustedPalette, neutral hue/saturation, gamma option0).
   # At these settings blue truncates B-.001R-.001G before the 1.1333 gamma.
   # Derive the solid RGB oracle from the fixture, never from captured pixels.
   my($r,$g,$b)=unpack('C3',substr($palette,($_/2)*3,3));
   $b=int($b-.001*$r-.001*$g);
   pack('C3',map{int(($_/255)**1.1333*256+.5)}($r,$g,$b));
}(0x84,0x46);
my%digests;
for my$attempt(1,2) {
   my$dir="$tmp/run$attempt";my$user="$dir/user";make_path($dir,$user);
   my@cmd=(vcsc_stella_capture_launcher($repo,$stella),vcsc_stella_palette_args($repo,$user),
      '--capture-frames','200,201-203,205','--capture-dir',$dir,
      '-plr.bankrandom','0','-plr.ramrandom','0','-plr.tiarandom','0',
      '-dev.bankrandom','0','-dev.ramrandom','0','-dev.cpurandom','0','-dev.tiarandom','0',
      '-dev.hsrandom','0','-dev.tiadriven','0','-video','software','-turbo','1',
      '-audio.enabled','0','-bs','4K','-exitlauncher','0','-confirmexit','0','-userdir',$user,"$tmp/probe.bin");
   run(@cmd);
   my@png=glob"$dir/*.png";@png==5 or die'exact frame selection count';
   for my$n(200,201,202,203,205) {
      my$path=sprintf("$dir/frame_%08d.png",$n);my($w,$h,$rgb)=decode_rgb($path);
      $w==160&&$h>=192 or die'native frame dimensions';
      my%colors;for(unpack('(a3)*',$rgb)){$colors{$_}++unless$_ eq"\0\0\0";}
      keys(%colors)==1 or die'probe is not a uniform colored frame';
      # Frame1 ends the startup partial raster at the first VSYNC. The first
      # complete ROM iteration has phase1 and ends at frame2 (Stella increments
      # frameCount before RawStream::frame). No stream-position offset is used.
      my$wanted=$expected[($n-1)&1];
      exists$colors{$wanted}&&$colors{$wanted}>=160*192 or die"wrong frame identity/color at $n; got ".join(',',map{unpack('H*',$_)}keys%colors);
      my$d=sha256_hex(slurp($path));
      if($attempt==1){$digests{$n}=$d;}else{$digests{$n}eq$d or die"PNG nondeterminism at frame$n";}
   }
   !glob("$dir/rawstream-*/*.raw")or die'successful raw recording not cleaned';
}
$digests{200}ne$digests{201}or die'alternating frames indistinguishable';
print "vcs_stella_rawstream_contract ok\n";
