#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 240
# expectstdout: vcs_standard_renderer_banked_controls ok
# expectexit: 0
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use IPC::Open3;
use POSIX qw(:sys_wait_h setpgid);
use Symbol qw(gensym);
my($repo,$tmp)=@ARGV;$repo=abs_path($repo);make_path($tmp);$tmp=abs_path($tmp);
require "$repo/test/stella_test_lib.pl";
sub slurp {open my$f,'<:raw',$_[0] or die$!;local$/;return <$f>;}
sub save {open my$f,'>:raw',$_[0] or die$!;print {$f} $_[1];close$f or die$!;}
sub run {
   my$e=gensym;my$p=open3(my$i,my$o,$e,@_);close$i;local$/;
   my$s=<$o>//'';my$t=<$e>//'';waitpid($p,0);die"@_\n$s$t"if$?;return$s;
}
sub address {
   my($map,$name)=@_;$map=~/^\s*\$([0-9a-f]+)\s+\Q$name\E\b/im or die "missing $name";return hex$1;
}
sub findexe {
   my$n=shift;return abs_path($n)if-x$n;
   for(split/:/,$ENV{PATH}//''){return abs_path("$_/$n")if-x"$_/$n";}die"missing $n";
}
my$source="$repo/examples/07_diagnostics/bankswitching/standard_renderer/banked_standard_renderer.c26";
my$body=slurp($source);
my$initial=substr($body,rindex($body,'void initialize_banked_scene(void)'));
sub initial_value {
   my$n=shift;$initial=~/\b\Q$n\E\s*:=\s*(0x[0-9a-f]+|\d+)\s*;/i or die "missing initial $n";
   my$value=$1;return $value=~/^0x/i?hex($value):0+$value;
}

# Actual public ROMs receive frame-indexed bus input, never startup-held host
# input. Every object reaches all four limits; SELECT and score holds/rolls,
# carry/borrow, decimal wrap, opposing directions, fire and RESET are independent.
my@steps=([4,255,255,128]);
for my$o(0..4){
   push@steps,[3,255,253,128],[2,255,255,128]if$o;
   push@steps,[200,175,255,128],[200,95,255,128],[2,255,255,128];
}
push@steps,[3,255,253,128],[2,255,255,128],[5,15,255,128];
for my$digit(0..5){
   for(1..11){push@steps,[2,254,255,128],[1,255,255,128];}
   for(1..11){push@steps,[2,253,255,128],[1,255,255,128];}
   push@steps,[4,251,255,128],[2,254,255,128],[1,255,255,128];
}
push@steps,[3,247,255,128],[1,255,255,128], # right wraps ones -> hundred-thousands
   [2,250,255,128],[1,255,255,128],       # diagonal selects before increment
   [2,240,255,128],[1,255,255,128],       # opposite directions prefer left/up
   [2,254,255,128],[2,253,255,128],[1,255,255,128], # roll must not re-arm
   [4,255,255,0],[2,255,255,128],         # fire does not select/edit
   [1,255,254,128],[20,255,255,128];      # reset, then check restored state
my$total=5;$total+=$_->[0]for@steps;
my$prefix=<<'CPP';
#include <array>
#include <cstdint>
namespace {
struct TestInput {unsigned duration,joy,switches,fire;};
static constexpr TestInput test_steps[]={TEST_STEPS};
static TestInput test_input{0,255,255,128};
static std::array<bool,TEST_FRAMES> test_reset_period{};
static unsigned test_resets=0;
struct TestModel {
   unsigned x[5]={TEST_INITIAL_XS}, y[5]={TEST_INITIAL_YS};
   unsigned selected=0,select_ready=1,digit=0,joy_ready=15;
   unsigned score=TEST_INITIAL_SCORE,color=TEST_INITIAL_COLOR,count=0,epoch=0;
};
static TestModel test_model;
static TestInput test_input_at(unsigned frame) {
   for(auto step:test_steps){if(frame<step.duration)return step;frame-=step.duration;}
   return {1,255,255,128};
}
static void test_advance() {
   auto&m=test_model;const auto&i=test_input;
   if(!(i.switches&1)){m=TestModel{};return;}
   m.count=(m.count+1)&255;m.epoch=1;
   if(i.switches&2)m.select_ready=1;
   else if(m.select_ready){m.selected=(m.selected+1)%5;m.select_ready=0;}
   auto&x=m.x[m.selected];auto&y=m.y[m.selected];
   if(!(i.joy&64)){if(x)--x;}else if(!(i.joy&128)){if(x<159)++x;}
   if(!(i.joy&16)){if(y)--y;}else if(!(i.joy&32)){if(y<87)++y;}
   if(m.joy_ready){
      if((i.joy&15)!=15){
         if(!(i.joy&4)){m.digit=(m.digit+1)%6;m.color=(m.color+16)&255;}
         else if(!(i.joy&8)){m.digit=(m.digit+5)%6;m.color=(m.color+16)&255;}
         unsigned weight=1;for(unsigned n=0;n<m.digit;++n)weight*=10;
         if(!(i.joy&1))m.score=(m.score+weight)%1000000;
         else if(!(i.joy&2))m.score=(m.score+1000000-weight)%1000000;
         m.joy_ready=0;
      }
   }else if((i.joy&15)==15)m.joy_ready=15;
}
}
CPP
$prefix=~s/TEST_STEPS/join(',',map{'{'.join(',',@$_).'}'}@steps)/e;
$prefix=~s/TEST_FRAMES/$total/g;
# These are editable scene inputs, not expectations copied from the controller.
# The independent transition model and limits above remain fixed.
$prefix=~s/TEST_INITIAL_XS/join(',',map{initial_value("VCS_STANDARD_${_}_X")}qw(PLAYER0 PLAYER1 MISSILE0 MISSILE1 BALL))/e;
$prefix=~s/TEST_INITIAL_YS/join(',',map{initial_value("vcs_standard_${_}_y")}qw(player0 player1 missile0 missile1 ball))/e;
$prefix=~s/TEST_INITIAL_SCORE/initial_value('vcs_standard_score')/e;
$prefix=~s/TEST_INITIAL_COLOR/initial_value('vcs_standard_score_color')/e;
my$verify=<<'CPP';
void verify_frame_boundary() {
   if(selected_file_bank!=bank_count-1)fail("interactive frame began outside startup bank");
   if(frame>0){
      if(!(test_input.switches&1)){test_reset_period[frame-1]=true;++test_resets;}
      test_advance();
   }
   auto check=[](unsigned a,unsigned expected){
      if(inspect_address(a)!=expected){
         std::fprintf(stderr,"interactive frame%d address$%04x got%u expected%u\n",frame,a,inspect_address(a),expected);
         std::exit(1);
      }
   };
   const unsigned ys[]={TEST_YS};
   for(unsigned n=0;n<5;++n){check(TEST_XS+n,test_model.x[n]);check(ys[n],test_model.y[n]);}
   check(TEST_SELECTED,test_model.selected);check(TEST_SELECT_READY,test_model.select_ready);
   check(TEST_DIGIT,test_model.digit);check(TEST_JOY_READY,test_model.joy_ready);
   check(TEST_COLOR,test_model.color);
   check(hook_count_address,test_model.count);check(hook_epoch_address,test_model.epoch);check(hook_failure_address,0);
   unsigned value=test_model.score;
   for(unsigned n=0;n<3;++n){const unsigned pair=value%100;value/=100;check(score_address+n,(pair/10)*16+pair%10);}
   test_input=test_input_at(frame);
}

CPP
my$vcs="$repo/libraries/vcs";my$renderer="$vcs/renderers/standard_4k_ntsc/standard_4k_ntsc_renderer.s26";
my$mos="$repo/simulator/mos6502";my$obj=-f"$mos/mos6502.o"?"$mos/mos6502.o":"$mos/mos6502.cpp";
my@spec=(['4K',['-DUNBANKED_REFERENCE'],4096],['F8',['-DMAPPER_BANKS=2'],8192],
   ['F6',['-DMAPPER_BANKS=4'],16384],['F4',['-DMAPPER_BANKS=8'],32768],
   ['F8SC',['-DMAPPER_BANKS=2','-DSUPERCHIP_TEST'],8192]);
my%built;my%trace;my%maps;my%runtime_args;
for my$spec(@spec){
   my($name,$defs,$bytes)=@$spec;my$stem="$tmp/$name";
   my$out=run("$repo/driver/vcsc",'-I',$vcs,@$defs,'-Map',"$stem.map",$source,$renderer,'-o',"$stem.bin");
   -s"$stem.bin"==$bytes or die "$name ROM size";
   my($ram)=$out=~/ram\s+used=(\d+) bytes/;defined($ram)&&$ram<=128 or die "$name stock RAM budget";
   my$map=slurp("$stem.map");$built{$name}="$stem.bin";$maps{$name}=$map;
   if($name ne'4K'){
      $map=~/CODE\.bank1\.__vcsc_function\$banked_game_logic .*bank=bank1.*placement=pinned/ or die 'gameplay escaped bank1';
      $map=~/RODATA\.bank1\.__vcsc_object\$score_digit_weight .*bank=bank1.*placement=pinned/ or die 'gameplay table escaped bank1';
      $map=~/RENDERER_CODE .*bank=bank0.*component-region=\@startup/ or die 'renderer escaped startup bank';
   }
   my%names=(TEST_XS=>'vcs_standard_object_x',TEST_SELECTED=>'selected_object',TEST_SELECT_READY=>'select_switch_ready',
      TEST_DIGIT=>'selected_score_digit',TEST_JOY_READY=>'right_joystick_ready',TEST_COLOR=>'vcs_standard_score_color');
   my$hook=$verify;$hook=~s/\bTEST_YS\b/join(',',map{address($map,"vcs_standard_${_}_y")}qw(player0 player1 missile0 missile1 ball))/e;
   for my$key(keys%names){my$a=address($map,$names{$key});$hook=~s/\b\Q$key\E\b/$a/g;}
   my$cpu=slurp("$repo/test/vcs_standard_renderer_banked.cpp");
   $cpu=~s/constexpr int kFramesToRun = 8;/constexpr int kFramesToRun = $total;/ or die 'frame count';
   $cpu=~s/constexpr int kLastDigestFrame = 5;/constexpr int kLastDigestFrame = @{[$total-1]};/ or die 'whole-script visible trace';
   $cpu=~s/constexpr uint64_t kInstructionLimit = 20000000;/constexpr uint64_t kInstructionLimit = uint64_t(kFramesToRun)*20000;/ or die 'instruction bound';
   $cpu=~s/void verify_frame_boundary\(\) \{.*?(?=void apply_write\()/$hook/s or die 'controller hook';
   $cpu=~s/(uint8_t read_bus\(uint16_t address\) \{)/$1\n   if(canonical(address)==0x280)return test_input.joy;\n   if(canonical(address)==0x282)return test_input.switches;\n   if(canonical(address)==0x3c || canonical(address)==0x3d)return test_input.fire;/ or die 'bus input hook';
   # Real RIOT RAM is mirrored at stack addresses. Do not give the banked
   # controller a fictitious second128-byte stack storage area.
   $cpu=~s/return static_cast<uint16_t>\(address & 0x1FFFu\);/const uint16_t a=address\&0x1fff;\n   return a<0x1000 \&\& (a\&0x80) \&\& !(a\&0x200) ? 0x80+(a\&0x7f) : a;/ or die 'RIOT mirror';
   $cpu=~s/(if \(frame_periods\[i\] != kExpectedFrameCycles\) \{)/if(test_reset_period[i])continue;\n      $1/ or die 'scripted reset period';
   $cpu=~s/(if \(inspect_address\(signature_address\) != 0x5A\))/if(test_resets!=1)fail("missing scripted RESET");\n   $1/ or die 'reset coverage';
   save("$stem.cpp",$prefix.$cpu);
   run($ENV{CXX}||'c++','-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,"$stem.cpp",$obj,'-o',"$stem.cpu");
   my@args=map{address($map,$_)}qw(banked_hook_count banked_hook_epoch banked_hook_failure);
   push@args,address($map,'vcs_standard_object_x')+4,address($map,'vcs_standard_score'),address($map,'banked_hook_signature');
   $runtime_args{$name}=\@args;
   my$result=run("$stem.cpu","$stem.bin",$name,@args);
   $result=~/raster=([0-9a-f]+) events=(\d+)/ or die 'missing visible trace';$trace{$name}="$1/$2";
   $trace{$name}eq$trace{'4K'} or die "$name interactive visible trace differs from4K";
}

# Prove the public controller oracle rejects an accidentally reintroduced X119
# clamp; never hide it behind a matching banked/unbanked trace or static raster.
my$bad=slurp($source);
$bad=~s/(vcs_standard_object_x\[selected_object\] < )159/${1}119/ or die 'clamp mutation site';
save("$tmp/clamped.c26",$bad);
run("$repo/driver/vcsc",'-I',$vcs,'-DMAPPER_BANKS=2','-Map',"$tmp/clamped.map","$tmp/clamped.c26",$renderer,'-o',"$tmp/clamped.bin");
my$bad_map=slurp("$tmp/clamped.map");
for my$n(qw(vcs_standard_object_x vcs_standard_player0_y vcs_standard_player1_y vcs_standard_missile0_y
   vcs_standard_missile1_y vcs_standard_ball_y selected_object select_switch_ready selected_score_digit
   right_joystick_ready vcs_standard_score vcs_standard_score_color banked_hook_count banked_hook_epoch banked_hook_failure)){
   address($bad_map,$n)==address($maps{'F8'},$n)or die 'clamp mutation changed state layout';
}
eval{run("$tmp/F8.cpu","$tmp/clamped.bin",'F8',@{$runtime_args{'F8'}});1}
   and die 'X119 clamp was accepted';
$@=~/interactive frame\d+ address\$[0-9a-f]+ got119 expected120/ or die "clamp rejected for wrong reason: $@";

# Actual public binaries: released-input native frames agree with the unbanked
# rendering witness. Behavioral input coverage above executes these same ROMs.
my$stella=findexe($ENV{VCSC_STELLA}||$ENV{STELLA}||'stella');my$xvfb=findexe($ENV{VCSC_XVFB}||$ENV{XVFB}||'Xvfb');
my(undef,$display)=vcsc_reserve_x_display(890,30);my$xp=fork();defined$xp or die$!;
if(!$xp){setpgid(0,0);open STDOUT,'>',"$tmp/xvfb.log"or die$!;open STDERR,'>&STDOUT';exec$xvfb,$display,'-ac','-screen','0','1024x768x24';die$!;}
eval{setpgid($xp,$xp)};
END {
   local$?;
   if($xp){
      kill'TERM',-$xp;my$done=0;
      for(1..20){my$r=waitpid($xp,WNOHANG);if($r==$xp||$r==-1){$done=1;last;}select undef,undef,undef,.05;}
      if(!$done){kill'KILL',-$xp;waitpid($xp,0);}
   }
}
vcsc_xvfb_assert_ready($display,$xp);
local$ENV{DISPLAY}=$display;local$ENV{SDL_VIDEODRIVER}='x11';local$ENV{SDL_AUDIODRIVER}='dummy';
my%png;
for my$name(qw(4K F8 F8SC)){
   my$dir="$tmp/native_$name";make_path($dir,"$dir/user");
   run(vcsc_stella_capture_launcher($repo,$stella),vcsc_stella_palette_args($repo,"$dir/user"),
      '-plr.bankrandom','0','-plr.ramrandom','0','-plr.tiarandom','0',
      '-dev.bankrandom','0','-dev.ramrandom','0','-dev.cpurandom','0','-dev.tiarandom','0',
      '-dev.hsrandom','0','-dev.tiadriven','0','-video','software','-turbo','1','-audio.enabled','0',
      '-bs',$name,'-exitlauncher','0','-confirmexit','0','-userdir',"$dir/user",
      '--capture-frames','200,201','--capture-dir',$dir,$built{$name});
   for my$frame(200,201){
      $png{"$name/$frame"}=run($^X,"$repo/test/stella_png_rgb_digest.pl",'--stella-raster',sprintf("$dir/frame_%08d.png",$frame));
      $png{"$name/$frame"}eq$png{"4K/$frame"}or die "$name native frame$frame differs from4K";
   }
}
print "vcs_standard_renderer_banked_controls ok\n";
