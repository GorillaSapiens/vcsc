#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 300
# expectstdout: combined live score RGB ok
# expectexit: 0
# Frozen application driver, independently rendered by the ordinary gameplay
# component. The complementary frozen moving/straddle gates also check score
# pointer preparation against the independent ordinary score implementation.
use strict;
use warnings;
use File::Path qw(make_path);
use IPC::Open3;
use Symbol qw(gensym);
my($repo,$tmp,$mutation)=@ARGV;
defined($mutation)&&$mutation ne 'late_tail'&&$mutation ne 'independent'&&$mutation ne 'independent_bad_handoff' and die 'unknown live mode';
my$independent=defined($mutation)&&$mutation=~/^independent/;
my$driver_file=$independent?'independent':'interactive';
sub slurp {open(my$f,'<',$_[0])or die$!;local$/;return<$f>;}
sub save {open(my$f,'>',$_[0])or die$!;print{$f}$_[1];close$f or die$!;}
sub run {my$e=gensym;my$p=open3(my$i,my$o,$e,@_);close$i;local$/;my$o2=<$o>//'';my$e2=<$e>//'';waitpid($p,0);$?==0 or die "@_ failed\n$o2$e2";}
require "$repo/test/stella_test_lib.pl";
my$helpers=slurp("$repo/test/stella_png_sequence.pl");$helpers=~s/\n\@ARGV>=2.*\z//s or die 'PNG boundary';eval$helpers;die$@if$@;
my%children;
sub terminate {my$p=shift;kill'TERM',$p;waitpid($p,0);delete$children{$p};}
END {local$?;terminate($_)for keys%children;}
my(undef,$display)=vcsc_reserve_x_display(250,40);
my$xp=fork();defined$xp or die$!;
if(!$xp){open(STDOUT,'>',"$tmp/xvfb.log");open(STDERR,'>&STDOUT');exec('Xvfb',$display,'-ac','-screen','0','1024x768x24');die$!;}
$children{$xp}=1;vcsc_xvfb_assert_ready($display,$xp);
local$ENV{DISPLAY}=$display;local$ENV{XAUTHORITY}='/dev/null';local$ENV{SDL_AUDIODRIVER}='dummy';
sub capture {
   my($name,$source)=@_;save("$tmp/$name.c26",$source);
   run("$repo/driver/vcsc",'-I',"$repo/libraries/vcs","$tmp/$name.c26",'-o',"$tmp/$name.bin");
   my$snap="$tmp/snap_$name";my$user="$tmp/user_$name";make_path($snap,$user);
   my$p=fork();defined$p or die$!;
   if(!$p){open(STDOUT,'>',"$tmp/$name.log");open(STDERR,'>&STDOUT');
      exec('stella',vcsc_stella_palette_args($repo,$user),
         '-plr.bankrandom','0','-plr.ramrandom','0','-plr.tiarandom','0',
         '-dev.bankrandom','0','-dev.ramrandom','0','-dev.cpurandom','0','-dev.tiarandom','0',
         '-dev.hsrandom','0','-dev.tiadriven','0','-video','software','-turbo','1','-audio.enabled','0',
         '-bs','F8','-framesnap','200-201','-snapsavedir',$snap,'-snapname','rom','-sssingle','1','-ss1x','1',
         '-exitlauncher','0','-confirmexit','0','-userdir',$user,"$tmp/$name.bin");die$!;
   }
   $children{$p}=1;my@png=vcsc_stella_wait_snapshots("$snap/*.png",2);
   select undef,undef,undef,.025;terminate($p);@png==2 or die 'missing live snapshots';
   my%frames;for(@png){/_([0-9A-F]{8})\.png$/ or die 'frame name';$frames{hex$1}=[decode_rgb($_)];}return\%frames;
}
for my$order(qw(above below)){
   next if defined($mutation)&&$mutation ne 'independent'&&$order eq 'above';
   my$s=slurp("$repo/test/fixtures/all_five_colors_sections_score/$driver_file.c26");
   $s=~s!"component.c26"!"$repo/test/fixtures/all_five_colors_sections_score/component.c26"!g;
   # All eight sections have independent palettes, not four repeated aliases.
   $s=~s/(score_below:=[01])\)/$1,section5_colupf:=0x6e,section5_colubk:=0x12,section6_colupf:=0xce,section6_colubk:=0x72,section7_colupf:=0xde,section7_colubk:=0x92,section8_colupf:=0xfe,section8_colubk:=0xb2)/g;
   $s='alias SCORE_BELOW '.($order eq 'below'?1:0)."\n".$s;
   my$gold_source=$s;
   if(defined($mutation)&&$mutation eq 'independent_bad_handoff'){
      $s=~s/(#if SCORE_BELOW\n)       vcs_ntsc_component_handoff\(\);/$1/ or die 'missing handoff mutation';
   }
   if(defined($mutation)&&$mutation eq 'late_tail'){
      my$component=slurp("$repo/test/fixtures/all_five_colors_sections_score/component.c26");
      $component=~s/   draw_combined_score_tail\(\);/   asm sta WSYNC;\n   draw_combined_score_tail();/ or die 'late terminal mutation';
      save("$tmp/late.c26",$component);
      $s=~s!"$repo/test/fixtures/all_five_colors_sections_score/component.c26"!"$tmp/late.c26"!g;
      $s=~s/(bank0 void draw_combined_score_tail\(void\) \{)\n   asm sta WSYNC;/$1/ or die 'late tail mutation';
   }
   my$actual=capture("${order}_actual",$s);
   my$gold=$gold_source;
   $gold=~s/#if SCORE_BELOW\ninstantiate .*?#endif/instantiate "renderers\/all_five_player_color_181\/all_five_player_color_181.c26" as game/s or die 'ordinary kernel';
   $gold=~s/   game_vblank\(\);\n// or die 'unbank golden preparation';
   $gold=~s/(       prepare_game\(\);)/$1\n       game_vblank();/ or die 'golden preparation call';
   $gold=~s/       game_set_initial_palette\(\);/       COLUPF := 0x2e;\n       COLUBK := 0x84;/ or die 'golden palette';
   if($order eq 'below'&&!$independent){
      $gold=~s/(       game_draw\(\);)/$1\n       vcs_ntsc_component_handoff();\n       score_draw();\n       vcs_ntsc_begin_overscan();/ or die 'golden below handoff';
   }
   my@pal=([46,132],[70,194],[142,38],[174,100],[110,18],[206,114],[222,146],[254,178]);my@gold;
   for my$n(0..7){my$g=$gold;
      $g=~s/COLUPF := 0x2e;/COLUPF := $pal[$n][0];/g;$g=~s/COLUBK := 0x84;/COLUBK := $pal[$n][1];/g;
      $gold[$n]=capture("${order}_gold$n",$g);
   }
   for my$f(200..201){my($w,$h,$expected)=@{$gold[0]{$f}};my%count;
      $count{substr($expected,($_*$w+20)*3,3)}++ for 0..$h-1;
      my($bg)=sort{$count{$b}<=>$count{$a}}keys%count;
      my@visible=grep{substr($expected,($_*$w+20)*3,3)eq$bg}0..$h-1;
      @visible>=176 or die 'live visible extent';my$first=$visible[0]+($order eq 'above'?15:4);
      for my$line(2..$h-$first-1){my$n=$line<14?int($line/2):7;
         substr($expected,($first+$line)*$w*3,$w*3)=substr($gold[$n]{$f}[2],($first+$line)*$w*3,$w*3);
      }
      my($aw,$ah,$rgb)=@{$actual->{$f}};$aw==$w&&$ah==$h or die 'live geometry';
      if($rgb ne$expected){for my$i(0..$w*$h-1){substr($rgb,$i*3,3)eq substr($expected,$i*3,3)or die "$order live RGB mismatch at ".($i%$w).','.int($i/$w)."\n";}}
   }
}
print "combined live score RGB ok\n";
