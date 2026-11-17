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
my@modes=(qw(idle standing jump duck shoot world edge_gap edge_top edge_seam),map{"aim$_"}0..7);
for my$mode(@modes) {
   my$dir="$tmp/$mode";make_path($dir);my$s=$source;my$input='';
   if($mode ne 'idle') {$s=~s/new_run\(\);\n   game_init\(\);/new_run();\n   run_mode := 1;\n   game_init();/ or die 'startup boundary';}
   $input.='if (run_frame >= 2 && run_frame < 40) { return 0xef; }' if $mode eq 'jump';
   $input.='if (run_frame >= 20 && run_frame < 40) { return 0xdf; }' if $mode eq 'duck';
   if($mode eq 'world') {$input.='if (run_frame >= 2 && run_frame < 50) { return 0x7f; } if (run_frame >= 50 && run_frame < 114) { return 0xbf; }';}
   if($mode=~/^aim(\d)$/) {$input.="if (run_frame >= 10 && run_frame <= 12) { return $aim[$1]; }";}
   if($mode=~/^edge_/) {
      my$y=$mode eq 'edge_gap'?61:$mode eq 'edge_top'?13:27;
      $s=~s/prepare_sprites\(\);/prepare_sprites(); run_spark_x := run_frame \& 63; run_spark_x++; run_spark_y := $y;/ or die 'edge boundary';
   }
   $input=~s/return ([^;]+);/fixture_input := $1;/g;
   $s=~s/(inline void update_physics\(void\) \{)/uint8_t fixture_input;\n$1/ or die 'keys boundary';
   $s=~s/(bank1 void advance_physics\(void\) \{)/$1\nfixture_input := 0xff; $input\n/;
   $s=~s/(run_frame\+\+;)/$1\nfixture_input := 0xff; $input\n/;
   $s=~s/SWCHA/fixture_input/g;
   if($mode eq 'shoot'||$mode=~/^aim/) {
      $s=~s/!\(INPT4 & 0x80\)/(run_frame >= 10 \&\& run_frame <= 12)/g;
      $s=~s/INPT4 & 0x80/(run_frame < 10 || run_frame > 12)/g;
   }
   else {$s=~s/INPT4/0x80/g;}
   open my$f,'>',"$dir/scripted.c26" or die$!;print{$f}$s;close$f;
   run("$repo/driver/vcsc",'-I',"$repo/libraries/vcs","$dir/scripted.c26",'-o',"$dir/scripted.bin");
   my$frames=$mode=~/^edge_/?join(',',4..67):$mode eq 'idle'?'4,8,12,14,16,25,50':$mode eq 'standing'?'50':$mode eq 'world'?'4,50,116':$mode=~/^aim/?'14':$mode eq 'shoot'?'14,50':$mode eq 'duck'?'25':'10';
   run(vcsc_stella_capture_launcher($repo,$stella),vcsc_stella_palette_args($repo,"$dir/user"),
      '-plr.bankrandom','0','-plr.ramrandom','0','-plr.tiarandom','0',
      '-dev.bankrandom','0','-dev.ramrandom','0','-dev.cpurandom','0','-dev.tiarandom','0',
      '-dev.hsrandom','0','-dev.tiadriven','0','-video','software','-turbo','1','-audio.enabled','0',
      '-bs','F6','-exitlauncher','0','-confirmexit','0','-userdir',"$dir/user",
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
for my$x(0..159) {substr($rgb,(($origin+175)*$w+$x)*3,3) eq $pf_rgb or die "road misses x$x\n";}
sub body {
   my($mode,$f)=@_;my($w,$h,$rgb)=image($mode,$f);my@ys;my$mask='';
   for my$y(60..$h-1) {for my$x(79..86) {if($courier_rgb{substr($rgb,($y*$w+$x)*3,3)}) {push@ys,$y;$mask.=pack('CC',$x,$y);}}}
   @ys or die "missing courier in $mode/$f";@ys=sort{$a<=>$b}@ys;return($ys[0],$ys[-1],$mask);
}
my($head,$feet)=body('idle',25);my($duck_head,$duck_feet)=body('duck',25);
$feet==$duck_feet&&$duck_head>$head or die 'crouch moved feet or did not shrink';
my(undef,$jump_feet)=body('jump',10);$jump_feet<$feet or die 'Up did not visibly jump';
my%poses;for my$f(4,8,12,16) {my(undef,undef,$mask)=body('idle',$f);$poses{$mask}=1;}
keys(%poses)==4 or die 'running poses are not distinct';
# Pixel roundtrip: input travels eight columns right and then eight left.
my@maps;
for my$f(4,50,116) {my($w,$h,$rgb)=image('world',$f);my$m='';for my$y($origin+48..$origin+143) {for my$x(0..159) {$m.=substr($rgb,($y*$w+$x)*3,3) eq $pf_rgb?'1':'0';}}push@maps,$m;}
$maps[0] ne $maps[1]&&$maps[0] eq $maps[2] or die 'terrain did not visually return after reversing';
my@enemy;
for my$m(qw(standing shoot)) {my($w,$h,$rgb)=image($m,50);my@xs;for my$y($feet-18..$feet+2) {for my$x(100..159) {push@xs,$x if$monster_rgb{substr($rgb,($y*$w+$x)*3,3)};}}@xs or die 'monster missing';push@enemy,(sort{$a<=>$b}@xs)[0];}
$enemy[1]>$enemy[0]+5 or die 'real M0 hit did not replace the monster';
for my$i(0..7) {
   my($w,$h,$rgb)=image("aim$i",14);my(@xs,@ys);
   for my$y(60..$h-1) {for my$x(0..159) {my$at=($y*$w+$x)*3;if($courier_rgb{substr($rgb,$at,3)}&&!($x>=79&&$x<=86&&$y>=$head&&$y<=$feet)) {push@xs,$x;push@ys,$y;}}}
   @xs or die "aim$i: shot invisible";
   my$x=0;$x+=$_ for@xs;$x/=@xs;my$y=0;$y+=$_ for@ys;$y/=@ys;
   my@dx=(1,1,0,-1,-1,-1,0,1);my@dy=(0,-1,-1,-1,0,1,1,1);
   ($dx[$i]>0?$x>90:$dx[$i]<0?$x<76:abs($x-83)<5) or die "aim$i: wrong horizontal travel";
   ($dy[$i]>0?$y>$feet:$dy[$i]<0?$y<$head:($y>=$head&&$y<=$feet)) or die "aim$i: wrong vertical travel (y$y, body $head..$feet)";
}
for my$m(qw(edge_gap edge_top edge_seam)) {
   my$n;
   for my$f(4..67) {my($w,$h,$rgb)=image($m,$f);my@rows;
      for my$y(25..$feet-20) {my@xs=grep{$monster_rgb{substr($rgb,($y*$w+$_)*3,3)}}0..70;push@rows,join(',',@xs) if@xs;}
      @rows or die "$m/$f: M1 missing";$n//=scalar@rows;@rows==$n or die "$m/$f: M1 height tears";
      for(@rows) {$_ eq $rows[0] or die "$m/$f: M1 scanlines tear";}
   }
}
print "vcs_cinder_run_stella ok\n";
