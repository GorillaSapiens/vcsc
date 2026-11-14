#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 90
# expectstdout: vcs_driving_stella ok
# expectexit: 0
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use POSIX qw(:sys_wait_h setpgid);
my($repo,$tmp)=@ARGV;$repo=abs_path($repo);make_path($tmp);$tmp=abs_path($tmp);
require "$repo/test/stella_test_lib.pl";
my%children;
sub stop {
   my$p=shift;return unless delete$children{$p};kill 'TERM',-$p;
   for(1..20){my$r=waitpid($p,WNOHANG);return if$r==$p||$r==-1;select undef,undef,undef,.05;}
   kill 'KILL',-$p;waitpid($p,0);
}
END {local$?;stop($_)for keys%children;}
sub spawn {
   my($log,@cmd)=@_;my$p=fork();defined$p or die$!;
   if(!$p){setpgid(0,0);open STDOUT,'>:raw',$log or die$!;open STDERR,'>&STDOUT' or die$!;exec@cmd;die$!;}
   eval{setpgid($p,$p)};$children{$p}=1;return$p;
}
sub slurp {open my$f,'<:raw',$_[0]or die$!;local$/;return<$f>;}
sub findexe {
   my$n=shift;return abs_path($n)if-x$n;
   for(split/:/,$ENV{PATH}//''){return abs_path("$_/$n")if-x"$_/$n";}
   die"required executable: $n";
}
my$helpers=slurp("$repo/test/stella_png_sequence.pl");
$helpers=~s/\n\@ARGV>=2.*\z//s or die'PNG helper boundary';eval$helpers;die$@if$@;
my$stella=findexe($ENV{VCSC_STELLA}||$ENV{STELLA}||'stella');
my$xvfb=findexe($ENV{VCSC_XVFB}||$ENV{XVFB}||'Xvfb');
# Public-example smoke invariants, not golden scenes: RGB, glyphs, playfield and
# orbit positions remain editable. Cover every affected caller family.
my@cases=(
 ['03_controllers/driving/drive.c26','4K','NTSC',192],
 ['03_controllers/keypad/keypad.c26','4K','NTSC',192],
 ['02_components/six_digit_score/score.c26','2K','NTSC',0],
 ['02_components/wide_score/wide_score.c26','2K','NTSC',0],
 ['02_components/big_wide_score/big_wide_score.c26','2K','NTSC',0],
 ['02_components/three_plus_three_score/dual_score.c26','2K','NTSC',0],
 ['02_components/heart_score/heart_score.c26','4K','NTSC',0],
 ['07_diagnostics/bankswitching/e0/e0_diagnostic.c26','E0','NTSC',192],
 ['07_diagnostics/bankswitching/f864/bankswitching_diagnostic.c26','F8','NTSC',192,'-DMAPPER_BANKS=2'],
 ['05_video_standards/enhanced_multisprite_asymmetric/pal/pal_enhanced_multisprite_asymmetric_228_interactive.c26','F8','PAL',228,'-DMULTISPRITE_NO_RETAINED_PF_ROWS'],
 ['05_video_standards/enhanced_multisprite_asymmetric/secam/secam_enhanced_multisprite_asymmetric_228_interactive.c26','F8','SECAM',228,'-DMULTISPRITE_NO_RETAINED_PF_ROWS']);
my(undef,$display)=vcsc_reserve_x_display(396,20);
my$xp=spawn("$tmp/xvfb.log",$xvfb,$display,'-ac','-screen','0','1024x768x24');
vcsc_xvfb_assert_ready($display,$xp);
local$ENV{DISPLAY}=$display;local$ENV{XAUTHORITY}='/dev/null';local$ENV{SDL_AUDIODRIVER}='dummy';
local$ENV{SDL_VIDEODRIVER}='x11';
for my$index(0..$#cases) {
my($source,$mapper,$tv,$lines,@extra)=@{$cases[$index]};
my$dir="$tmp/case$index";make_path($dir);
my$example=File::Spec->catfile($repo,'examples',split(m{/},$source));
my$build=spawn("$dir/build.log","$repo/driver/vcsc",'-I',"$repo/libraries/vcs",@extra,$example,'-o',"$dir/scene.bin");
waitpid($build,0);my$status=$?;delete$children{$build};$status==0 or die slurp("$dir/build.log");
my$snap="$dir/snap";my$user="$dir/user";make_path($snap,$user);
my$p=spawn("$dir/stella.log",vcsc_stella_capture_launcher($repo,$stella),vcsc_stella_palette_args($repo,$user),
   '-plr.bankrandom','0','-plr.ramrandom','0','-plr.tiarandom','0',
   '-dev.bankrandom','0','-dev.ramrandom','0','-dev.cpurandom','0','-dev.tiarandom','0',
   '-dev.hsrandom','0','-dev.tiadriven','0','-video','software','-turbo','1',
   '-audio.enabled','0','-bs',$mapper,'-format',$tv,'--capture-frames','200-201','--capture-dir',$snap,
   '-exitlauncher','0','-confirmexit','0','-userdir',$user,"$dir/scene.bin");
my@png=vcsc_stella_wait_snapshots("$snap/*.png",2);stop($p);
@png==2 or die"missing $source frames";
for my$path(@png) {
   my($w,$h,$rgb)=decode_rgb($path);$w==160&&$h==($tv eq'NTSC'?228:274)or die'unexpected native viewport';
   # The pinned PAL palette's blank entry is dark grey, not RGB000000.
   my$blank=substr($rgb,0,3);
   substr($rgb,0,$w*3)eq$blank x$w&&substr($rgb,($h-1)*$w*3,$w*3)eq$blank x$w or die"$source blank margins are not uniform";
   my@lit=grep{substr($rgb,$_*$w*3,$w*3)ne$blank x$w}0..$h-1;
   @lit&&$lit[-1]-$lit[0]+1==@lit or die"$source visible field is not contiguous";
   !$lines||@lit==$lines or die"$source has ".scalar(@lit)." visible rows, expected$lines\n";
   for my$y($lit[0],$lit[-1]) {
      my$row=substr($rgb,$y*$w*3,$w*3);
      !grep{$_ eq$blank}unpack('(a3)*',$row)or die"$source boundary row$y contains blank pixels (partial line?)\n";
   }
}
}
print "vcs_driving_stella ok\n";
