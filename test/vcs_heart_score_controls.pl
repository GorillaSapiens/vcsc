#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 120
# expectstdout: vcs_heart_score_controls ok
# expectexit: 0
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);
my($repo,$tmp)=@ARGV; $repo=abs_path($repo); make_path($tmp); $tmp=abs_path($tmp);
sub read_file { open my$f,'<:raw',$_[0] or die$!; local$/; return <$f>; }
sub save { open my$f,'>:raw',$_[0] or die$!; print {$f} $_[1]; close$f or die$!; }
sub run {
   my$err=gensym; my$p=open3(my$i,my$o,$err,@_); close$i; local$/;
   my$s=<$o>//''; my$e=<$err>//''; waitpid($p,0); die "@_\n$s$e" if $?; return$s;
}
sub symbol {
   my($stem,$name)=@_; my$s=read_file("$stem.sym");
   $s=~/^\Q$name\E\s+([0-9a-fA-F]{4})\s*$/m or die "missing $name"; return hex$1;
}
# Exercise actual public controller code with frame-indexed bus input, not
# startup hold flags. All objects traverse both coordinate limits. SELECT and
# right-stick holds/rolls, health/marker saturation, and RESET are independent
# of the preset-only raster fixture below.
my@steps=([5,255,255]);
for my$o(0..2) {
   push@steps,[3,255,253],[2,255,255] if$o;
   push@steps,[200,95,255],[200,175,255],[2,255,255];
}
push@steps,[3,255,253],[2,255,255],[2,15,255];
for my$joy(254,253,251,247) {
   for(1..40) { push@steps,[2,$joy,255],[1,255,255]; }
}
push@steps,[3,254,255],[3,253,255],[1,255,255]; # direction roll cannot re-arm
my$total=0; $total+=$_->[0] for@steps;
my$prefix=<<'CPP';
struct HeartInput { unsigned duration, joystick, switches; };
static constexpr HeartInput heart_steps[]={ HEART_STEPS };
static unsigned heart_frame=0;
static bool heart_sync=false;
static HeartInput heart_input{0,255,255};
struct HeartModel {
   unsigned x[3]={44,108,78},y[3]={70,42,45};
   unsigned selected=0,select_ready=1,joy_ready=15,health=11,markers=8;
};
static HeartModel heart_model;
static HeartModel heart_initial;
static bool heart_visible=false;
static bool heart_resp_seen[2]={false,false};
static unsigned heart_resp_phase[2],heart_resp_wanted[2];
static unsigned long long heart_last_sync=0;
static HeartInput heart_input_at(unsigned frame) {
   for(auto step:heart_steps) { if(frame<step.duration) return step; frame-=step.duration; }
   if(frame==10) return {1,255,254};
   return {1,255,255};
}
static void heart_advance() {
   auto&m=heart_model; const auto&i=heart_input;
   if(!(i.switches&1)) { m=heart_initial; return; }
   if(i.switches&2) m.select_ready=1;
   else if(m.select_ready) { m.selected=(m.selected+1)%3; m.select_ready=0; }
   auto&x=m.x[m.selected]; auto&y=m.y[m.selected];
   if(!(i.joystick&64)) { if(x) --x; }
   else if(!(i.joystick&128)) { if(x<159) ++x; }
   if(!(i.joystick&16)) { if(y) --y; }
   else if(!(i.joystick&32)) { if(y<87) ++y; }
   if(m.joy_ready) {
      if((i.joystick&15)!=15) {
         if(!(i.joystick&1)) { if(m.health<22) ++m.health; }
         else if(!(i.joystick&2)) { if(m.health) --m.health; }
         else if(!(i.joystick&4)) { if(m.markers) --m.markers; }
         else if(!(i.joystick&8)) { if(m.markers<11) ++m.markers; }
         m.joy_ready=0;
      }
   } else if((i.joystick&15)==15) m.joy_ready=15;
}
CPP
$prefix=~s/HEART_STEPS/join(',',map{'{'.join(',',@$_).'}'}@steps)/e;
my$hook=<<'CPP';
      if(event.address==1) heart_visible=!(event.value&2);
      if(heart_visible && (event.address==0x10 || event.address==0x11)) {
         const unsigned lane=event.address-0x10;
         // Gameplay is last in score-above and first in score-below. Both
         // player restore lines have RESP at cycle17+5*coarse_steps.
         if(!COMPOSITION_BELOW || !heart_resp_seen[lane]) {
            heart_resp_phase[lane]=virtual_cycles%76;
            const unsigned x=peek_memory(G0X+lane);
            heart_resp_wanted[lane]=17+5*(1+(x+2)/15);
            heart_resp_seen[lane]=true;
         }
      }
      if(event.address==0) {
         const bool next=(event.value&2)!=0;
         if(next&&!heart_sync) {
            if(heart_frame>1 && (heart_input.switches&1) && virtual_cycles-heart_last_sync!=20216) {
               std::fprintf(stderr,"heart frame %u period %llu expected 20216 (266 raw harness lines)\n",
                  heart_frame,(unsigned long long)(virtual_cycles-heart_last_sync)); std::exit(1);
            }
            heart_last_sync=virtual_cycles;
            for(unsigned lane=0;lane<2;++lane) {
               if(heart_frame && (!heart_resp_seen[lane] || heart_resp_phase[lane]!=heart_resp_wanted[lane])) {
                  std::fprintf(stderr,"heart frame %u P%u restore phase %u expected %u\n",
                     heart_frame,lane,heart_resp_phase[lane],heart_resp_wanted[lane]); std::exit(1);
               }
               heart_resp_seen[lane]=false;
            }
            auto check=[](unsigned address,unsigned want) {
               if(peek_memory(address)!=want) {
                  std::fprintf(stderr,"heart frame %u address $%04x got %u want %u\n",
                     heart_frame,address,peek_memory(address),want); std::exit(1);
               }
            };
#if SEQUENCE_MODE
            const unsigned tick=heart_frame%96,state=tick/16;
            check(TICK,tick); check(G0X,state==5?159:44);
            check(SCORE,state==1?6:5); check(HALF,(state==1||state==2)?0:1);
            check(MARKERS,state==3?7:state==4?9:8);
#else
            const unsigned game_x[]={G0X,G1X,GBX},game_y[]={G0Y,G1Y,GBY};
            // Public scenes remain editable: learn the initial pose/health,
            // then independently model relative input effects and RESET.
            if(heart_frame==0) {
               for(unsigned n=0;n<3;++n) { heart_model.x[n]=peek_memory(XS+n); heart_model.y[n]=peek_memory(YS+n); }
               heart_model.selected=peek_memory(SELECTED); heart_model.select_ready=peek_memory(SELECT_READY);
               heart_model.joy_ready=peek_memory(JOY_READY);
               heart_model.health=peek_memory(SCORE)*2+peek_memory(HALF); heart_model.markers=peek_memory(MARKERS);
               heart_initial=heart_model;
            }
            for(unsigned n=0;n<3;++n) {
               check(XS+n,heart_model.x[n]); check(YS+n,heart_model.y[n]);
               check(game_x[n],heart_model.x[n]); check(game_y[n],heart_model.y[n]);
            }
            check(SELECTED,heart_model.selected); check(SELECT_READY,heart_model.select_ready);
            check(JOY_READY,heart_model.joy_ready);
            check(SCORE,heart_model.health/2); check(HALF,heart_model.health%2); check(MARKERS,heart_model.markers);
#endif
            heart_input=heart_input_at(heart_frame++); heart_advance();
         }
         heart_sync=next;
      }
CPP
my$original=read_file("$repo/test/vcs_frame_timing.cpp");
my$mos="$repo/simulator/mos6502"; my$obj=-f"$mos/mos6502.o"?"$mos/mos6502.o":"$mos/mos6502.cpp";
for my$kind(qw(above below)) {
   for my$sequence(0,1) {
      my$stem="$tmp/${kind}_".($sequence?'sequence':'controls');
      my$source=$sequence?"$repo/test/fixtures/heart_score/composition_sequence.c26":
         File::Spec->catfile($repo,qw(examples 04_renderers player_color),"score_$kind",'heart',"heart_score_${kind}_interactive.c26");
      run("$repo/driver/vcsc",'-I',"$repo/libraries/vcs",'-Map',"$stem.map",
         '-DHEART_COMPOSITION_BELOW='.($kind eq 'below'?1:0),$source,'-o',"$stem.bin");
      -s"$stem.bin"==4096 or die 'heart composition must remain one 4K bank';
      my%names=(G0X=>'game_object_x',SCORE=>'score_score',HALF=>'score_half',MARKERS=>'score_lines');
      if($sequence) { $names{TICK}='sequence_tick'; }
      else {
         %names=(%names,XS=>'demo_object_x',YS=>'demo_object_y',
            G0Y=>'game_player0_y',G1Y=>'game_player1_y',GBY=>'game_ball_y',
            SELECTED=>'selected_object',SELECT_READY=>'select_switch_ready',JOY_READY=>'right_joystick_ready');
      }
      my%defines=(SEQUENCE_MODE=>$sequence,COMPOSITION_BELOW=>($kind eq 'below'?1:0)); $defines{$_}=symbol($stem,$names{$_}) for keys%names;
      $defines{G1X}=$defines{G0X}+1; $defines{GBX}=$defines{G0X}+4;
      my$cpu=join('',map{"#define $_ $defines{$_}\n"}sort keys%defines).$prefix.$original;
      my$read_hook=<<'CPP';
   if(address==0x280 || address==0x282 || (address>=0x38 && address<=0x3d)) {
#if SEQUENCE_MODE
      std::fprintf(stderr,"preset raster fixture read joystick/console input\n"); std::exit(1);
#else
      if(address==0x280) return heart_input.joystick;
      if(address==0x282) return heart_input.switches;
#endif
   }
CPP
      $cpu=~s/(uint8_t read_bus\(uint16_t address\) \{)/$1\n$read_hook/ or die 'input hook';
      $cpu=~s/(   for \(const WriteEvent &event : writes\) \{)/$1\n$hook/ or die 'CPU hook';
      save("$stem.cpp",$cpu);
      run($ENV{CXX}||'c++','-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,"$stem.cpp",$obj,'-o',"$stem.cpu");
      if($sequence) {
         # Freeze the preset fixture's existing266-line raw harness period.
         run("$stem.cpu","$stem.bin",600,'--no-audio','--raw-lines','266','--require-safe-visible-boundaries');
         if($kind eq 'above') {
            # Prove this oracle rejects the historical ten-cycle-late caller.
            my$bad=read_file($source);
            $bad=~s/(   COLUPF := VCS_NTSC_GOLDENROD;\n   CTRLPF := 0x21;\n)(   WSYNC := \$A;\n)/$2$1/
               or die 'missing handoff mutation site';
            save("$stem.late.c26",$bad);
            run("$repo/driver/vcsc",'-I',"$repo/libraries/vcs",'-DHEART_COMPOSITION_BELOW=0',
               "$stem.late.c26",'-o',"$stem.late.bin");
            eval { run("$stem.cpu","$stem.late.bin",100,'--report-visible-boundaries'); };
            $@=~/P1 restore phase .* expected/ or die "late-entry negative control did not fail correctly: $@";
         }
      }
      else {
         # RESET intentionally interrupts a frame. Check state and exact player
         # restoration phase on every VSYNC, retaining the safe visible edge.
         run("$stem.cpu","$stem.bin",$total+20,'--no-audio','--report-visible-boundaries','--require-safe-visible-boundaries');
      }
   }
}
print "vcs_heart_score_controls ok\n";
