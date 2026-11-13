#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 120
# expectstdout: vcs_layers_events ok
# expectexit: 0
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use IPC::Open3;
use Symbol qw(gensym);
my($repo,$tmp)=@ARGV;$repo=abs_path($repo);make_path($tmp);$tmp=abs_path($tmp);
sub slurp{open my$f,'<:raw',$_[0]or die$!;local$/;return<$f>;}
sub save{open my$f,'>:raw',$_[0]or die$!;print$f $_[1];}
sub run{
   my$e=gensym;my$p=open3(my$i,my$o,$e,@_);close$i;local$/;
   my$s=<$o>//'';my$t=<$e>//'';waitpid($p,0);die"@_\n$s$t"if$?;return$s;
}
run("$repo/driver/vcsc",'-I',"$repo/libraries/vcs","$repo/test/fixtures/layers/events.c26",'-o',"$tmp/events.bin");
my$sym=slurp("$tmp/events.sym");my%addr;
while($sym=~/^(\w+)\s+([0-9a-fA-F]{4})\s*$/mg){$addr{$1}=hex$2;}
my%names=(DATA=>'layers_event_data',CURRENT=>'layers_current_mask',REMAIN=>'layers_run_remaining',
   SAVED=>'layers_saved_stack',BLANK=>'layers_player1_blank_color',PHASE=>'phase',EXTENT=>'extent',
   Y0=>'layers_missile0_y',Y1=>'layers_missile1_y',Y2=>'layers_ball_y',
   H0=>'layers_missile0_height',H1=>'layers_missile1_height',H2=>'layers_ball_height');
my$defs='';for my$n(sort keys%names){exists$addr{$names{$n}}or die"missing $names{$n}";$defs.="#define $n $addr{$names{$n}}\n";}
my$hook=<<'CPP';
      if (!(event.address & 0x1080) && (event.address & 63)==1 && !(event.value & 2)) {
         static unsigned frame=0,max_runs=0;
         static bool saw_merged=false,saw_wrap=false,saw_empty=false;
         const unsigned phase=frame&255,extent=(frame>>8)&255;
         ++frame;
         const unsigned ys[]={Y0,Y1,Y2},hs[]={H0,H1,H2},bias[]={1,1,2},bits[]={4,1,2};
         const unsigned wanted_y[]={phase,(phase*5+extent)&255,(phase*11+extent*3)&255};
         const unsigned wanted_h[]={(extent*17)&255,(phase^(extent*7))&255,((255-phase)*3+extent)&255};
         if(peek_memory(PHASE)!=phase || peek_memory(EXTENT)!=extent || peek_memory(SAVED)!=165 || peek_memory(BLANK)!=238) {
            std::fprintf(stderr,"event preparation state/canary mismatch\n");std::exit(1);
         }
         for(unsigned o=0;o<3;++o) if(peek_memory(ys[o])!=wanted_y[o] || peek_memory(hs[o])!=wanted_h[o]) {
            std::fprintf(stderr,"event preparation changed an input\n");std::exit(1);
         }
         unsigned cursor=0,remaining=peek_memory(DATA),mask=peek_memory(DATA+1);
         if(peek_memory(CURRENT)!=mask || peek_memory(REMAIN)!=remaining) {
            std::fprintf(stderr,"event initial state mismatch\n");std::exit(1);
         }
         for(unsigned pair=0;pair<96;++pair) {
            if(pair && --remaining==0) {
               cursor+=2;
               if(cursor>=14){std::fprintf(stderr,"too many events\n");std::exit(1);}
               remaining=peek_memory(DATA+cursor);
               const unsigned next=peek_memory(DATA+cursor+1),delta=mask^next;
               if(delta && (delta&(delta-1)))saw_merged=true;
               mask=next;
               if(!remaining){std::fprintf(stderr,"zero duration\n");std::exit(1);}
            }
            unsigned wanted=0;
            for(unsigned o=0;o<3;++o) {
               const unsigned end=(wanted_y[o]+bias[o])&255,start=(end-wanted_h[o])&255;
               bool on=start>end;
               if(on)saw_wrap=true;
               if((start?start-1:0)<=pair)on=!on;
               if(end<=pair)on=!on;
               if(on)wanted|=bits[o];
            }
            if(mask!=wanted){std::fprintf(stderr,"event interval mismatch pair=%u\n",pair);std::exit(1);}
         }
         if(cursor/2+1>max_runs)max_runs=cursor/2+1;
         if(!cursor && !mask)saw_empty=true;
         if(frame==4090 && (max_runs!=7 || !saw_merged || !saw_wrap || !saw_empty)) {
            std::fprintf(stderr,"event test lacks maximum/merged/wrap/empty witnesses\n");std::exit(1);
         }
         if(peek_memory(DATA+cursor)!=255){std::fprintf(stderr,"missing final sentinel\n");std::exit(1);}
         for(unsigned i=cursor+2;i<14;++i) if(peek_memory(DATA+i)!=165) {
            std::fprintf(stderr,"event tail overwritten\n");std::exit(1);
         }
      }
CPP
my$cpu=$defs.slurp("$repo/test/vcs_frame_timing.cpp");
$cpu=~s/(   for \(const WriteEvent &event : writes\) \{)/$1\n$hook/ or die 'event hook';
save("$tmp/timing.cpp",$cpu);my$mos="$repo/simulator/mos6502";
my$obj=-f"$mos/mos6502.o"?"$mos/mos6502.o":"$mos/mos6502.cpp";
run($ENV{CXX}||'c++','-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,"$tmp/timing.cpp",$obj,'-o',"$tmp/timing");
run("$tmp/timing","$tmp/events.bin",'4096','--no-audio','--released-inputs','--raw-lines','264');
print "vcs_layers_events ok\n";
