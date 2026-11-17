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
my(undef,$display)=vcsc_reserve_x_display(770,30);
my$p=fork(); defined$p or die$!;
if(!$p) { open STDOUT,'>',"$tmp/xvfb.log" or die$!; open STDERR,'>&STDOUT'; exec($xvfb,$display,'-ac','-screen','0','1024x768x24'); die$!; }
END { local$?; if($p) { kill 'TERM',$p; waitpid($p,0); } }
vcsc_xvfb_assert_ready($display,$p);
local$ENV{DISPLAY}=$display; local$ENV{SDL_VIDEODRIVER}='x11'; local$ENV{SDL_AUDIODRIVER}='dummy';
for my$mode(qw(climb standing duck)) {
   my$dir="$tmp/$mode"; make_path($dir);
   my$input="physics_old_feet := 0x80; physics_top := 0xff;";
   if($mode eq 'climb') {
      $input.="if (run_frame == 2 || run_frame == 30 || run_frame == 65) { physics_old_feet := 0; }\n";
      $input.="if (run_frame >= 90 && run_frame < 100) { physics_top := 0xdf; }\n";
   }
   if($mode eq 'duck') { $input.="if (run_frame >= 210) { physics_top := 0xdf; }\n"; }
   my$script=$source;
   $script=~s/(bank1 void (?:update_run|advance_physics)\(void\) \{)/$1\n$input/g or die 'input boundary';
   # These bytes are dead until after their respective last input reads.
   # The input fixture consumes no additional persistent cartridge RAM.
   $script=~s/INPT4/physics_old_feet/g;
   $script=~s/SWCHA/physics_top/g;
   open my$f,'>',"$dir/scripted.c26" or die$!; print{$f}$script; close$f;
   run("$repo/driver/vcsc",'-I',"$repo/libraries/vcs","$dir/scripted.c26",'-o',"$dir/scripted.bin");
   run(vcsc_stella_capture_launcher($repo,$stella),
   vcsc_stella_palette_args($repo,"$dir/user"),
   '-plr.bankrandom','0','-plr.ramrandom','0','-plr.tiarandom','0',
   '-dev.bankrandom','0','-dev.ramrandom','0','-dev.cpurandom','0','-dev.tiarandom','0',
   '-dev.hsrandom','0','-dev.tiadriven','0','-video','software','-turbo','1','-audio.enabled','0',
   '-bs','F8','-exitlauncher','0','-confirmexit','0','-userdir',"$dir/user",
   '--capture-frames',($mode eq 'climb' ? '30,60,89,95' : $mode eq 'standing' ? '4,8,12,16,100,140,250' : '100,140,250'),
   '--capture-dir',$dir,"$dir/scripted.bin");
}
my$pal=slurp("$repo/test/fixtures/stella/stella.pal");
sub color {
   my($index)=@_; my($r,$g,$b)=unpack('C3',substr($pal,($index/2)*3,3));
   $b=int($b-.001*$r-.001*$g);
   return pack('C3',map{int(($_/255)**1.1333*256+.5)}($r,$g,$b));
}
my%courier_rgb=map{color($_)=>1}@courier_colors;
my$hood_rgb=color($hood_color);
my$playfield_rgb=color($playfield_color);
my(%top,%lamps,%body_height,%body_bottom,%running_masks);
for my$mode(qw(climb standing duck)) {
for my$frame($mode eq 'climb' ? (30,60,89,95) : $mode eq 'standing' ? (4,8,12,16,100,140,250) : (100,140,250)) {
   my($w,$h,$rgb)=decode_rgb(sprintf("$tmp/$mode/frame_%08d.png",$frame));
   $w==160 && $h>=192 && $h<=264 or die "unexpected capture geometry $w x $h\n";
   my@hood; my@body; my$lamps=0; my$mask='';
   for my$y(25..$h-1) { for my$x(0..159) {
      my$c=substr($rgb,($y*160+$x)*3,3);
      push@hood,[$x,$y] if $y>45 && $c eq $hood_rgb;
      if($y>45 && $x>=35 && $x<44 && $courier_rgb{$c}) {
         push@body,$y; $mask.=pack('CC',$x,$y);
      }
      $lamps++ if $y<60 && $c eq $playfield_rgb;
   }}
   if($mode eq 'climb' && $frame!=95) {
      @hood or die "frame $frame: courier is invisible\n";
      my@ys=sort{$a<=>$b}map{$_->[1]}@hood;
      $top{$frame}=$ys[0];
   }
   if(@body) { my@ys=sort{$a<=>$b}@body; $body_height{"$mode/$frame"}=$ys[-1]-$ys[0]+1; $body_bottom{"$mode/$frame"}=$ys[-1]; }
   $lamps{"$mode/$frame"}=$lamps;
   $running_masks{$mask}=1 if $mode eq 'standing' && $frame<20;
}
}
$top{30}-$top{60}==32 && $top{60}-$top{89}==32
   or die "three real platform landings are not visible: @top{30,60,89}\n";
$body_height{'climb/95'}<=8 && $body_height{'climb/89'}>=14 or die 'crouch silhouette did not shrink';
$body_bottom{'climb/95'}==$body_bottom{'climb/89'} or die 'crouching moved the feet through the platform';
keys(%running_masks)==4 or die 'running cycle did not show four distinct silhouettes';
$lamps{'standing/100'}>0 && $lamps{'standing/140'}*3==$lamps{'standing/100'}*2
   or die "real ground contact did not remove one life\n";
$lamps{'standing/250'}*2==$lamps{'duck/250'} && $lamps{'duck/250'}==$lamps{'duck/140'}
   or die "ducking did not avoid the real low ember collision\n";
print "vcs_cinder_run_stella ok\n";
