#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 240
# expectstdout: combined score examples ok
# expectexit: 0
use strict;
use warnings;
use IPC::Open3;
use Symbol qw(gensym);
my($repo,$tmp,$mode)=@ARGV;
defined($mode)&&$mode ne 'independent'&&$mode ne 'prefix'&&$mode ne 'later'&&$mode ne 'boundary' and die 'unknown composition mode';
my$boundary=defined($mode)&&$mode eq 'boundary';
my$later=$boundary||(defined($mode)&&$mode eq 'later');
my$driver_file=$boundary?'boundary':$later?'later':defined($mode)?'independent':'interactive';
my$prefix=defined($mode)&&$mode eq 'prefix';
sub slurp {open(my$f,'<',$_[0])or die$!;local$/;return<$f>;}
sub run {my$e=gensym;my$p=open3(my$i,my$o,$e,@_);close$i;local$/;
   my$out=<$o>//'';my$err=<$e>//'';waitpid($p,0);$?==0 or die "@_ failed\n$out$err";return$out;}
my$mos="$repo/simulator/mos6502";
for my$pair(['timing','vcs_frame_timing.cpp'],['controls','vcs_all_five_interactive_example_matrix.cpp']){
   run($ENV{CXX}||'c++','-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,
      "$repo/test/$pair->[1]","$mos/mos6502.o",'-o',"$tmp/$pair->[0]");
}
for my$order(qw(above below)){
   # Editable leaves are independently covered by vcs_examples_build.pl.
   my$fixture=slurp("$repo/test/fixtures/all_five_colors_sections_score/$driver_file.c26");
   $fixture=~s!"component.c26"!"$repo/test/fixtures/all_five_colors_sections_score/component.c26"!g;
   $fixture=~s!"later_component.c26"!"$repo/test/fixtures/all_five_colors_sections_score/later_component.c26"!g if$later;
   $fixture=~s!"boundary_component.c26"!"$repo/test/fixtures/all_five_colors_sections_score/boundary_component.c26"!g if$boundary;
   if($prefix){
      $fixture=~s!/component.c26"!/prefix_component.c26"!g;
      $fixture=~s/score_below:=0/section1_lines:=4,section2_lines:=0,section3_lines:=2,section4_lines:=0,section5_lines:=4,section6_lines:=0,section7_lines:=0,section8_lines:=166/g;
   }
   open(my$f,'>',"$tmp/$order.c26")or die$!;print{$f}'alias SCORE_BELOW '.($order eq 'below'?1:0)."\n$fixture";close$f;
   my$bin="$tmp/$order.bin";my$out=run("$repo/driver/vcsc",'-I',"$repo/libraries/vcs","$tmp/$order.c26",'-o',$bin);
   -s$bin==8192 or die 'not ordinary F8';
   $out=~/ram\s+used=(\d+) bytes/&&$1<=128 or die "RAM budget\n$out";
   my$s=slurp("$tmp/$order.sym");
   my$address=sub{my$n=shift;$s=~/^\Q$n\E\s+([0-9a-fA-F]{4})\s*$/m or die "missing $n";return hex$1;};
   run("$tmp/controls",$bin,"all5_color181_$order",map{$address->($_)}qw(game_object_x game_player0_y game_player1_y game_missile0_y game_missile1_y game_ball_y selected_object select_latched selected_digit score_latched score_score score_color));
   run("$tmp/timing",$bin,'420','--no-audio','--released-inputs','--raw-lines','264');
   my@runtime=('--randomize-zp',$address->('game_object_x'),5,160,733,
      '--randomize-zp',$address->('game_player0_nusiz'),2,256,911);
   for my$n(qw(game_player0_y game_player1_y game_missile0_y game_missile1_y game_ball_y)){
      push@runtime,'--randomize-zp',$address->($n),1,256,955+scalar@runtime;
   }
   for my$n(qw(game_player0_height game_player1_height game_missile0_height game_missile1_height game_ball_height)){
      push@runtime,'--randomize-zp',$address->($n),1,8,955+scalar@runtime;
   }
   run("$tmp/timing",$bin,'420','--no-audio','--released-inputs','--raw-lines','264',@runtime);
   my@art=(
      [0x42,0xa5,0xbd,0xff,0xdb,0x7e,0x3c,0x66], [0x24,0x5a,0xbd,0xff,0xdb,0x7e,0x5a,0x99],
      [0x42,0xa5,0xbd,0xff,0xdb,0x7e,0x5a,0x81], [0x81,0x5a,0xbd,0xff,0xdb,0x7e,0x3c,0x24],
      [0xa5,0x5a,0x24,0xff,0xdb,0xff,0x66,0x3c], [0x54,0x3c,0x42,0xff,0xdb,0xff,0x66,0x3c],
      [0x24,0x5a,0x81,0xff,0xdb,0xff,0x66,0x3c], [0x2a,0x3c,0x42,0xff,0xdb,0xff,0x66,0x3c]);
   my$a=$address->('animations');($a&255)<=192 or die 'animation crosses page';
   substr(slurp($bin),4096+($a&4095),64)eq pack('C*',map{reverse@$_}@art) or die 'upright artwork changed';
}
# Unsupported geometry must not silently retain the fixed schedule.
my$c=slurp("$repo/test/fixtures/all_five_colors_sections_score/interactive.c26");
$c=~s!"component.c26"!"$repo/test/fixtures/all_five_colors_sections_score/component.c26"!g;
$c=~s/score_below:=0/score_below:=0,section1_lines:=4/ or die 'invalid geometry marker';
open(my$f,'>',"$tmp/invalid.c26")or die$!;print{$f}"alias SCORE_BELOW 0\n$c";close$f;
eval{run("$repo/driver/vcsc",'-I',"$repo/libraries/vcs","$tmp/invalid.c26",'-o',"$tmp/invalid.bin")};
$@=~/supports only heights/ or die 'unsupported geometry was not explicitly refused';
if($prefix||$later){
   my$base=slurp("$repo/test/fixtures/all_five_colors_sections_score/independent.c26");
   my$renderer=$boundary?'boundary_component':$later?'later_component':'prefix_component';
   $base=~s!"component.c26"!"$repo/test/fixtures/all_five_colors_sections_score/$renderer.c26"!g;
   for my$case(
      $boundary?(['beyond','2,2,2,2,2,2,8,156',qr/seams2\.\.18/]):(['later','2,2,2,2,2,2,4,160',$later?qr/seam16/:qr/all seams within14/]),
      $later&&!$boundary?(['beyond','2,2,2,2,2,2,8,156',qr/seams2\.\.14 or18/],['middle16','2,2,2,2,2,6,2,158',qr/seam16/]):(),
      ['odd','3,1,2,2,2,2,2,162',qr/even section heights/],
      ['empty','0,4,2,2,2,2,2,162',qr/first nonempty/],
      ['negative','4,-2,2,2,2,2,4,162',qr/nonnegative heights|requires an integer literal/],
      ['total','2,2,2,2,2,2,2,164',qr/total176/]){
      my($name,$heights,$error)=@$case;my@h=split/,/,$heights;
      my$args=join(',',map{'section'.($_+1).'_lines:='.$h[$_]}0..7);my$s=$base;
      $s=~s/score_below:=0/$args/g;
      open(my$f,'>',"$tmp/reject_$name.c26")or die$!;print{$f}"alias SCORE_BELOW 0\n$s";close$f;
      eval{run("$repo/driver/vcsc",'-I',"$repo/libraries/vcs","$tmp/reject_$name.c26",'-o',"$tmp/reject_$name.bin")};
      $@=~$error or die "$name prefix geometry was not explicitly rejected: $@";
   }
   my$default=slurp("$repo/test/fixtures/all_five_colors_sections_score/independent.c26");
   $default=~s!"component.c26"!"$repo/test/fixtures/all_five_colors_sections_score/component.c26"!g;
   open(my$old,'>',"$tmp/prefix_old_default.c26")or die$!;print{$old}"alias SCORE_BELOW 1\n$default";close$old;
   run("$repo/driver/vcsc",'-I',"$repo/libraries/vcs","$tmp/prefix_old_default.c26",'-o',"$tmp/prefix_old_default.bin");
   $default=~s!/component.c26"!/$renderer.c26"!g;
   $default=~s/score_below:=0/section1_lines:=2,section2_lines:=2,section3_lines:=2,section4_lines:=2,section5_lines:=2,section6_lines:=2,section7_lines:=2,section8_lines:=162/g;
   open(my$new,'>',"$tmp/prefix_new_default.c26")or die$!;print{$new}"alias SCORE_BELOW 1\n$default";close$new;
   run("$repo/driver/vcsc",'-I',"$repo/libraries/vcs","$tmp/prefix_new_default.c26",'-o',"$tmp/prefix_new_default.bin");
   slurp("$tmp/prefix_old_default.bin")eq slurp("$tmp/prefix_new_default.bin") or die 'prefix generalization changed default ROM';
}
# The new initializer parameter must leave the historical default ROM intact.
my$component=slurp("$repo/libraries/vcs/six_glyph_component.c26");
$component=~s/parameter initial_color := 0x0e;\n// or die 'initial colour default';
$component=~s/TEMPLATE_color := TEMPLATE_initial_color;/TEMPLATE_color := 0x0e;/ or die 'old literal initializer';
open(my$old,'>',"$tmp/old_score.c26")or die$!;print{$old}$component;close$old;
my$default=slurp("$repo/test/fixtures/six_glyph_component/poison_then_centered_color.c26");
open(my$df,'>',"$tmp/default.c26")or die$!;print{$df}$default;close$df;
run("$repo/driver/vcsc",'-I',"$repo/libraries/vcs","$tmp/default.c26",'-o',"$tmp/default.bin");
$default=~s!"six_glyph_component.c26"!"$tmp/old_score.c26"! or die 'old component instance';
open(my$of,'>',"$tmp/old.c26")or die$!;print{$of}$default;close$of;
run("$repo/driver/vcsc",'-I',"$repo/libraries/vcs","$tmp/old.c26",'-o',"$tmp/old.bin");
slurp("$tmp/default.bin")eq slurp("$tmp/old.bin") or die 'default initial colour changed ROM';
print "combined score examples ok\n";
