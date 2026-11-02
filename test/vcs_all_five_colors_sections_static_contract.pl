#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 120
# expectstdout: static geometry contracts ok
# expectexit: 0

use strict;
use warnings;
my($repo,$tmp)=@ARGV;
open(my$f,'<',"$repo/test/fixtures/all_five_player_color_192/smoke.c26")or die$!;local$/;my$base=<$f>;close$f;
$base=~s/include "vcs.c26"/include "vcs.c26"\ninclude "F8\/mapper.c26"/ or die 'contract mapper';
my@bad=(
   ['section1_lines:=0,section2_lines:=192,section3_lines:=0,section4_lines:=0,section5_lines:=0,section6_lines:=0,section7_lines:=0,section8_lines:=0','nonnegative and first nonempty'],
   ['section8_lines:=174','total 192'],
   ['section1_lines:=3,section8_lines:=175','must be even'],
   ['section7_lines:=-2,section8_lines:=182','requires an integer literal'],
   ['section4_colupf:=256','section_colours_must_be_bytes'],
   ['section8_colubk:=-1','requires an integer literal']
);
for my$i(0..$#bad){my($args,$diagnostic)=@{$bad[$i]};my$s=$base;
   $s=~s{instantiate "renderers/all_five_player_color_192/all_five_player_color_192.c26" as game}{instantiate "$repo/test/fixtures/all_five_colors_sections_preview/static_global.c26" as game ($args)} or die 'contract instantiation';
   open($f,'>',"$tmp/bad_$i.c26")or die$!;print{$f}$s;close$f;
   my$pid=fork();defined$pid or die$!;
   if(!$pid){
      open(STDOUT,'>',"$tmp/bad_$i.log")or die$!;open(STDERR,'>&STDOUT')or die$!;
      exec("$repo/driver/vcsc",'-I',"$repo/libraries/vcs","$tmp/bad_$i.c26",'-o',"$tmp/bad_$i.bin");die$!;
   }
   waitpid($pid,0);my$status=$?;
   open($f,'<',"$tmp/bad_$i.log")or die$!;my$log=<$f>//'';close$f;
   $status&&$log=~/\Q$diagnostic\E/ or die "invalid native configuration $i not diagnosed: $log";
}
print "static geometry contracts ok\n";
