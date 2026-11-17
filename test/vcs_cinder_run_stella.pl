#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 180
# expectstdout: vcs_cinder_run_stella ok
# expectexit: 0
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
my($repo,$tmp)=@ARGV;
$repo=abs_path($repo); make_path($tmp); $tmp=abs_path($tmp);
require "$repo/test/stella_test_lib.pl";
sub slurp { open my$f,'<:raw',$_[0] or die$!; local$/; return <$f>; }
sub run { open my$f,'-|',@_ or die$!; local$/; my$s=<$f>//''; close$f or die "@_ failed\n$s"; return$s; }
sub findexe {
   my$n=shift;
   return abs_path($n) if -x$n;
   for(split/:/,$ENV{PATH}//'') { return abs_path("$_/$n") if -x"$_/$n"; }
   die "missing executable $n\n";
}
my$stella=findexe($ENV{VCSC_STELLA}||$ENV{STELLA}||'stella');
my$xvfb=findexe($ENV{VCSC_XVFB}||$ENV{XVFB}||'Xvfb');
my$helpers=slurp("$repo/test/stella_png_sequence.pl");
$helpers=~s/\n\@ARGV>=2.*\z//s or die 'PNG boundary'; eval$helpers; die$@ if$@;
# Only input is scripted in a temporary cartridge. Rendering, real TIA latches,
# game physics, and collision responses remain the public game's implementation.
my$source=slurp("$repo/examples/06_games/cinder_run/cinder_run.c26");
$source=~/game_player0_colors\[8\]\s*:=\s*\{([^}]+)\}/ or die 'courier palette';
my@courier_colors=map{hex($_)}split /\s*,\s*/,$1;
my$hood_color=$courier_colors[-1];
$source=~/COLUPF\s*:=\s*(0x[0-9a-f]+)/i or die 'playfield palette';
my$playfield_color=hex($1);
$source=~s/new_run\(\);\n   game_init\(\);/new_run();\n   run_mode := 1;\n   game_init();/ or die 'startup boundary';
$source=~s/INPT4/((run_frame == 40) ? 0 : 0x80)/g;
open my$f,'>',"$tmp/scripted.c26" or die$!; print{$f}$source; close$f;
run("$repo/driver/vcsc",'-I',"$repo/libraries/vcs","$tmp/scripted.c26",'-o',"$tmp/scripted.bin");
my(undef,$display)=vcsc_reserve_x_display(770,30);
my$p=fork(); defined$p or die$!;
if(!$p) { open STDOUT,'>',"$tmp/xvfb.log" or die$!; open STDERR,'>&STDOUT'; exec($xvfb,$display,'-ac','-screen','0','1024x768x24'); die$!; }
END { local$?; if($p) { kill 'TERM',$p; waitpid($p,0); } }
vcsc_xvfb_assert_ready($display,$p);
local$ENV{DISPLAY}=$display; local$ENV{SDL_VIDEODRIVER}='x11'; local$ENV{SDL_AUDIODRIVER}='dummy';
run(vcsc_stella_capture_launcher($repo,$stella),
   vcsc_stella_palette_args($repo,"$tmp/user"),
   '-plr.bankrandom','0','-plr.ramrandom','0','-plr.tiarandom','0',
   '-dev.bankrandom','0','-dev.ramrandom','0','-dev.cpurandom','0','-dev.tiarandom','0',
   '-dev.hsrandom','0','-dev.tiadriven','0','-video','software','-turbo','1','-audio.enabled','0',
   '-bs','4K','-exitlauncher','0','-confirmexit','0','-userdir',"$tmp/user",
   '--capture-frames','10,60,100,140','--capture-dir',$tmp,"$tmp/scripted.bin");
my$pal=slurp("$repo/test/fixtures/stella/stella.pal");
sub color {
   my($index)=@_; my($r,$g,$b)=unpack('C3',substr($pal,($index/2)*3,3));
   $b=int($b-.001*$r-.001*$g);
   return pack('C3',map{int(($_/255)**1.1333*256+.5)}($r,$g,$b));
}
my(%top,%lamps);
for my$frame(10,60,100,140) {
   my($w,$h,$rgb)=decode_rgb(sprintf("$tmp/frame_%08d.png",$frame));
   $w==160 && $h>=192 && $h<=264 or die "unexpected capture geometry $w x $h\n";
   my@hood; my$lamps=0;
   for my$y(25..$h-1) { for my$x(0..159) {
      my$c=substr($rgb,($y*160+$x)*3,3);
      push@hood,[$x,$y] if $y>60 && $c eq color($hood_color);
      $lamps++ if $y<60 && $c eq color($playfield_color);
   }}
   if($frame!=140) {
      @hood or die "frame $frame: courier is invisible\n";
      my@ys=sort{$a<=>$b}map{$_->[1]}@hood;
      $top{$frame}=$ys[0];
   }
   $lamps{$frame}=$lamps;
}
$top{10}==$top{100} && $top{60}<$top{10}-40 or die "jump/landing not visible\n";
$lamps{100}>0 && $lamps{140}*3==$lamps{100}*2 or die "real TIA contact did not remove exactly one life: $lamps{100} -> $lamps{140}\n";
print "vcs_cinder_run_stella ok\n";
