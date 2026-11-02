# Private display-wide feasibility planner. No generated files are user inputs.
use strict;
use warnings;
return sub {
   my($heights)=@_;
   @$heights==8 or die "global schedule requires eight heights\n";
   my$total=0;
   for(@$heights){defined($_)&&/^\d+$/&&!($_%2) or die "global schedule requires even nonnegative heights\n";$total+=$_;}
   $total==192&&$heights->[0]>0 or die "global schedule requires total192 and first nonempty\n";
   my(@section,@seams);my$line=0;
   for my$i(0..7){push@section,($i)x$heights->[$i];$line+=$heights->[$i];push@seams,$line if$i<7&&$heights->[$i]&&$line<192;}
   my%busy;
   for my$s(@seams){my$phase=($s%16)/2;next if!$phase||$phase==7;$busy{int($s/16)%2}{$phase}=1;}
   # A route is consumed at pair7. A byte may be loaded in its own row, or
   # by the preceding opposite-parity row. Both choices have the same seven
   # cycle load/store cost; a shifted ROM feed handles the latter without
   # runtime index arithmetic. Each destination has its own two-byte pointer.
   my@free;
   for my$parity(0,1){for my$phase(1..6){push@free,[$parity,$phase] unless$busy{$parity}{$phase}&&$phase!=6;}}
   my$boundary=grep{$_%16==0}@seams;
   my@destination=(0,0,1,1);push@destination,0,1 if$boundary;
   @free>=@destination or die "global schedule has insufficient route slots\n";
   my($best,$best_cost);my%memo;
   my$search;$search=sub{
      my($task,$mask,$cost,$chosen)=@_;
      return if defined($best_cost)&&$cost>=$best_cost;
      return if exists($memo{"$task:$mask"})&&$memo{"$task:$mask"}<=$cost;
      $memo{"$task:$mask"}=$cost;
      if($task==@destination){$best=[@$chosen];$best_cost=$cost;return;}
      my$destination=$destination[$task];
      for my$i(0..$#free){next if$mask&(1<<$i);
         my$cross=$free[$i][0]!=$destination;
         my$late=$task>=4&&!$cross&&$free[$i][1]==6;
         next if$task>=4&&!$cross&&!$late;
         next if$busy{$free[$i][0]}{$free[$i][1]}&&!$late;
         $search->($task+1,$mask|(1<<$i),$cost+($late?200:$cross?100:0)+$free[$i][1],[@$chosen,$free[$i]]);
      }
   };
   $search->(0,0,0,[]);
   defined$best or die "global schedule has insufficient lifetime-safe slots\n";
   my@donors;
   for my$task(0..$#destination){my($parity,$phase)=@{$best->[$task]};my$dest=$destination[$task];
      push@donors,{kind=>$task<4?'route':'m1',late=>($task>=4&&$parity==$dest?1:0),parity=>$parity,phase=>$phase,destination=>$dest,byte=>$task%2,advance=>($parity!=$dest?1:$task<4?0:2)};
   }
   return {heights=>[@$heights],section=>\@section,seams=>\@seams,busy=>\%busy,donors=>\@donors,boundary=>$boundary?1:0};
};
