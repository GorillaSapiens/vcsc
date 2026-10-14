#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 180
# expectstdout: vcs_all_five_sections_score ok
# expectexit: 0
use strict;
use warnings;
use IPC::Open3;
use Symbol qw(gensym);
my($repo,$tmp)=@ARGV;
defined$tmp or die "usage: $0 REPO TMP\n";
sub read_file { open(my$f,'<',$_[0]) or die$!; local$/; return <$f>; }
sub write_file { open(my$f,'>',$_[0]) or die$!; print{$f}$_[1]; close$f or die$!; }
sub capture {
   my$err=gensym; my$p=open3(my$i,my$o,$err,@_); close$i;
   local$/; my$out=<$o>//''; my$e=<$err>//''; waitpid($p,0);
   $?==0 or die "@_ failed\n$out$e";
   return$out;
}
sub reject {
   my($label,$source,$pattern)=@_;
   my$file="$tmp/reject_$label.c26";write_file($file,$source);
   my$err=gensym;my$p=open3(my$i,my$o,$err,"$repo/driver/vcsc",'-I',"$repo/libraries/vcs",$file,'-o',"$tmp/reject_$label.bin");close$i;
   local$/;my$out=<$o>//'';my$e=<$err>//'';waitpid($p,0);
   $?&&$e =~ $pattern or die "$label configuration was not rejected as expected\n$out$e";
}
sub address {
   my($s,$name)=@_; $s =~ /^\Q$name\E\s+([a-fA-F0-9]{4})\s*$/m or die "missing $name\n";
   return hex$1;
}
my$mos="$repo/simulator/mos6502";
for my$pair (
   ['timing','vcs_frame_timing.cpp'],
   ['controls','vcs_all_five_interactive_example_matrix.cpp'],
   ['score','vcs_score_matrix_raster.cpp'],
   ['objects','vcs_all_five_composition.cpp']) {
   capture($ENV{CXX}||'c++','-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,
      "$repo/test/$pair->[1]","$mos/mos6502.o",'-o',"$tmp/$pair->[0]");
}
for my$order(qw(above below)) {
   my$source=read_file("$repo/test/fixtures/all_five_181/static_score_$order.c26");
   $source =~ s#instantiate "renderers/all_five/all_five.c26" as game \(lines:=181\)#instantiate "renderers/all_five_sections_181/all_five_sections_181.c26" as game# or die "missing renderer\n";
   $source =~ s/^\s*game_player[01]_color\s*:=.*?;\s*\n//mg;
   $source =~ s/^\s*game_playfield_position\s*:=.*?;\s*\n//mg;
   if($order eq 'above') {
      for my$case(
         ['total','section1_lines:=192',qr/Section heights/],
         ['odd','section1_lines:=175,section2_lines:=1',qr/Section heights/],
         ['negative','section1_lines:=178,section2_lines:=-2',qr/Section heights|requires an integer literal/],
         ['empty','section1_lines:=0,section2_lines:=176',qr/Section heights/],
         ['colour','player0_color:=256',qr/player_colours_must_be_bytes/],
         ['profile','PROFILE_LINES:=192',qr/Internal profile constants/]) {
         my($label,$args,$pattern)=@$case;my$bad=$source;
         $bad =~ s/(as game)\b/$1 ($args)/ or die "missing configuration\n";
         reject($label,$bad,$pattern);
      }
   }
   write_file("$tmp/$order.c26",$source);
   capture("$repo/driver/vcsc",'-I',"$repo/libraries/vcs","$tmp/$order.c26",'-o',"$tmp/$order.bin");
   capture("$tmp/timing","$tmp/$order.bin",'420','--no-audio','--released-inputs','--raw-lines','264');
   capture("$tmp/score","$tmp/$order.bin",'center',$order eq 'above'?40:221);
   capture("$tmp/objects","$tmp/$order.bin",$order,'static','post-resp-player');

   my$public="$repo/test/fixtures/all_five_sections_181/interactive_$order.c26";
   my$bin="$tmp/public_$order.bin";
   capture("$repo/driver/vcsc",'-I',"$repo/libraries/vcs",$public,'-o',$bin);
   -s$bin==8192 or die "$order interactive fixture is not F8\n";
   my$sym=read_file("$tmp/public_$order.sym");
   my$y=address($sym,'object_y');
   capture("$tmp/controls",$bin,"all5_color181_$order",
      address($sym,'game_object_x'),(map{$y+$_}0..4),
      map{address($sym,$_)}qw(selected_object select_switch_latched selected_score_digit right_joystick_latched score_score score_color));
   capture("$tmp/timing",$bin,'420','--no-audio','--released-inputs','--raw-lines','264');
   # State-dependent sprite paths, all X residues, and arbitrary Y bytes must
   # not change the frame budget, including preparation's bank-call stack.
   capture("$tmp/timing",$bin,'420','--no-audio','--released-inputs','--raw-lines','264',
      '--randomize-zp',address($sym,'game_object_x'),5,160,731,
      '--randomize-zp',$y,5,256,913,
      '--randomize-zp',address($sym,'game_player0_height'),2,8,101,
      '--randomize-zp',address($sym,'game_player0_nusiz'),2,256,307);
   # Swap complete, page-contained graphics pointers only at the frame boundary.
   # Both bankswitch preparation and the draw must preserve temporary heights.
   my@graphics=map{address($sym,$_)}qw(p0_graphics p1_graphics);
   my@pointer_args;
   for my$n(qw(game_player0_graphics game_player1_graphics)) {
      my$a=address($sym,$n);
      push@pointer_args,'--frame-sequence',$a,join(',',map{$_&255}@graphics),
         '--frame-sequence',$a+1,join(',',map{$_>>8}@graphics);
   }
   capture("$tmp/timing",$bin,'420','--no-audio','--released-inputs','--raw-lines','264',
      @pointer_args,
      '--expect-memory',address($sym,'game_player0_height'),7,
      '--expect-memory',address($sym,'game_player1_height'),7);
}
print "vcs_all_five_sections_score ok\n";
