#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 240
# expectstdout: vcs_layers_all_five ok
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
sub save {open my$f,'>:raw',$_[0] or die$!;print $f $_[1];}
sub run {
   my$e=gensym;my$p=open3(my$i,my$o,$e,@_);close$i;local$/;
   my$s=<$o>//'';my$t=<$e>//'';waitpid($p,0);die"@_\n$s$t"if$?;return$s;
}
my%children;
sub stop {
   my$p=shift;return unless delete$children{$p};kill 'TERM',-$p;
   for(1..20){my$r=waitpid($p,WNOHANG);return if$r==$p||$r==-1;select undef,undef,undef,.05;}
   kill 'KILL',-$p;waitpid($p,0);
}
END {local$?;stop($_)for keys%children;}
sub spawn {
   my($log,@cmd)=@_;my$p=fork();die$!unless defined$p;
   if(!$p){setpgid(0,0);open STDOUT,'>:raw',$log or die$!;open STDERR,'>&STDOUT' or die$!;exec@cmd;die$!;}
   eval{setpgid($p,$p)};$children{$p}=1;return$p;
}
sub findexe {
   my$n=shift;return abs_path($n)if-x$n;
   for(split/:/,$ENV{PATH}//''){return abs_path("$_/$n")if-x"$_/$n";}
   die"required executable $n";
}
my$helpers=slurp("$repo/test/stella_png_sequence.pl");
$helpers=~s/\n\@ARGV>=2.*\z//s or die 'PNG helper boundary';eval$helpers;die$@if$@;
my$timing=slurp("$repo/test/vcs_frame_timing.cpp");
my$hook=<<'CPP';
      static bool layers_visible = false;
      static unsigned layers_pf = 0;
      static uint64_t layers_start = 0;
      if (!(event.address & 0x1080)) {
         const unsigned reg = event.address & 63;
         if (reg == 1) {
            if ((event.value & 2) && layers_visible) {
               if (layers_pf != 768 || virtual_cycles-layers_start != 192*76+2) {
                  std::fprintf(stderr,"layers visible extent/count mismatch: %u %llu\n",layers_pf,(unsigned long long)(virtual_cycles-layers_start)); std::exit(1);
               }
            }
            layers_visible = !(event.value & 2);
            if (layers_visible) { layers_pf=0; layers_start=virtual_cycles; }
         } else if (layers_visible && (reg == 14 || reg == 15)) {
            static const unsigned regs[] = {14,15,15,14};
            static const unsigned even[] = {3,32,48,53};
            static const unsigned odd[] = {18,23,48,53};
            const unsigned line = layers_pf/4, slot=layers_pf++%4;
            unsigned phase = (line&1)?odd[slot]:even[slot];
            if (!line && !slot) phase=8;
            if (reg != regs[slot] || virtual_cycles%76 != phase) {
               std::fprintf(stderr,"layers PF phase mismatch: line=%u slot=%u reg=%u phase=%llu expected=%u\n",line,slot,reg,(unsigned long long)(virtual_cycles%76),phase); std::exit(1);
            }
         } else if (layers_visible && reg >= 27 && reg <= 31) {
            static const unsigned phases[] = {72,2,12,13,60};
            if (virtual_cycles%76 != phases[reg-27]) {
               std::fprintf(stderr,"layers object phase mismatch: reg=%u phase=%llu\n",reg,(unsigned long long)(virtual_cycles%76)); std::exit(1);
            }
         }
      }
CPP
$timing=~s/(   for \(const WriteEvent &event : writes\) \{)/$1\n$hook/ or die 'timing hook';
save("$tmp/timing.cpp",$timing);
my$mos="$repo/simulator/mos6502";my$obj=-f"$mos/mos6502.o"?"$mos/mos6502.o":"$mos/mos6502.cpp";
run($ENV{CXX}||'c++','-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,"$tmp/timing.cpp",$obj,'-o',"$tmp/timing");
run($ENV{CXX}||'c++','-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,"$repo/test/vcs_frame_timing.cpp",$obj,'-o',"$tmp/plain_timing");
my$stella=findexe($ENV{VCSC_STELLA}||$ENV{STELLA}||'stella');
my$xvfb=findexe($ENV{VCSC_XVFB}||$ENV{XVFB}||'Xvfb');
my(undef,$display)=vcsc_reserve_x_display(310,20);
my$xp=spawn("$tmp/x.log",$xvfb,$display,'-ac','-screen','0','1024x768x24');vcsc_xvfb_assert_ready($display,$xp);
local$ENV{DISPLAY}=$display;local$ENV{XAUTHORITY}='/dev/null';local$ENV{SDL_AUDIODRIVER}='dummy';
sub build {
   my($n,$src)=@_;save("$tmp/$n.c26",$src);
   return run("$repo/driver/vcsc",'-I',"$repo/libraries/vcs","$tmp/$n.c26",'-o',"$tmp/$n.bin");
}
sub capture {
   my($n,$count)=@_;$count//=1;
   my$d="$tmp/snap_$n";my$u="$tmp/user_$n";make_path($d,$u);
   my$p=spawn("$tmp/$n.log",$stella,vcsc_stella_palette_args($repo,$u),
      '-plr.bankrandom','0','-plr.ramrandom','0','-plr.tiarandom','0',
      '-dev.bankrandom','0','-dev.ramrandom','0','-dev.cpurandom','0','-dev.tiarandom','0',
      '-dev.hsrandom','0','-dev.tiadriven','0','-video','software','-turbo','1',
      '-audio.enabled','0','-bs','4K','-framesnap',($count==1?'200':'200-239'),'-snapsavedir',$d,
      '-snapname','rom','-sssingle','1','-ss1x','1','-exitlauncher','0','-confirmexit','0','-userdir',$u,"$tmp/$n.bin");
   my@png=vcsc_stella_wait_snapshots("$d/*.png",$count);stop($p);
   @png>=$count or die "$n missing snapshots";return[map{[decode_rgb($_)]}@png];
}
sub address {
   my($name,$symbol)=@_;my$s=slurp("$tmp/$name.sym");
   $s=~/^\Q$symbol\E\s+([0-9a-fA-F]{4})\s*$/m or die"missing $symbol";return hex$1;
}
my$fixture=slurp("$repo/test/fixtures/layers/all_five_sections.c26");
my@objects=qw(player0 player1 missile0 missile1 ball);
my@cases=(
   {seam=>6,ys=>[9,9,5,5,4],hs=>[7,7,5,7,3]},
   {seam=>2,ys=>[7,7,2,2,2],hs=>[7,7,5,7,3]},
   {seam=>190,ys=>[99,99,95,95,94],hs=>[7,7,5,7,3]},
   {seam=>6,ys=>[5,4,5,5,4],hs=>[3,1,5,7,3],frames=>[1,2],nusiz=>[0x10,0x30],ball_width=>2},
);
sub source {
   my($case)=@_;my$s=$fixture;
   $s=~s/number_of_scanlines:=6,/number_of_scanlines:=$case->{seam},/ or die 'first height';
   my$rest=192-$case->{seam};$s=~s/number_of_scanlines:=186,/number_of_scanlines:=$rest,/ or die 'second height';
   for my$i(0..4){
      $s=~s/(layers_$objects[$i]_y:=)\d+;/$1$case->{ys}[$i];/ or die 'pose';
      $s=~s/(layers_$objects[$i]_height:=)\d+;/$1$case->{hs}[$i];/ or die 'height';
   }
   if($case->{frames}){for my$p(0..1){my$off=$case->{frames}[$p]*8;
      $s=~s/layers_player${p}_graphics:=p$p;/asm lda #<{p$p + $off}; asm sta.z layers_player${p}_graphics; asm lda #>{p$p + $off}; asm sta.z layers_player${p}_graphics + 1;/ or die 'frame pointer';
   }}
   if($case->{nusiz}){for my$p(0..1){$s=~s/layers_player${p}_nusiz:=0x20;/layers_player${p}_nusiz:=$case->{nusiz}[$p];/ or die 'runtime width';}}
   if($case->{ball_width}){$s=~s/CTRLPF:=0x21;/CTRLPF:=0x11;/ or die 'Ball width';}
   return$s;
}
sub masks {
   my($c)=@_;my@result;
   for my$t(1..96){my$b=0;
      for my$o(2..4){my$last=($c->{ys}[$o]+($o==4?2:1))&255;my$first=($last-$c->{hs}[$o])&255;
         my$on=$first<=$last?($t>=$first&&$t<=$last):($t>=$first||$t<=$last);
         $b|=(4,8,2)[$o-2] if$on;
      }push@result,$b;
   }return@result;
}
sub timing {
   my($n,$c)=@_;my@expect;my$a=address($n,'layers_object_masks');my@m=masks($c);
   push@expect,'--expect-memory',$a+$_,$m[$_]for 0..95;
   for my$p(0..1){push@expect,'--expect-memory',address($n,"layers_player${p}_counter"),($c->{ys}[$p]+$p-97)&255;}
   for my$p(0..1){
      my$frame=$c->{frames}?$c->{frames}[$p]:0;my$ptr=address($n,"p$p")+$frame*8;my$a=address($n,"layers_player${p}_graphics");
      push@expect,'--expect-memory',$a,$ptr&255,'--expect-memory',$a+1,$ptr>>8,
         '--expect-memory',address($n,"layers_player${p}_nusiz"),$c->{nusiz}?$c->{nusiz}[$p]:0x20;
   }
   for my$i(0..4){push@expect,'--expect-memory',address($n,"layers_$objects[$i]_y"),$c->{ys}[$i],'--expect-memory',address($n,"layers_$objects[$i]_height"),$c->{hs}[$i];}
   run("$tmp/timing","$tmp/$n.bin",'420','--no-audio','--released-inputs','--raw-lines','264',@expect);
}

# Independent palette RGB witness, not candidate/scenery timing. Twelve unique
# background stripes provide the emulator's exact colour conversion.
my@codes=(14,46,78,110,142,174,206,238,0x46,0xc2,0x8e,0x26);
my$cal="include \"vcs.c26\"\ninclude \"frame_ntsc.c26\"\nvoid main(void){VBLANK:=2;while(1){vcs_ntsc_vsync();vcs_ntsc_begin_vblank();vcs_ntsc_end_vblank();\n";
$cal.="COLUBK:=$_; vcs_ntsc_wait_scanlines(16);\n"for@codes;
$cal.="vcs_ntsc_begin_overscan();vcs_ntsc_end_overscan();}}\n";
build('palette',$cal);my$calrgb=capture('palette')->[0];my$w=$calrgb->[0];
my@runs;my$last='';for my$y(0..$calrgb->[1]-1){my$c=substr($calrgb->[2],($y*$w+160)*3,3);if($c ne$last){push@runs,[$y,$c];$last=$c;}}
my@lit=grep{$_->[1]ne"\0\0\0"}@runs;@lit==12 or die 'palette stripe count';
my%rgb;$rgb{$codes[$_]}=$lit[$_][1]for 0..$#codes;
my@graphics=(
   [[0,0x66,0x66,0x66,0x7e,0x66,0x66,0x3c],[0,0x18,0x18,0x18,0x18,0x7e,0x3c,0x18],
    [0,0x66,0x66,0x66,0x7e,0x66,0x66,0x66],[0,0x3c,0x66,0x66,0x66,0x66,0x66,0x3c]],
   [[0,0x7c,0x66,0x66,0x7c,0x66,0x66,0x7c],[0,0x3c,0x66,0x60,0x60,0x60,0x66,0x3c],
    [0,0x78,0x6c,0x66,0x66,0x66,0x6c,0x78],[0,0x7e,0x60,0x60,0x7c,0x60,0x60,0x7e]]);
my@colors=([14,46,78,110,142,174,206,238],[238,206,174,142,110,78,46,14]);
sub logical_image {
   my($image,$c,$first,$witness)=@_;my($width,$height,$actual)=@$image;
   $width==320 or die 'unexpected raster width';my@m=masks($c);my%seen;
   for my$line(0..191){
      my$scene=$line<$c->{seam}?0:1;my$bits=sprintf('%032b',$scene?0x3c96a569:0x81244596);
      my$bk=$rgb{$scene?0x26:0xc2};my$pf=$rgb{$scene?0x8e:0x46};
      my$want=$bk x32;$want.=($_ eq'1'?$pf:$bk)x8for split//,$bits;$want.=$bk x32;
      my$scenery=$want;my@row=($c->{ys}[0]-1-int($line/2),$line==0?$c->{ys}[1]:$c->{ys}[1]-1-int(($line-1)/2));
      for my$p(0..1){my$r=$row[$p];next if$r<0||$r>$c->{hs}[$p];my$frame=$c->{frames}?$c->{frames}[$p]:0;my$glyph=$graphics[$p][$frame][$r];
         for my$b(0..7){next unless$glyph&(128>>$b);substr($want,((($p?130:20)+$b)*2-2)*3,6)=$rgb{$colors[$p][$r]}x2;}
      }
      my$i0=int($line/2);my$i1=$line==0?0:int(($line-1)/2);
      my$mw0=$c->{nusiz}?(1<<(($c->{nusiz}[0]>>4)&3)):4;
      my$mw1=$c->{nusiz}?(1<<(($c->{nusiz}[1]>>4)&3)):4;
      my$bw=$c->{ball_width}//4;
      if($m[$i0]&4){my$r=$row[0];my$init=$c->{ys}[0]-1;my$color=$r>$c->{hs}[0]?$colors[0][$init<=$c->{hs}[0]?$init:0]:$colors[0][$r<0?0:$r];substr($want,96*3,$mw0*6)=$rgb{$color}x($mw0*2);}
      if($m[$i1]&8){my$r=$row[1];my$color=$r>$c->{hs}[1]?$colors[1][$c->{ys}[1]<=$c->{hs}[1]?$c->{ys}[1]:0]:$colors[1][$r<0?0:$r];substr($want,216*3,$mw1*6)=$rgb{$color}x($mw1*2);}
      if($m[$i1]&2){substr($want,156*3,$bw*6)=$pf x($bw*2);}
      my$got=substr($actual,($first+$line)*$width*3,$width*3);
      if($got ne$want){for my$x(0..$width-1){substr($got,$x*3,3)eq substr($want,$x*3,3)or die"logical RGB mismatch seam=$c->{seam} line=$line x=$x\n";}}
      if($witness&&$line>=$c->{seam}-2&&$line<=$c->{seam}+1){
         my$side=$line<$c->{seam}?0:1;
         for my$o(['P0',38,54],['P1',258,274],['M0',96,104],['M1',216,224],['BL',156,164]){
            my($name,$a,$b)=@$o;$seen{"$name/$side"}=1 if substr($got,$a*3,($b-$a)*3)ne substr($scenery,$a*3,($b-$a)*3);
         }
      }
   }
   if($witness){for my$n(qw(P0 P1 M0 M1 BL)){for my$s(0,1){$seen{"$n/$s"}or die"$n not visibly crossing seam $c->{seam} side$s";}}}
}
my$first;
for my$index(0..$#cases){my$c=$cases[$index];my$s=source($c);my$n="sections_$index";
   my$b=build($n,$s);$b=~/objects=122 bytes hardware-stack=4 bytes/ or die 'shared RAM/stack budget';timing($n,$c);
   my$image=capture($n)->[0];
   if(!defined$first){my@visible=grep{substr($image->[2],($_*$w+20)*3,3)eq$rgb{0xc2}}0..$image->[1]-1;@visible==$c->{seam}or die 'visible origin';$first=$visible[0];}
   logical_image($image,$c,$first,1);
}
{
   my$b=build('motion',"alias LAYERS_MOTION\n".$fixture);
   $b=~/ram\s+used=127 bytes.*objects=123 bytes hardware-stack=4 bytes/s or die 'animated shared RAM budget';
   run("$tmp/timing","$tmp/motion.bin",'420','--no-audio','--released-inputs','--raw-lines','264');
   my$frames=capture('motion',40);my$pose;my%animation;my$crossed=0;
   my$pose_case=sub{my$p=shift;return{seam=>6,ys=>[$p,$p,$p-4,$p-4,($p-5)&255],hs=>[7,7,5,7,3],frames=>[($p-4)&3,($p-3)&3]};};
   my@matches;
   for my$p(4..19){push@matches,$p if eval{logical_image($frames->[0],$pose_case->($p),$first,0);1};}
   @matches==1 or die 'motion origin is not independently identifiable';$pose=$matches[0];
   for my$image(@$frames){my$c=$pose_case->($pose);logical_image($image,$c,$first,$pose==9);
      $crossed=1 if$pose==9;$animation{$c->{frames}[0]}=1;$pose=4+(($pose-3)&15);
   }
   $crossed&&keys(%animation)==4 or die 'motion lacks a complete seam/four-frame sweep';
}

# These cover mask wrap/offscreen/full intervals and seven-run preparation.
for my$extra([0,0,0,0,0,0],[250,255,200,255,3,220],[48,25,65,5,5,5]){
   my$c={seam=>6,ys=>[9,9,$extra->[2],$extra->[1],$extra->[0]],hs=>[7,7,$extra->[5],$extra->[4],$extra->[3]]};
   my$n='mask_'.join('_',@$extra);build($n,source($c));timing($n,$c);
}

# Instance count, placement and equal constants must not alter cycle contracts.
for my$mode(qw(three uniform repeated)){
   my$s=source($cases[0]);
   if($mode eq'three'){
      $s=~s/number_of_scanlines:=186/number_of_scanlines:=4/;
      $s=~s/void prepare_objects/instantiate "layers\/all_five_section.c26" as third (number_of_scanlines:=182, playfield_row:=0x18244281, pf_color:=14, bk_color:=0)\nvoid prepare_objects/;
      $s=~s/ground_draw\(\);/ground_draw(); third_draw();/;
   }elsif($mode eq'uniform'){
      $s=~s/playfield_row:=0x[0-9a-f]+/playfield_row:=0xffffffff/g;
      $s=~s/pf_color:=0x[0-9a-f]+/pf_color:=3/g;
      $s=~s/bk_color:=0x[0-9a-f]+/bk_color:=2/g;
   }else{
      $s=~s/number_of_scanlines:=6/number_of_scanlines:=96/;
      $s=~s/ground_draw\(\)/sky_draw()/;
   }
   build($mode,$s);run("$tmp/timing","$tmp/$mode.bin",'420','--no-audio','--released-inputs','--raw-lines','264');
}
for my$height(0,1,3,255,256,-2){my$s=source($cases[0]);$s=~s/number_of_scanlines:=6/number_of_scanlines:=$height/;
   eval{build("bad_height_$height",$s);1}and die"invalid height $height accepted";
}
for my$mutation(['pf_color:=0x46','pf_color:=256'],['bk_color:=0xc2','bk_color:=-1']){
   my$s=source($cases[0]);$s=~s/\Q$mutation->[0]\E/$mutation->[1]/ or die 'colour mutation';
   eval{build('bad_colour',$s);1}and die 'invalid colour accepted';
}
{
   my$bad=slurp("$repo/libraries/vcs/layers/all_five_section.c26");
   $bad=~s/asm sta.a GRP0;/asm sta GRP0;/ or die 'phase mutation';save("$tmp/wrong_phase_component.c26",$bad);
   my$s=source($cases[0]);$s=~s!layers/all_five_section.c26!$tmp/wrong_phase_component.c26!g;
   eval{build('bad_phase',$s);run("$tmp/timing","$tmp/bad_phase.bin",'200','--no-audio','--released-inputs','--raw-lines','264');1}
      and die 'shifted object phase accepted';
}
{
   my$bad=slurp("$repo/libraries/vcs/layers/all_five_dense_objects.c26");
   $bad=~s/asm dey;/asm nop;/ or die 'progress mutation';save("$tmp/frozen_player_owner.c26",$bad);
   my$s=source($cases[0]);$s=~s!layers/all_five_dense_objects.c26!$tmp/frozen_player_owner.c26!;
   build('frozen_player',$s);
   eval{timing('frozen_player',$cases[0]);1}and die 'unadvanced shared counter accepted';
   $@=~/memory .*expected/ or die 'frozen player failed for the wrong reason';
}
print "vcs_layers_all_five ok\n";
