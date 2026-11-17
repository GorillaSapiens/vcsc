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
$source=~s{\.\./\.\./_common/cinder_run_raster\.c26}{$repo/examples/_common/cinder_run_raster.c26}g;
$source=~/game_player0_colors\[8\]\s*:=\s*\{([^}]+)\}/ or die 'courier palette';
my@courier_colors=map{hex($_)}split /\s*,\s*/,$1;
$source=~/game_player1_colors\[8\]\s*:=\s*\{([^}]+)\}/ or die 'monster palette';
my@monster_colors=map{hex($_)}split /\s*,\s*/,$1;
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
for my$mode(qw(climb standing duck shoot edge_gap edge_top edge_seam)) {
   my$dir="$tmp/$mode"; make_path($dir);
    my$input='';
   if($mode eq 'climb') {
       $input.="if (run_frame == 2 || run_frame == 65 || run_frame == 135) { return 0xef; }\n";
       $input.="if (run_frame >= 170 && run_frame < 180) { return 0xdf; }\n";
   }
    if($mode eq 'duck') { $input.="if (run_speed) { return 0xdf; }\n"; }
    my$script=$source;
    if($mode=~/^edge_/) {
       my$y=$mode eq 'edge_gap' ? 61 : $mode eq 'edge_top' ? 13 : 27;
       $script=~s/prepare_sprites\(\);/prepare_sprites(); run_spark_x := run_frame \& 63; run_spark_x++; run_spark_y := $y;/ or die 'edge fixture boundary';
    }
    # Pure input substitution; no persistent RAM or physics scratch is changed.
    $script=~s/(inline void update_physics\(void\) \{)/inline uint8_t fixture_keys(void) { $input return 0xff; }\n$1/ or die 'input boundary';
    if($mode eq 'shoot') {
       $script=~s/!\(INPT4 & 0x80\)/(run_frame == 10)/g;
       $script=~s/INPT4 & 0x80/run_frame != 10/g;
    }
    else { $script=~s/INPT4/0x80/g; }
    $script=~s/SWCHA/fixture_keys()/g;
   open my$f,'>',"$dir/scripted.c26" or die$!; print{$f}$script; close$f;
   run("$repo/driver/vcsc",'-I',"$repo/libraries/vcs","$dir/scripted.c26",'-o',"$dir/scripted.bin");
   run(vcsc_stella_capture_launcher($repo,$stella),
   vcsc_stella_palette_args($repo,"$dir/user"),
   '-plr.bankrandom','0','-plr.ramrandom','0','-plr.tiarandom','0',
   '-dev.bankrandom','0','-dev.ramrandom','0','-dev.cpurandom','0','-dev.tiarandom','0',
   '-dev.hsrandom','0','-dev.tiadriven','0','-video','software','-turbo','1','-audio.enabled','0',
   '-bs','F8','-exitlauncher','0','-confirmexit','0','-userdir',"$dir/user",
    '--capture-frames',($mode=~/^edge_/ ? join(',',4..67) : $mode eq 'climb' ? '30,100,169,175' : $mode eq 'standing' ? '4,8,12,16,50,100,280,570' : $mode eq 'shoot' ? '20,50' : '100,280,570'),
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
my%monster_rgb=map{color($_)=>1}@monster_colors;
my(%top,%lamps,%body_height,%body_bottom,%running_masks);
for my$mode(qw(climb standing duck)) {
 for my$frame($mode eq 'climb' ? (30,100,169,175) : $mode eq 'standing' ? (4,8,12,16,50,100,280,570) : (100,280,570)) {
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
    if($mode eq 'climb' && $frame!=175) {
      @hood or die "frame $frame: courier is invisible\n";
      my@ys=sort{$a<=>$b}map{$_->[1]}@hood;
      $top{$frame}=$ys[0];
   }
   if(@body) { my@ys=sort{$a<=>$b}@body; $body_height{"$mode/$frame"}=$ys[-1]-$ys[0]+1; $body_bottom{"$mode/$frame"}=$ys[-1]; }
   $lamps{"$mode/$frame"}=$lamps;
   $running_masks{$mask}=1 if $mode eq 'standing' && $frame<20;
}
}
$top{30}-$top{100}==32 && $top{100}-$top{169}==32
    or die "three real platform landings are not visible: @top{30,100,169}\n";
$body_height{'climb/175'}<=8 && $body_height{'climb/169'}>=14 or die 'crouch silhouette did not shrink';
$body_bottom{'climb/175'}==$body_bottom{'climb/169'} or die 'crouching moved the feet through the platform';
keys(%running_masks)==4 or die 'running cycle did not show four distinct silhouettes';
$lamps{'standing/100'}>0 && $lamps{'standing/280'}*3==$lamps{'standing/100'}*2
   or die "real ground contact did not remove one life\n";
$lamps{'standing/570'}*2==$lamps{'duck/570'} && $lamps{'duck/570'}==$lamps{'duck/280'}
    or die "ducking did not avoid the real low ember collision\n";
# Independently measure ledge thickness, auxiliary colours, and a real M0/P1 hit.
my($w,$h,$rgb)=decode_rgb("$tmp/standing/frame_00000004.png");
my@runs; my$n=0;
for my$y(60..$h-1) {
   if(substr($rgb,($y*$w+120)*3,3) eq $playfield_rgb) { $n++; }
   elsif($n) { push@runs,$n; $n=0; }
}
grep($_==4,@runs)>=2 or die "platforms did not render at four scanlines thick\n";
my$spark_pixels=0;
for my$y(80..$body_bottom{'standing/4'}-20) { for my$x(70..130) {
   $spark_pixels++ if $monster_rgb{substr($rgb,($y*$w+$x)*3,3)};
}}
$spark_pixels>0 or die "M1 collectible did not use P1's contrasting colour\n";
($w,$h,$rgb)=decode_rgb("$tmp/shoot/frame_00000020.png");
my$shot_pixels=0;
for my$y($body_bottom{'standing/4'}-15..$body_bottom{'standing/4'}) { for my$x(50..110) {
   $shot_pixels++ if $courier_rgb{substr($rgb,($y*$w+$x)*3,3)};
}}
$shot_pixels>0 or die "Fire did not render the M0 shot\n";
my@left;
for my$mode(qw(standing shoot)) {
   ($w,$h,$rgb)=decode_rgb("$tmp/$mode/frame_00000050.png");
   my@xs;
   for my$y($body_bottom{'standing/4'}-30..$body_bottom{'standing/4'}) { for my$x(100..159) {
      push@xs,$x if $monster_rgb{substr($rgb,($y*$w+$x)*3,3)};
   }}
   @xs or die "missing monster in $mode control\n";
   push@left,(sort{$a<=>$b}@xs)[0];
}
$left[1]>$left[0]+10 or die "real M0 collision did not kill and replace the monster\n";
# Sweep all 64 near-left X positions through ordinary and row-transition paths.
# Compare every occupied scanline to its neighbors, not a ROM/artwork golden.
for my$mode(qw(edge_gap edge_top edge_seam)) {
   my$reference;
   for my$frame(4..67) {
      my($w,$h,$rgb)=decode_rgb(sprintf("$tmp/$mode/frame_%08d.png",$frame));
      my@rows;
      for my$y(25..$body_bottom{'standing/4'}-10) {
         my@xs=grep { $monster_rgb{substr($rgb,($y*$w+$_)*3,3)} } 0..80;
         push@rows,join(',',@xs) if @xs;
      }
      @rows or die "$mode frame $frame: M1 disappeared\n";
      $reference//=scalar(@rows);
      @rows==$reference or die "$mode frame $frame: M1 height tears near the left edge\n";
      for my$row(@rows) {
         $row eq $rows[0] or die "$mode frame $frame: M1 scanlines tear near the left edge\n";
      }
   }
}
print "vcs_cinder_run_stella ok\n";
