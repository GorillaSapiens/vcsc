#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 240
# expectstdout: vcs_layers_sections ok
# expectexit: 0
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use IPC::Open3;
use POSIX qw(:sys_wait_h setpgid);
use Symbol qw(gensym);
my($repo,$tmp)=@ARGV;
$repo=abs_path($repo);make_path($tmp);$tmp=abs_path($tmp);
require "$repo/test/stella_test_lib.pl";
my%children;
sub stop {
   my($p)=@_;return unless delete$children{$p};kill 'TERM',-$p;
   for(1..20){my$r=waitpid($p,WNOHANG);return if$r==$p||$r==-1;select undef,undef,undef,.05;}
   kill 'KILL',-$p;waitpid($p,0);
}
END { local$?;stop($_) for keys%children; }
sub spawn {
   my($log,@cmd)=@_;my$p=fork();defined$p or die "fork: $!";
   if(!$p){setpgid(0,0);open STDOUT,'>:raw',$log or die$!;open STDERR,'>&STDOUT' or die$!;exec@cmd;die$!;}
   eval{setpgid($p,$p)};$children{$p}=1;return$p;
}
sub run {
   my(@cmd)=@_;my$err=gensym;my$p=open3(my$i,my$o,$err,@cmd);close$i;
   local$/;my$out=<$o>//'';my$e=<$err>//'';waitpid($p,0);
   $?==0 or die "@cmd\n$out$e";return$out;
}
sub slurp {open my$f,'<:raw',$_[0] or die$!;local$/;return <$f>;}
sub save {open my$f,'>:raw',$_[0] or die$!;print $f $_[1];}
sub findexe {
   my($n)=@_;return abs_path($n) if -x$n;
   for(split /:/,$ENV{PATH}//''){return abs_path("$_/$n") if -x"$_/$n";}
   die "required executable: $n";
}
my$helpers=slurp("$repo/test/stella_png_sequence.pl");
$helpers=~s/\n\@ARGV>=2.*\z//s or die 'PNG helper boundary';eval$helpers;die$@ if$@;
my$stella=findexe($ENV{VCSC_STELLA}||$ENV{STELLA}||'stella');
my$xvfb=findexe($ENV{VCSC_XVFB}||$ENV{XVFB}||'Xvfb');
my(undef,$display)=vcsc_reserve_x_display(290,20);
my$xp=spawn("$tmp/xvfb.log",$xvfb,$display,'-ac','-screen','0','1024x768x24');
vcsc_xvfb_assert_ready($display,$xp);
local$ENV{DISPLAY}=$display;local$ENV{XAUTHORITY}='/dev/null';local$ENV{SDL_AUDIODRIVER}='dummy';
sub capture {
   my($name)=@_;my$snap="$tmp/snap_$name";my$user="$tmp/user_$name";make_path($snap,$user);
   my$p=spawn("$tmp/stella_$name.log",$stella,vcsc_stella_palette_args($repo,$user),
      '-plr.bankrandom','0','-plr.ramrandom','0','-plr.tiarandom','0',
      '-dev.bankrandom','0','-dev.ramrandom','0','-dev.cpurandom','0','-dev.tiarandom','0',
      '-dev.hsrandom','0','-dev.tiadriven','0','-video','software','-turbo','1',
      '-audio.enabled','0','-bs','4K','-framesnap','200','-snapsavedir',$snap,
      '-snapname','rom','-sssingle','1','-ss1x','1','-exitlauncher','0','-confirmexit','0',
      '-userdir',$user,"$tmp/$name.bin");
   my@png=vcsc_stella_wait_snapshots("$snap/*.png",1);stop($p);
   @png==1 or die "$name missing snapshot";return [decode_rgb($png[0])];
}
sub build {
   my($name,$src)=@_;save("$tmp/$name.c26",$src);
   return run("$repo/driver/vcsc",'-I',"$repo/libraries/vcs","$tmp/$name.c26",'-o',"$tmp/$name.bin");
}
my@scene=([6,'0x81244596','0x46','0xc2'],[186,'0x3c96a569','0x8e','0x26']);
my$timing=slurp("$repo/test/vcs_frame_timing.cpp");
my$hook=<<'CPP';
      static bool section_visible = false;
      static unsigned section_writes = 0;
      if (!(event.address & 0x1080)) {
         const unsigned reg = event.address & 63;
         if (reg == 1) {
            if ((event.value & 2) && section_visible && section_writes != 768) {
               std::fprintf(stderr,"section PF count %u != 768\n",section_writes); std::exit(1);
            }
            section_visible = !(event.value & 2);
            if (section_visible) section_writes = 0;
         } else if (section_visible && (reg == 14 || reg == 15)) {
            static const unsigned regs[] = {14,15,15,14};
            static const unsigned phases[] = {20,25,48,53};
            const unsigned slot = section_writes++ % 4;
            if (reg != regs[slot] || virtual_cycles % 76 != phases[slot]) {
               std::fprintf(stderr,"section PF phase: slot=%u reg=%u phase=%llu\n",slot,reg,(unsigned long long)(virtual_cycles%76));
               std::exit(1);
            }
         }
      }
CPP
$timing=~s/(   for \(const WriteEvent &event : writes\) \{)/$1\n$hook/ or die 'timing hook';
save("$tmp/section_timing.cpp",$timing);
my$mos="$repo/simulator/mos6502";my$obj=-f"$mos/mos6502.o"?"$mos/mos6502.o":"$mos/mos6502.cpp";
run($ENV{CXX}||'c++','-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,"$tmp/section_timing.cpp",$obj,'-o',"$tmp/timing");
my$gold_template=slurp("$repo/test/fixtures/all_five_player_color_192/all_five_match.c26");
my@gold;
for my$i(0..1){
   my(undef,$row,$pf,$bk)=@{$scene[$i]};my$s=$gold_template;
   $s="include \"playfield.c26\"\n".$s;
   $s=~s/(game_playfield\[48\] := \{).*?\};/$1.join(',',("VCS_PLAYFIELD_ROW($row)")x12)."};"/se or die 'gold PF';
   $s=~s/(COLUBK := )0x84;/$1$bk;/ or die 'gold BK';
   $s=~s/(COLUPF := )0x2e;/$1$pf;/ or die 'gold PF colour';
   $s=~s/(game_(?:player[01]|missile[01]|ball)_y := )\d+;/${1}250;/g;
   build("gold_$i",$s);push@gold,capture("gold_$i");
}
sub source {
   my($heights)=@_;my$s=slurp("$repo/test/fixtures/layers/sections.c26");
   for my$i(0..1){my$n=$i+1;
      $s=~s/(as section$n \(number_of_scanlines:=)\d+/$1$heights->[$i]/ or die 'height parameter';
   }
   return$s;
}
for my$height(2,6,190){
   my$name="sections_$height";my$build=build($name,source([$height,192-$height]));
   $build=~/ram\s+used=(\d+) bytes/&&$1==9 or die 'sections must add no RAM to intro/app';
   run("$tmp/timing","$tmp/$name.bin",'420','--no-audio','--released-inputs','--raw-lines','264');
   my($w,$h,$rgb)=@{capture($name)};
   $w==$gold[0][0]&&$h==$gold[0][1] or die 'raster dimensions';
   my%count;$count{substr($gold[0][2],($_*$w+20)*3,3)}++ for 0..$h-1;
   my($bg)=sort{$count{$b}<=>$count{$a}}keys%count;
   my@visible=grep{substr($gold[0][2],($_*$w+20)*3,3)eq$bg}0..$h-1;
   @visible==192 or die 'independent visible extent';my$first=$visible[0];
   my@row;
   for my$i(0..1){
      # Take palette RGB from a certified ordinary row, then independently
      # expand the VISUAL bitmap. Do not inherit the ancestor's terminal PF
      # write schedule (which clobbers a left-half bit for these distinct rows).
      my$reference=substr($gold[$i][2],($first+40)*$w*3,$w*3);
      my$bits=sprintf('%032b',hex($scene[$i][1]));my$lit=index($bits,'1');
      my$bg=substr($reference,20*3,3);my$fg=substr($reference,(32+$lit*8)*3,3);
      $fg ne$bg or die 'palette witness has no contrast';
      my$expected=$bg x32; $expected.=($_ eq'1'?$fg:$bg)x8 for split//,$bits;
      $expected.=$bg x32;
      $reference eq$expected or die 'independent PF bitmap witness';
      push@row,$expected;
   }
   for my$y(0..$h-1){
      my$which=$y>=$first+$height?1:0;
      my$want=$y>=$first&&$y<$first+192?$row[$which]:substr($gold[0][2],$y*$w*3,$w*3);
      my$got=substr($rgb,$y*$w*3,$w*3);
      $got eq$want or die "section seam/row mismatch: height=$height y=$y";
   }
}
for my$height(0,1,3,255,256,-2){
   eval{build("bad_height_$height",source([$height,2]));1} and die "invalid height $height accepted";
}
for my$pair(['pf_color:=0x46','pf_color:=256'],['bk_color:=0xc2','bk_color:=-1']){
   my$s=source([6,186]);$s=~s/\Q$pair->[0]\E/$pair->[1]/ or die 'colour mutation';
   eval{build('bad_colour',$s);1} and die 'invalid colour accepted';
}
build('hex_height',source(['0xfe',2]));
{
   my$s=source([96,2]);
   $s=~s/^instantiate "layers\/section.c26" as section2 .*\n//m or die 'remove repeat section';
   $s=~s/section2_draw\(\)/section1_draw()/ or die 'repeat instance call';
   build('repeat_instance',$s);
   run("$tmp/timing","$tmp/repeat_instance.bin",'420','--no-audio','--released-inputs','--raw-lines','264');
}
{
   my$s=source([2,6]);
   $s=~s/void main\(void\)/instantiate "layers\/section.c26" as section3 (number_of_scanlines:=184, playfield_row:=0x18244281, pf_color:=0x6e, bk_color:=0x84)\nvoid main(void)/ or die 'third instance';
   $s=~s/section2_draw\(\);/section2_draw(); section3_draw();/ or die 'third call';
   build('three_instances',$s);
   run("$tmp/timing","$tmp/three_instances.bin",'420','--no-audio','--released-inputs','--raw-lines','264');
}
{
   my$bad=slurp("$repo/libraries/vcs/layers/section.c26");
   $bad=~s/   asm nop;\n// or die 'phase mutation';save("$tmp/bad_phase_component.c26",$bad);
   my$s=source([6,186]);$s=~s!layers/section.c26!$tmp/bad_phase_component.c26!g;
   build('bad_phase',$s);
   eval{run("$tmp/timing","$tmp/bad_phase.bin",'200','--no-audio','--released-inputs','--raw-lines','264');1}
      and die 'wrong PF phase accepted';
   $@=~/section PF phase/ or die 'phase mutant failed for the wrong reason';
}
{
   my$s=source([6,186]);$s=~s/playfield_row:=0x[0-9a-f]+/playfield_row:=0xffffffff/gi;
   build('uniform',$s);
   run("$tmp/timing","$tmp/uniform.bin",'420','--no-audio','--released-inputs','--raw-lines','264');
}
{
   # Transparency only, NOT vertical object advancement: keep all five TIA
   # objects enabled across two differently coloured sections. Compare against
   # independently captured full-height flat fields, and prove each object is
   # actually lit so equality of empty frames cannot satisfy this check.
   my$hold=<<'C26';
      VDELP0 := 0; VDELP1 := 0; VDELBL := 0;
      COLUP0 := 0x0e; COLUP1 := 0xee;
      GRP0 := 0xff; GRP1 := 0xff;
      ENAM0 := 2; ENAM1 := 2; ENABL := 2;
C26
   my@flat;
   for my$i(0..1){
      my$s=source([192,2]);$s=~s/playfield_row:=0x[0-9a-f]+/playfield_row:=0/gi;
      $s=~s/^instantiate "layers\/section.c26" as section2 .*\n//m or die 'remove unused flat section';
      $s=~s/section1_draw\(\); section2_draw\(\);/section1_draw();/ or die 'flat composition';
      $s=~s/intro_establish\(\);/intro_establish();\n$hold/ or die 'held objects';
      if($i){$s=~s/pf_color:=0x46/pf_color:=0x8e/;$s=~s/bk_color:=0xc2/bk_color:=0x26/;}
      build("held_flat_$i",$s);push@flat,capture("held_flat_$i");
   }
   my$s=source([6,186]);$s=~s/playfield_row:=0x[0-9a-f]+/playfield_row:=0/gi;
   $s=~s/intro_establish\(\);/intro_establish();\n$hold/ or die 'held seam';
   build('held_sections',$s);my($w,$h,$rgb)=@{capture('held_sections')};
   my%count;$count{substr($flat[0][2],($_*$w+20)*3,3)}++ for 0..$h-1;
   my($bg)=sort{$count{$b}<=>$count{$a}}keys%count;
   my@visible=grep{substr($flat[0][2],($_*$w+20)*3,3)eq$bg}0..$h-1;
   @visible==192 or die 'held field extent';my$first=$visible[0];
   for my$y(0..$h-1){
      my$i=$y>=$first+6&&$y<$first+192?1:0;
      substr($rgb,$y*$w*3,$w*3) eq substr($flat[$i][2],$y*$w*3,$w*3)
         or die "held-object seam mismatch: y=$y";
   }
   for my$x(20,130,50,110,80){
      my$lit=0;
      for my$p($x*2-8..$x*2+24){$lit++ if substr($rgb,(($first+40)*$w+$p)*3,3)ne substr($flat[1][2],(($first+40)*$w+20)*3,3);}
      $lit or die "object at X=$x not witnessed";
   }
}
print "vcs_layers_sections ok\n";
