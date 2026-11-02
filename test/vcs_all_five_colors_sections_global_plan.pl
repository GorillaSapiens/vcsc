#!/usr/bin/perl
# runner: perl @FILE@ @REPO@
# phase: e2e
# expectstdout: global plan ok
# expectexit: 0

use strict;
use warnings;
my($repo)=@ARGV;
my$plan=do "$repo/test/fixtures/all_five_colors_sections_preview/fine_global_plan.pl";
die$@ if$@;
for my$bad([2,2], [0,0,0,0,0,0,0,192], [3,1,2,2,2,2,2,178], [2,2,2,2,2,2,2,176]){
   eval{$plan->($bad)};length($@) or die 'invalid geometry accepted';
}
my$formerly_refused=$plan->([2,2,2,2,2,2,4,176]);
grep{$_->{late}}@{$formerly_refused->{donors}} or die 'late refill not exercised';
srand(733);my($accepted,$refused)=(0,0);
# Exhaust all parity/phase unions possible with one boundary and six remaining
# seams. Multiple boundaries or phase14 events only remove busy reservations.
for my$mask(0..4095){my@seams=(16);
   for my$i(0..11){push@seams,($i<6?0:16)+2*($i%6+1) if$mask&(1<<$i);}
   next if@seams>7;@seams=sort{$a<=>$b}@seams;
   my(@h,$prior);$prior=0;for(@seams,192){push@h,$_-$prior;$prior=$_;}
   push@h,0 while@h<8;
   $plan->(\@h);
}
for(1..2000){my@seams=sort{$a<=>$b}map{2+2*int(rand(95))}1..7;my@h;my$prior=0;
   for(@seams,192){push@h,$_-$prior;$prior=$_;}
   my$p=eval{$plan->(\@h)};
   if(!$p){$@=~/insufficient (?:route|lifetime-safe) slots/ or die$@;++$refused;next;}
   ++$accepted;@{$p->{section}}==192 or die 'extent';my(%slot,%task);
   for my$d(@{$p->{donors}}){
      !$p->{busy}{$d->{parity}}{$d->{phase}}||$d->{late} or die 'palette collision';
      !$slot{"$d->{parity}:$d->{phase}"}++ or die 'donor collision';
      !$task{"$d->{kind}:$d->{destination}:".($d->{kind}eq'route'?$d->{byte}:0)}++ or die 'duplicate task';
      if($d->{kind}eq'm1'){
         ($d->{late}?$d->{parity}==$d->{destination}&&$d->{advance}==2&&$d->{phase}==6:$d->{parity}!=$d->{destination}&&$d->{advance}==1) or die 'live M1 lane overwritten';
      }
      else{$d->{advance}==($d->{parity}!=$d->{destination}?1:0) or die 'route deadline';}
   }
   keys(%task)==($p->{boundary}?6:4) or die 'missing task';
}
$accepted==2000&&$refused==0 or die 'fuzz coverage';
print "global plan ok\n";
