#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 240
# expectstdout: c26 global schedule ok
# expectexit: 0

use strict;
use warnings;
use File::Path qw(make_path);
my($repo,$tmp)=@ARGV;
my$planner=do "$repo/test/fixtures/all_five_colors_sections_preview/fine_global_plan.pl";die$@ if$@;
my$c26=do "$repo/test/fixtures/all_five_colors_sections_preview/c26_schedule_plan.pl";die$@ if$@;
srand(192733);my@cases=([2,2,2,2,2,2,4,176],[18,2,2,2,2,2,4,160],[16,16,16,16,32,32,32,32]);
for(1..32){my@seams=sort{$a<=>$b}map{2+2*int(rand(95))}1..7;my(@h,$previous);$previous=0;for(@seams,192){push@h,$_-$previous;$previous=$_;}push@cases,\@h;}
for my$case(0..$#cases){my$h=$cases[$case];my$plan=$planner->($h);my$dir="$tmp/geometry_$case";make_path($dir);
   my$actual=$c26->($repo,$dir,$h);$actual->{boundary}==$plan->{boundary} or die 'c26 boundary';my%slot;
   for my$task(0..$#{$actual->{donors}}){my$d=$actual->{donors}[$task];my($parity,$phase,$advance,$late)=@{$d}{qw(parity phase advance late)};my$dest=$d->{destination};
      $parity<=1&&$phase>=1&&$phase<=6 or die 'c26 donor range';
      !$slot{"$parity:$phase"}++ or die 'c26 donor collision';
      !$plan->{busy}{$parity}{$phase}||($task>=4&&$late&&$phase==6) or die 'c26 palette collision';
      if($task<4){!$late&&$advance==($parity!=$dest?1:0) or die 'c26 route lifetime';}
      else{($late?$parity==$dest&&$phase==6&&$advance==2:$parity!=$dest&&$advance==1) or die 'c26 M1 lifetime';}
   }
}
print "c26 global schedule ok\n";
