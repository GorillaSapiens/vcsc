# Test-only bridge: compile the .c26 front end and decode its constant records.
# This is not an input format or generation step for user programs.
use strict;
use warnings;
return sub {
   my($repo,$dir,$h)=@_;
   my$source="include \"vcs.c26\"\ninstantiate \"$repo/test/fixtures/all_five_colors_sections_preview/global_schedule.c26\" as schedule (".join(',',map{'section'.($_+1).'_lines:='.$h->[$_]}0..7).")\n";
   my@data=(115,99,104,100,'schedule_BOUNDARY');
   for my$side(qw(A B)){for my$byte(qw(LO HI)){push@data,map{"schedule_ROUTE_${side}_${byte}_$_"}qw(PARITY PHASE ADVANCE);push@data,0;}}
   for my$side(qw(A B)){push@data,map{"schedule_M1_${side}_$_"}qw(PARITY PHASE ADVANCE LATE);}
   $source.="void main(void) { schedule_init();\n".join('',map{"   asm .byte $_;\n"}@data)."while (true) {} }\n";
   open(my$f,'>',"$dir/plan.c26")or die$!;print{$f}$source;close$f;
   system("$repo/driver/vcsc",'-I',"$repo/libraries/vcs","$dir/plan.c26",'-o',"$dir/plan.bin")==0 or die "c26 geometry @$h\n";
   open($f,'<',"$dir/plan.bin")or die$!;binmode$f;local$/;my$bin=<$f>;close$f;
   my$at=index($bin,pack('C4',115,99,104,100));$at>=0 or die 'c26 schedule descriptor';
   open($f,'<',"$dir/plan.map")or die$!;my$map=<$f>;close$f;
   $map=~/ram\s+used=0 bytes/&&$map=~/CODE\.__vcsc_function\$main load=\$[\dA-F]+ size=\$0023 / or die 'c26 planner emitted RAM or executable code';
   my@bytes=unpack('C25',substr($bin,$at+4,25));my$boundary=shift@bytes;my@donors;
   for my$task(0..5){my($parity,$phase,$advance,$late)=splice@bytes,0,4;next if$task>=4&&!$boundary;
      push@donors,{kind=>$task<4?'route':'m1',destination=>$task<4?int($task/2):$task-4,byte=>$task%2,parity=>$parity,phase=>$phase,advance=>$advance,late=>$late};
   }
   return{boundary=>$boundary,donors=>\@donors};
};
