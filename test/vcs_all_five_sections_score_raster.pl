#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 240
# expectstdout: vcs_all_five_sections_score_raster ok
# expectexit: 0
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use IPC::Open3;
use Symbol qw(gensym);
my($repo,$tmp)=@ARGV;
$repo=abs_path($repo); $tmp=abs_path($tmp);
sub slurp { open(my$f,'<',$_[0]) or die$!; local$/; return <$f>; }
sub save { open(my$f,'>',$_[0]) or die$!; print{$f}$_[1]; close$f or die$!; }
sub run {
   my$err=gensym; my$p=open3(my$i,my$o,$err,@_); close$i;
   local$/; my$out=<$o>//'';my$e=<$err>//'';waitpid($p,0);
   $?==0 or die "@_ failed\n$out$e";
}
require "$repo/test/stella_test_lib.pl";
my$helpers=slurp("$repo/test/stella_png_sequence.pl");
$helpers =~ s/\n\@ARGV>=2.*\z//s or die "PNG helper boundary missing\n";
eval$helpers; die$@ if$@;
my%children;
sub terminate { my$p=shift;kill 'TERM',$p;waitpid($p,0);delete$children{$p}; }
END { local$?; terminate($_) for keys%children; }
sub findexe {
   my$n=shift;return abs_path($n) if$n=~m{/}&&-x$n;
   for(split(/:/,$ENV{PATH}//'')){my$p="$_/$n";return abs_path($p) if-x$p;}
   die "required executable not found: $n\n";
}
my$stella=findexe($ENV{VCSC_STELLA}||$ENV{STELLA}||'stella');
my$xvfb=findexe($ENV{VCSC_XVFB}||$ENV{XVFB}||'Xvfb');
my(undef,$display)=vcsc_reserve_x_display(250,40);
my$xpid=fork();defined$xpid or die$!;
if(!$xpid){open(STDOUT,'>',"$tmp/xvfb.log");open(STDERR,'>&STDOUT');exec($xvfb,$display,'-ac','-screen','0','1024x768x24');die$!}
$children{$xpid}=1;vcsc_xvfb_assert_ready($display,$xpid);
local$ENV{DISPLAY}=$display;local$ENV{XAUTHORITY}='/dev/null';local$ENV{SDL_AUDIODRIVER}='dummy';
sub capture {
   my($name,$bin)=@_;my$snap="$tmp/snap_$name";my$user="$tmp/user_$name";
   make_path($snap,$user);
   my$p=fork();defined$p or die$!;
   if(!$p){open(STDOUT,'>',"$tmp/stella_$name.log");open(STDERR,'>&STDOUT');
      exec($stella,vcsc_stella_palette_args($repo,$user),
         '-plr.bankrandom','0','-plr.ramrandom','0','-plr.tiarandom','0',
         '-dev.bankrandom','0','-dev.ramrandom','0','-dev.cpurandom','0','-dev.tiarandom','0',
         '-dev.hsrandom','0','-dev.tiadriven','0','-video','software','-turbo','1','-audio.enabled','0',
         '-bs',(-s$bin==8192?'F8':'4K'),'-framesnap','200-239','-snapsavedir',$snap,'-snapname','rom','-sssingle','1','-ss1x','1',
         '-exitlauncher','0','-confirmexit','0','-userdir',$user,$bin);die$!}
   $children{$p}=1;my@png;
   for(1..1200){@png=grep{-s$_}glob("$snap/*.png");last if@png==40;select undef,undef,undef,.025}
   terminate($p);@png==40 or die "$name snapshot count ".scalar(@png)." !=40\n";
   my%frames;
   for(@png){/_([0-9A-F]{8})\.png$/ or die "bad snapshot name\n";$frames{hex$1}=[decode_rgb($_)];}
   return\%frames;
}
my@palettes=([0x2e,0x84],[0x46,0xc2],[0x8e,0x26],[0xae,0x64]);
my@heights=(6,2,6,2,2,10,34,114);
my@seams=(6,8,14,16,18,28,62);
for my$order(qw(above below)) {
   my$base=slurp("$repo/test/fixtures/all_five_181/static_score_$order.c26");
   # Separate X windows and coupled vertical sweep expose continuous all-five
   # silhouettes at every seam; the golden renderer is not the shared schedule.
   $base =~ s/game_BALL_X := 80;/game_BALL_X := 8;/;
   $base =~ s/void main\(void\)/uint8_t motion;\nvoid main(void)/;
   my$updates=join('',map{"      game_${_}_y := motion;\n"}qw(player0 player1 missile0 missile1 ball));
   $base =~ s/(vcs_ntsc_begin_vblank\(\);)/$1\n      motion++;\n      if (motion == 40) { motion := 0; }\n$updates/;
   my@frames;
   for my$i(0..4) {
      my$s=$base;my$name="${order}_$i";
      if($i<4) {
         $s =~ s/COLUPF := 0x2e;/COLUPF := $palettes[$i][0];/;
         $s =~ s/COLUBK := 0x84;/COLUBK := $palettes[$i][1];/;
      } else {
         my$args=join(',',map{my$n=$_+1;my$p=$palettes[$_%4];
            "section${n}_lines:=$heights[$_],section${n}_colupf:=$p->[0],section${n}_colubk:=$p->[1]"}0..7);
         $s =~ s#instantiate "renderers/all_five/all_five.c26" as game \(lines:=181\)#instantiate "renderers/all_five_sections_181/all_five_sections_181.c26" as game ($args)#;
         $s =~ s/^\s*game_player[01]_color\s*:=.*?;\s*\n//mg;
         $s =~ s/^\s*game_playfield_position\s*:=.*?;\s*\n//mg;
      }
      save("$tmp/$name.c26",$s);
      run("$repo/driver/vcsc",'-I',"$repo/libraries/vcs","$tmp/$name.c26",'-o',"$tmp/$name.bin");
      $frames[$i]=capture($name,"$tmp/$name.bin");
   }
   my%crossed;
   for my$f(200..239) {
      my($w,$h,$gold)=@{$frames[0]{$f}};my($aw,$ah,$actual)=@{$frames[4]{$f}};
      $aw==$w&&$ah==$h or die "image geometry differs\n";
      my%counts;$counts{substr($gold,($_*$w+20)*3,3)}++ for 0..$h-1;
      my($bg)=sort{$counts{$b}<=>$counts{$a}}keys%counts;
      my@visible=grep{substr($gold,($_*$w+20)*3,3)eq$bg}0..$h-1;
      @visible==192 or die "$order background extent !=192\n";
      my$first=$visible[0];my$core=$first+($order eq 'above'?15:4);
      my$expected=$gold;my$start=0;
      for my$n(0..7) {
         my$rgb=$frames[$n%4]{$f}[2];
         substr($expected,($core+$start)*$w*3,$heights[$n]*$w*3)=
            substr($rgb,($core+$start)*$w*3,$heights[$n]*$w*3);
         $start+=$heights[$n];
      }
      # Tail (and score below) inherit the final section's background.
      my$end=$first+192;
      substr($expected,($core+176)*$w*3,($end-$core-176)*$w*3)=
         substr($frames[3]{$f}[2],($core+176)*$w*3,($end-$core-176)*$w*3);
      if($actual ne$expected) {
         for my$y(0..$h-1){for my$x(0..$w-1){my$p=($y*$w+$x)*3;
            substr($actual,$p,3)eq substr($expected,$p,3) or die "$order frame $f RGB mismatch at $x,$y (gameplay line ".($y-$core).") actual=".unpack('H6',substr($actual,$p,3))." expected=".unpack('H6',substr($expected,$p,3))."\n";}}
      }
      for my$seam(@seams) {
         for my$obj(['P0',36,56,'e8e8e6'],['P1',256,280,'46ab44'],
                     ['M0',94,110,'e8e8e6'],['M1',214,230,'46ab44'],['BL',10,22,'e8bc48']) {
            my($name,$lo,$hi,$hex)=@$obj;my@seen;
            for my$range([$core+$seam-4,$core+$seam-1],[$core+$seam,$core+$seam+3]) {
               my$found=0;for my$y($range->[0]..$range->[1]){for my$x($lo..$hi){
                  $found=1 if substr($gold,($y*$w+$x)*3,3)eq pack('H6',$hex);}}
               push@seen,$found;
            }
            $crossed{"$name/$seam"}=1 if$seen[0]&&$seen[1];
         }
      }
   }
   for my$seam(@seams){for my$name(qw(P0 P1 M0 M1 BL)){
      $crossed{"$name/$seam"} or die "$order $name never straddled seam $seam\n";}}

   # Certify a full interactive F8 link, not only a smaller private 4K fixture.
   # Its golden ROMs use the ordinary renderer with the same idle artwork/poses.
   my$common=slurp("$repo/test/fixtures/all_five_sections_181/interactive_common.c26");
   my$static=slurp("$repo/test/fixtures/all_five_181/static_score_$order.c26");
   $static =~ s/include "vcs.c26"/include "vcs.c26"\ninclude "playfield.c26"/;
   for my$name(qw(game_playfield p0_graphics p1_graphics)) {
      my($decl)=$common =~ /(page const uint8_t \Q$name\E\[\d+\] := \{.*?\};)/s;
      defined$decl or die "missing public artwork $name\n";
      $static =~ s/page const uint8_t \Q$name\E\[\d+\] := \{.*?\};/$decl/s or die "missing private artwork $name\n";
   }
   my@idle;
   for my$i(0..3) {
      my$s=$static;my$name="${order}_idle_$i";
      $s =~ s/COLUPF := 0x2e;/COLUPF := $palettes[$i][0];/;
      $s =~ s/COLUBK := 0x84;/COLUBK := $palettes[$i][1];/;
      save("$tmp/$name.c26",$s);
      run("$repo/driver/vcsc",'-I',"$repo/libraries/vcs","$tmp/$name.c26",'-o',"$tmp/$name.bin");
      $idle[$i]=capture($name,"$tmp/$name.bin");
   }
   my$name="${order}_public";
   run("$repo/driver/vcsc",'-I',"$repo/libraries/vcs",
      "$repo/test/fixtures/all_five_sections_181/interactive_$order.c26",'-o',"$tmp/$name.bin");
   my$public=capture($name,"$tmp/$name.bin");
   for my$f(200..239) {
      my($w,$h,$gold)=@{$idle[0]{$f}};my($aw,$ah,$actual)=@{$public->{$f}};
      $aw==$w&&$ah==$h or die "public $order geometry differs\n";
      my%counts;$counts{substr($gold,($_*$w+20)*3,3)}++ for 0..$h-1;
      my($bg)=sort{$counts{$b}<=>$counts{$a}}keys%counts;
      my@visible=grep{substr($gold,($_*$w+20)*3,3)eq$bg}0..$h-1;
      @visible==192 or die "public $order visible extent differs\n";
      my$first=$visible[0];my$core=$first+($order eq 'above'?15:4);
      my$expected=$gold;my$start=0;
      for my$n(0..7) {
         substr($expected,($core+$start)*$w*3,$heights[$n]*$w*3)=
            substr($idle[$n%4]{$f}[2],($core+$start)*$w*3,$heights[$n]*$w*3);
         $start+=$heights[$n];
      }
      my$tail=$first+192-$core-176;
      substr($expected,($core+176)*$w*3,$tail*$w*3)=
         substr($idle[3]{$f}[2],($core+176)*$w*3,$tail*$w*3);
      if($actual ne$expected) {
         for my$y(0..$h-1){for my$x(0..$w-1){my$p=($y*$w+$x)*3;
            substr($actual,$p,3)eq substr($expected,$p,3) or die "F8 $order frame $f RGB mismatch at $x,$y (gameplay line ".($y-$core).") actual=".unpack('H6',substr($actual,$p,3))." expected=".unpack('H6',substr($expected,$p,3))."\n";}}
      }
      # Independent row geometry: agreement with the ordinary renderer alone
      # could otherwise conceal an accidental seven-row glyph plus padding.
      for my$glyph(['P0',38,'e8e8e6',[0x18,0x3c,0x66,0x66,0x7e,0x66,0x66,0x66]],
                   ['P1',258,'46ab44',[0x78,0x6c,0x66,0x7c,0x66,0x66,0x6c,0x7c]]) {
         my($id,$left,$hex,$shape)=@$glyph;my@rows;my$colour=pack('H6',$hex);
         for my$y($core..$core+175) {
            my$bits=0;
            for my$bit(0..7) {
               my$x=$left+2*$bit;
               my$a=substr($actual,($y*$w+$x)*3,3)eq$colour;
               my$b=substr($actual,($y*$w+$x+1)*3,3)eq$colour;
               $a==$b or die "F8 $order $id half-pixel glyph\n";
               $bits|=0x80>>$bit if$a;
            }
            push@rows,$bits if$bits;
         }
         my@want=map{($_,$_)}@$shape;
         join(',',@rows)eq join(',',@want) or die "F8 $order $id does not have eight intentional two-line rows\n";
      }
   }
}
print "vcs_all_five_sections_score_raster ok\n";
