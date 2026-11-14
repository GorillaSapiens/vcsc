#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 240
# expectstdout: vcs_layers_interactive ok
# expectexit: 0
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use IPC::Open3;
use POSIX qw(:sys_wait_h setpgid);
use Symbol qw(gensym);
my($repo,$tmp)=@ARGV; $repo=abs_path($repo); make_path($tmp); $tmp=abs_path($tmp);
require "$repo/test/stella_test_lib.pl";
sub slurp { open my$f,'<:raw',$_[0] or die$!; local$/; return <$f>; }
sub save { open my$f,'>:raw',$_[0] or die$!; print {$f} $_[1]; close$f or die$!; }
sub run {
   my$err=gensym; my$p=open3(my$i,my$o,$err,@_); close$i; local$/;
   my$s=<$o>//''; my$e=<$err>//''; waitpid($p,0); die "@_\n$s$e" if $?; return$s;
}
sub symbol {
   my($stem,$name)=@_; my$s=slurp("$stem.sym");
   $s=~/^\Q$name\E\s+([0-9a-fA-F]{4})\s*$/m or die "missing $name"; return hex$1;
}
sub findexe {
   my$n=shift; return abs_path($n) if -x$n;
   for(split/:/,$ENV{PATH}//'') { return abs_path("$_/$n") if -x"$_/$n"; }
   die "required executable: $n";
}
my%children;
sub stop {
   my$p=shift; return unless delete$children{$p}; kill 'TERM',-$p;
   for(1..20) { my$r=waitpid($p,WNOHANG); return if$r==$p||$r==-1; select undef,undef,undef,.05; }
   kill 'KILL',-$p; waitpid($p,0);
}
END { local$?; stop($_) for keys%children; }
sub spawn {
   my($log,@cmd)=@_; my$p=fork(); defined$p or die$!;
   if(!$p) { setpgid(0,0); open STDOUT,'>:raw',$log or die$!; open STDERR,'>&STDOUT' or die$!; exec@cmd; die$!; }
   eval { setpgid($p,$p) }; $children{$p}=1; return$p;
}
my$family='examples/04_renderers/cooperating_layers';
my@leaves=qw(no_score score_above score_below);
my$original=slurp("$repo/test/vcs_frame_timing.cpp");
my$mos="$repo/simulator/mos6502"; my$obj=-f"$mos/mos6502.o"?"$mos/mos6502.o":"$mos/mos6502.cpp";
# Each object traverses both seams and all four limits; holds must not repeat
# SELECT. Neutral periods, simultaneous directions and BCD carry/borrow are
# independent input scripts, not Stella's host-time startup hold switches.
my@steps=([4,255,255,128]);
for my$o(0..4) {
   push@steps,[3,255,253,128],[2,255,255,128] if$o;
   push@steps,[200,175,255,128],[200,95,255,128],[2,255,255,128];
}
push@steps,[3,255,253,128],[2,255,255,128],[5,15,255,128];
for my$digit(0..3) {
   my$presses=$digit%2?101:11;
   for(1..$presses) { push@steps,[2,254,255,128],[1,255,255,128]; }
   for(1..$presses) { push@steps,[2,253,255,128],[1,255,255,128]; }
   # One selection per press, not per held frame; roll to UP without neutral
   # must not edit the newly selected digit. Cycling four times wraps to zero.
   push@steps,[4,247,255,128],[2,254,255,128],[1,255,255,128];
}
push@steps,[4,251,255,128],[1,255,255,128]; # left wraps zero -> three
push@steps,[2,246,255,128],[1,255,255,128]; # diagonal selects before editing
push@steps,[2,240,255,128],[1,255,255,128]; # opposing directions: left/up
push@steps,[4,255,255,0],[2,255,255,128];   # fire has no effect
my$total=0; $total+=$_->[0] for@steps;
my$prefix=<<'CPP';
#include <algorithm>
struct TestInput { unsigned duration, joystick, switches, fire; };
static constexpr TestInput test_steps[]={ TEST_STEPS };
static unsigned test_frame=0;
static bool test_sync=false;
static TestInput test_input{0,255,255,128};
struct TestModel {
   unsigned x[5]={20,100,50,110,80}, y[5]={18,70,34,62,48};
   unsigned selected=0, select_ready=1, digit=0, joy_ready=15;
   unsigned score[2]={12,34};
};
static TestModel test_model;
static TestInput test_input_at(unsigned frame) {
   for(auto step:test_steps) { if(frame<step.duration) return step; frame-=step.duration; }
   if(frame==10) return {1,255,254,128}; // one RESET pulse, after the timed run
   return {1,255,255,128};
}
static void test_advance() {
   auto&m=test_model; const auto&i=test_input;
   if(!(i.switches&1)) { m=TestModel{}; return; }
   if(i.switches&2) m.select_ready=1;
   else if(m.select_ready) { m.selected=(m.selected+1)%5; m.select_ready=0; }
   auto&x=m.x[m.selected]; auto&y=m.y[m.selected];
   if(!(i.joystick&64)) { if(x) --x; }
   else if(!(i.joystick&128)) { if(x<MAX_X) ++x; }
   if(!(i.joystick&16)) { if(y) --y; }
   else if(!(i.joystick&32)) { if(y<MAX_Y) ++y; }
#if WITH_SCORE
   if(m.joy_ready) {
      if((i.joystick&15)!=15) {
         if(!(i.joystick&4)) m.digit=(m.digit+3)%4;
         else if(!(i.joystick&8)) m.digit=(m.digit+1)%4;
         const unsigned field=m.digit/2,weight=(m.digit%2)?1:10;
         if(!(i.joystick&1)) m.score[field]=(m.score[field]+weight)%100;
         else if(!(i.joystick&2)) m.score[field]=(m.score[field]+100-weight)%100;
         m.joy_ready=0;
      }
   } else if((i.joystick&15)==15) m.joy_ready=15;
#endif
}
CPP
$prefix=~s/TEST_STEPS/join(',',map{'{'.join(',',@$_).'}'}@steps)/e;
my$hook=<<'CPP';
      if(event.address==0) {
         const bool next=(event.value&2)!=0;
         if(next&&!test_sync) {
            const unsigned ys[]={Y0,Y1,YM0,YM1,YB};
            auto check=[](unsigned address,unsigned want) {
               if(peek_memory(address)!=want) {
                  std::fprintf(stderr,"interactive frame %u address $%04x got %u want %u\n",
                     test_frame,address,peek_memory(address),want); std::exit(1);
               }
            };
            auto word=[](unsigned a){return unsigned(peek_memory(a))+(unsigned(peek_memory(a+1))<<8);};
            for(unsigned n=0;n<5;++n) { check(XS+n,test_model.x[n]); check(ys[n],test_model.y[n]); }
            check(SELECTED,test_model.selected); check(SELECT_READY,test_model.select_ready);
            const unsigned pointers[]={G0,G1},graphics[]={P0,P1};
            for(unsigned n=0;n<2;++n) {
               const unsigned want=graphics[n]+((test_model.x[n]^test_model.y[n])&3)*8;
               if(word(pointers[n])!=want) { std::fprintf(stderr,"interactive animation pointer mismatch\n"); std::exit(1); }
            }
#if WITH_SCORE
            check(DIGIT,test_model.digit); check(JOY_READY,test_model.joy_ready);
            for(unsigned n=0;n<2;++n) check(n?S1:S0,(test_model.score[n]/10)*16+test_model.score[n]%10);
#endif
            test_input=test_input_at(test_frame++); test_advance();
         }
         test_sync=next;
      }
CPP
my@stems;
for my$mode(0..2) {
   my$leaf=$leaves[$mode]; my$stem="$tmp/$leaf"; push@stems,$stem;
   my$out=run("$repo/driver/vcsc",'-I',"$repo/libraries/vcs",'-Map',"$stem.map","$repo/$family/$leaf/interactive.c26",'-o',"$stem.bin");
   -s"$stem.bin"==4096 or die 'interactive example is not one 4K bank';
   my($rom)=$out=~/rom\s+used=(\d+) bytes/; my($ram)=$out=~/ram\s+used=(\d+) bytes/;
   defined($rom)&&$rom<=3840&&defined($ram)&&$ram<=64 or die 'interactive ROM/RAM budget';
   my%defines=(MAX_X=>($mode==1?119:159),MAX_Y=>($mode==0?95:$mode==1?85:87),WITH_SCORE=>($mode?1:0));
   my%names=(XS=>'layers_object_x',Y0=>'layers_player0_y',Y1=>'layers_player1_y',YM0=>'layers_missile0_y',YM1=>'layers_missile1_y',YB=>'layers_ball_y',
      SELECTED=>'controls_selected_object',SELECT_READY=>'controls_select_ready',G0=>'layers_player0_graphics',G1=>'layers_player1_graphics',P0=>'layers_p0_animation',P1=>'layers_p1_animation');
   %names=(%names,DIGIT=>'controls_selected_score_digit',JOY_READY=>'controls_joystick_ready',S0=>'score_left_score',S1=>'score_right_score') if$mode;
   $defines{$_}=symbol($stem,$names{$_}) for keys%names;
   my$cpu=join('',map{"#define $_ $defines{$_}\n"}sort keys%defines).$prefix.$original;
   $cpu=~s/(uint8_t read_bus\(uint16_t address\) \{)/$1\n   if(address==0x280) return test_input.joystick;\n   if(address==0x282) return test_input.switches;\n   if(address==0x3d) return test_input.fire;/ or die 'input hook';
   $cpu=~s/(   for \(const WriteEvent &event : writes\) \{)/$1\n$hook/ or die 'CPU hook';
   save("$stem.cpp",$cpu);
   run($ENV{CXX}||'c++','-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,"$stem.cpp",$obj,'-o',"$stem.cpu");
   run("$stem.cpu","$stem.bin",$total+5,'--no-audio','--raw-lines','264','--require-safe-visible-boundaries');
   # RESET intentionally restarts a frame. Keep the ordinary period assertion
   # above intact; separately verify rebooted state with boundary inspection.
   run("$stem.cpu","$stem.bin",$total+20,'--no-audio','--report-visible-boundaries','--require-safe-visible-boundaries');
}

# Native public-ROM smoke checks: no startup-held controls and no pinned art/RGB.
my$helpers=slurp("$repo/test/stella_png_sequence.pl");
$helpers=~s/\n\@ARGV>=2.*\z//s or die 'PNG helpers'; eval$helpers; die$@ if$@;
my(undef,$display)=vcsc_reserve_x_display(420,20);
my$xvfb=findexe($ENV{VCSC_XVFB}||$ENV{XVFB}||'Xvfb');
my$xp=spawn("$tmp/xvfb.log",$xvfb,$display,'-ac','-screen','0','1024x768x24');
vcsc_xvfb_assert_ready($display,$xp);
local$ENV{DISPLAY}=$display; local$ENV{XAUTHORITY}='/dev/null'; local$ENV{SDL_AUDIODRIVER}='dummy'; local$ENV{SDL_VIDEODRIVER}='x11';
my$stella=findexe($ENV{VCSC_STELLA}||$ENV{STELLA}||'stella');
for my$mode(0..2) {
   my$stem=$stems[$mode]; my$snap="$stem.snap"; my$user="$stem.user"; make_path($snap,$user);
   my$p=spawn("$stem.stella.log",vcsc_stella_capture_launcher($repo,$stella),vcsc_stella_palette_args($repo,$user),
      '-plr.bankrandom','0','-plr.ramrandom','0','-plr.tiarandom','0','-dev.bankrandom','0','-dev.ramrandom','0','-dev.cpurandom','0','-dev.tiarandom','0','-dev.hsrandom','0','-dev.tiadriven','0',
      '-video','software','-turbo','1','-audio.enabled','0','-bs','4K','--capture-frames','200-201','--capture-dir',$snap,
      '-exitlauncher','0','-confirmexit','0','-userdir',$user,"$stem.bin");
   my@png=vcsc_stella_wait_snapshots("$snap/*.png",2); stop($p); @png==2 or die 'missing interactive frames';
   my@images=map{[decode_rgb($_)]}@png;
   $images[0][0]==160&&$images[0][1]==228 or die 'unexpected native dimensions';
   $images[0][2] eq $images[1][2] or die 'idle interactive objects must not move automatically';
   my$rgb=$images[0][2]; my$blank=substr($rgb,0,3); my@runs; my$active=0;
   for my$y(0..227) {
      my$lit=substr($rgb,$y*480,480) ne $blank x160;
      if($lit) { if(!$active) { push@runs,0; } $runs[-1]++; } $active=$lit;
   }
   my$want=$mode==0?'192':$mode==1?'8,172':'176,8';
   join(',',@runs) eq $want or die "interactive $leaves[$mode] visible composition: @runs wanted $want";
}

# Installed entry points must have both shared app files and build independently.
run($^X,"$repo/packaging/install_manifest.pl",'install','--manifest',"$repo/packaging/install.manifest",'--scope','libraries','--source-root',$repo,'--dest-root',"$tmp/installed");
run($^X,"$repo/packaging/install_manifest.pl",'install','--manifest',"$repo/packaging/install.manifest",'--scope','examples','--source-root',$repo,'--dest-root',"$tmp/installed/examples");
for my$mode(0..2) {
   my$leaf=$leaves[$mode]; my$d="$tmp/installed/$family/$leaf";
   run('make','-C',$d,'interactive',"VCSC=$repo/driver/vcsc","VCS_DIR=$tmp/installed/libraries/vcs");
   slurp("$d/layers_${leaf}_interactive.bin") eq slurp("$stems[$mode].bin") or die 'installed interactive build differs';
   run('make','-C',$d,'clean'); !-e"$d/layers_${leaf}_interactive.bin" or die 'interactive clean left ROM';
}
print "vcs_layers_interactive ok\n";
