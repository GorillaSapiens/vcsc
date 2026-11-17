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
$repo=abs_path($repo);make_path($tmp);$tmp=abs_path($tmp);
require "$repo/test/stella_test_lib.pl";
sub slurp {open my$f,'<:raw',$_[0] or die$!;local$/;return <$f>;}
sub run {open my$f,'-|',@_ or die$!;local$/;my$s=<$f>//'';close$f or die "@_ failed\n$s";return$s;}
sub findexe {
   my$n=shift;return abs_path($n) if -x$n;
   for(split/:/,$ENV{PATH}//'') {return abs_path("$_/$n") if -x"$_/$n";}
   die "missing executable $n\n";
}
my$stella=findexe($ENV{VCSC_STELLA}||$ENV{STELLA}||'stella');
my$xvfb=findexe($ENV{VCSC_XVFB}||$ENV{XVFB}||'Xvfb');
my$helpers=slurp("$repo/test/stella_png_sequence.pl");
$helpers=~s/\n\@ARGV>=2.*\z//s or die 'PNG boundary';eval$helpers;die$@ if$@;
my$source=slurp("$repo/examples/06_games/cinder_run/cinder_run.c26");
$source=~s{\.\./\.\./_common/(\w+\.c26)}{$repo/examples/_common/$1}g;
$source=~/landscape\[18\]\s*:=\s*\{([^}]+)\}/s or die 'terrain boundary';
my@terrain=map{hex($_)}$1=~/(0x[0-9a-f]+)/ig;
@terrain==18 or die 'terrain bytes';
$source=~/game_player0_colors\[8\]\s*:=\s*\{([^}]+)\}/ or die 'courier palette';
my@courier=map{hex($_)}$1=~/(0x[0-9a-f]+)/ig;
$source=~/courier\[56\]\s*:=\s*\{(.*?)\};/s or die 'courier artwork';
my@poses=$1=~/game_SPRITE_GLYPH\(([^)]+)\)/g;
@poses==7 or die 'courier pose count';
my@standing=split /,/, $poses[-1];
for(@standing) {s/\s|0b//g;tr/.X/01/;$_=oct("0b$_");}
$source=~/game_player1_colors\[8\]\s*:=\s*\{([^}]+)\}/ or die 'monster palette';
my@monster=map{hex($_)}$1=~/(0x[0-9a-f]+)/ig;
$source=~/COLUPF\s*:=\s*(0x[0-9a-f]+)/i or die 'PF palette';my$pf=hex($1);
my(undef,$display)=vcsc_reserve_x_display(770,30);
my$p=fork();defined$p or die$!;
if(!$p) {open STDOUT,'>',"$tmp/xvfb.log" or die$!;open STDERR,'>&STDOUT';exec($xvfb,$display,'-ac','-screen','0','1024x768x24');die$!;}
END {local$?;if($p) {kill 'TERM',$p;waitpid($p,0);}}
vcsc_xvfb_assert_ready($display,$p);
local$ENV{DISPLAY}=$display;local$ENV{SDL_VIDEODRIVER}='x11';local$ENV{SDL_AUDIODRIVER}='dummy';
my@aim=(0x7f,0x6f,0xef,0xaf,0xbf,0x9f,0xdf,0x5f);
my@modes=(qw(idle running standing jump duck shoot world treasure edge_gap edge_top edge_seam),map{"aim$_"}0..7);
for my$mode(@modes) {
   my$dir="$tmp/$mode";make_path($dir);my$s=$source;my$input='';
   if($mode ne 'idle') {$s=~s/new_run\(\);\n   locate_treasure\(\);/new_run();\n   run_mode := 1;\n   locate_treasure();/ or die 'startup boundary';}
   $input.='if (run_frame >= 2 && run_frame < 40) { return 0xef; }' if $mode eq 'jump';
   $input.='if (run_frame >= 20 && run_frame < 40) { return 0xdf; }' if $mode eq 'duck';
   $input.='if (run_frame < 20) { return 0x7f; }' if $mode eq 'running';
   if($mode eq 'world') {$input.='if (run_frame >= 2 && run_frame < 50) { return 0x7f; } if (run_frame >= 50 && run_frame < 114) { return 0xbf; }';}
   if($mode eq 'treasure') {$input.='if (run_frame >= 2 && run_frame < 92) { return 0x7f; } if (run_frame >= 92 && run_frame < 198) { return 0xbf; }';}
   if($mode=~/^aim(\d)$/) {$input.="if (run_frame >= 10 && run_frame <= 12) { return $aim[$1]; }";}
   if($mode=~/^edge_/) {
      my$y=$mode eq 'edge_gap'?65:$mode eq 'edge_top'?17:33;
      $s=~s/(hazards\[128\]\s*:=\s*)\{.*?\};/${1}{0};/s or die 'edge monster boundary';
      $s=~s/(courier\[56\]\s*:=\s*)\{.*?\};/${1}{0};/s or die 'edge courier boundary';
      $s=~s/prepare_sprites\(\);/prepare_sprites(); run_spark_x := run_frame - 3; run_spark_y := $y;/ or die 'edge boundary';
   }
   $input=~s/return ([^;]+);/fixture_input := $1;/g;
   $s=~s/(inline void update_physics\(void\) \{)/uint8_t fixture_input;\n$1/ or die 'keys boundary';
   $s=~s/(bank2 void advance_physics\(void\) \{)/$1\nfixture_input := 0xff; $input\n/;
   $s=~s/(run_frame\+\+;)/$1\nfixture_input := 0xff; $input\n/;
   $s=~s/SWCHA/fixture_input/g;
   if($mode eq 'shoot'||$mode=~/^aim/) {
      $s=~s/!\(INPT4 & 0x80\)/(run_frame >= 10 \&\& run_frame <= 12)/g;
      $s=~s/INPT4 & 0x80/(run_frame < 10 || run_frame > 12)/g;
   }
   else {$s=~s/INPT4/0x80/g;}
   open my$f,'>',"$dir/scripted.c26" or die$!;print{$f}$s;close$f;
   run("$repo/driver/vcsc",'-I',"$repo/libraries/vcs","$dir/scripted.c26",'-o',"$dir/scripted.bin");
   my$frames=$mode=~/^edge_/?join(',',4..155):($mode eq 'idle'||$mode eq 'running')?'4,8,12,14,16,25,50':$mode eq 'standing'?'50':$mode eq 'world'?'4,50,116':$mode eq 'treasure'?'4,92,200':$mode=~/^aim/?'18':$mode eq 'shoot'?'14,50':$mode eq 'duck'?'25':'10';
   run(vcsc_stella_capture_launcher($repo,$stella),vcsc_stella_palette_args($repo,"$dir/user"),
      '-plr.bankrandom','0','-plr.ramrandom','0','-plr.tiarandom','0',
      '-dev.bankrandom','0','-dev.ramrandom','0','-dev.cpurandom','0','-dev.tiarandom','0',
      '-dev.hsrandom','0','-dev.tiadriven','0','-video','software','-turbo','1','-audio.enabled','0',
      '-bs','F6SC','-exitlauncher','0','-confirmexit','0','-userdir',"$dir/user",
      '--capture-frames',$frames,'--capture-dir',$dir,"$dir/scripted.bin");
}
my$pal=slurp("$repo/test/fixtures/stella/stella.pal");
sub color {
   my($i)=@_;my($r,$g,$b)=unpack('C3',substr($pal,($i/2)*3,3));$b=int($b-.001*$r-.001*$g);
   return pack('C3',map{int(($_/255)**1.1333*256+.5)}($r,$g,$b));
}
my%courier_rgb=map{color($_)=>1}@courier;my%monster_rgb=map{color($_)=>1}@monster;
my$pf_rgb=color($pf);
sub image {return decode_rgb(sprintf("$tmp/$_[0]/frame_%08d.png",$_[1]));}
my($w,$h,$rgb)=image('idle',4);$w==160&&$h>=192&&$h<=264 or die 'capture geometry';
my($origin)=grep{substr($rgb,($_*$w+16)*3,3) eq $pf_rgb}25..60;
defined$origin or die 'missing lamps';
for my$y($origin..$origin+15) {
   for my$x(80..159) {substr($rgb,($y*$w+$x)*3,3) ne $pf_rgb or die 'life lamps are mirrored on the right';}
}
# All 160 pixels, all four lines of each tier, and every intervening gap.
for my$dy(16..143) {
   my$t=$dy>=112?2:$dy>=80?1:$dy>=48?0:-1;
   for my$x(0..159) {
      my$on=0;
      if($t>=0&&($dy-48)%32<4) {
         my$c=int($x/4);my$b=$c<4?0:$c<12?1:$c<20?2:$c<28?3:$c<36?4:5;
         my$bit=$c<4?$c+4:$c<12?11-$c:$c<20?$c-12:$c<28?27-$c:$c<36?$c-28:43-$c;
         $on=!!($terrain[$t*6+$b]&(1<<$bit));
      }
      my$actual=substr($rgb,(($origin+$dy)*$w+$x)*3,3) eq $pf_rgb;
      $on==$actual or die "full-width terrain mismatch: scanline $dy x$x\n";
   }
}
for my$dy(144..175) {for my$x(0..159) {substr($rgb,(($origin+$dy)*$w+$x)*3,3) eq $pf_rgb or die "road misses scanline $dy x$x\n";}}
sub body {
   my($mode,$f)=@_;my($w,$h,$rgb)=image($mode,$f);my@ys;my$mask='';
   for my$y(60..$h-1) {for my$x(79..104) {if($courier_rgb{substr($rgb,($y*$w+$x)*3,3)}) {push@ys,$y;$mask.=pack('CC',$x,$y);}}}
   @ys or die "missing courier in $mode/$f";@ys=sort{$a<=>$b}@ys;return($ys[0],$ys[-1],$mask);
}
my($head,$feet)=body('idle',25);my($duck_head,$duck_feet)=body('duck',25);
my(undef,undef,$standing_rgb)=image('idle',25);
for my$dy(0..15) {for my$x(0..7) {
   my$on=!!($standing[int($dy/2)]&(0x80>>$x));
   my$actual=!!$courier_rgb{substr($standing_rgb,(($head+$dy)*$w+79+$x)*3,3)};
   $on==$actual or die "standing artwork differs from source: row $dy x$x";
}}
$feet==$duck_feet&&$duck_head>$head or die 'crouch moved feet or did not shrink';
my(undef,$jump_feet)=body('jump',10);$jump_feet<$feet or die 'Up did not visibly jump';
my%poses;for my$f(4,8,12,16) {my(undef,undef,$mask)=body('idle',$f);$poses{$mask}=1;}
keys(%poses)==1 or die 'stationary courier is still running';
%poses=();for my$f(4,8,12,16) {
   my(undef,undef,$mask)=body('running',$f);my@coords=unpack('C*',$mask);my$left=160;
   for(my$i=0;$i<@coords;$i+=2) {$left=$coords[$i] if $coords[$i]<$left;}
   for(my$i=0;$i<@coords;$i+=2) {$coords[$i]-=$left;}
   $poses{pack('C*',@coords)}=1;
}
keys(%poses)==4 or die 'running poses are not distinct';
# Pixel roundtrip: input travels eight columns right and then eight left.
my@maps;
for my$f(4,50,116) {my($w,$h,$rgb)=image('world',$f);my$m='';for my$y($origin+48..$origin+143) {for my$x(0..159) {$m.=substr($rgb,($y*$w+$x)*3,3) eq $pf_rgb?'1':'0';}}push@maps,$m;}
$maps[0] ne $maps[1]&&$maps[0] eq $maps[2] or die 'terrain did not visually return after reversing';
my@dots;
for my$f(4,200) {my($w,$h,$rgb)=image('treasure',$f);my$n=0;
   for my$y($origin+126..$origin+134) {for my$x(127..134) {$n++ if$monster_rgb{substr($rgb,($y*$w+$x)*3,3)};}}
   push@dots,$n;
}
$dots[0]==12&&$dots[1]==0 or die "real treasure collection did not persist after returning (@dots)";
my@enemy;
for my$m(qw(standing shoot)) {my($w,$h,$rgb)=image($m,50);my@xs;for my$y($feet-12..$feet+2) {for my$x(100..159) {push@xs,$x if$monster_rgb{substr($rgb,($y*$w+$x)*3,3)};}}@xs or die 'monster missing';push@enemy,(sort{$a<=>$b}@xs)[0];}
$enemy[1]>$enemy[0]+5 or die 'real M0 hit did not replace the monster';
for my$i(0..7) {
   my($w,$h,$rgb)=image("aim$i",18);my(@xs,@ys);
   for my$y(60..$h-1) {for my$x(0..159) {my$at=($y*$w+$x)*3;if($courier_rgb{substr($rgb,$at,3)}&&!($x>=79&&$x<=86&&$y>=$head&&$y<=$feet)) {push@xs,$x;push@ys,$y;}}}
   @xs or die "aim$i: shot invisible";
   my$x=0;$x+=$_ for@xs;$x/=@xs;my$y=0;$y+=$_ for@ys;$y/=@ys;
   my@dx=(1,1,0,-1,-1,-1,0,1);my@dy=(0,-1,-1,-1,0,1,1,1);
   ($dx[$i]>0?$x>90:$dx[$i]<0?$x<76:abs($x-83)<5) or die "aim$i: wrong horizontal travel";
   ($dy[$i]>0?$y>$feet:$dy[$i]<0?$y<$head:($y>=$head&&$y<=$feet)) or die "aim$i: wrong vertical travel (y$y, body $head..$feet)";
}
for my$m(qw(edge_gap edge_top edge_seam)) {
   my$n;
   for my$f(4..155) {my($w,$h,$rgb)=image($m,$f);my@rows;
      for my$y(25..$feet-10) {my@xs=grep{$monster_rgb{substr($rgb,($y*$w+$_)*3,3)}}0..159;push@rows,join(',',@xs) if@xs;}
      @rows or die "$m/$f: M1 missing";$n//=scalar@rows;@rows==$n or die "$m/$f: M1 height tears";
      @rows==4 or die "$m/$f: dot is not four lines";
      my@width=map{scalar(split /,/)}@rows;
      join(',',@width) eq '2,4,4,2' or die "$m/$f: dot profile @width";
      my@left=map{(split /,/)[0]}@rows;
      for(@left) {$_ eq $left[0] or die "$m/$f: M1 scanlines tear";}
   }
}
print "vcs_cinder_run_stella ok\n";
