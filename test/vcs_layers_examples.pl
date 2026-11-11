#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 240
# expectstdout: vcs_layers_examples ok
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
sub slurp {open my$f,'<:raw',$_[0]or die$!;local$/;return<$f>;}
sub save {open my$f,'>:raw',$_[0]or die$!;print$f $_[1];}
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
sub address {
   my($stem,$symbol)=@_;my$s=slurp("$stem.sym");
   $s=~/^\Q$symbol\E\s+([0-9a-fA-F]{4})\s*$/m or die"missing $symbol";return hex$1;
}
sub findexe {
   my$n=shift;return abs_path($n)if-x$n;
   for(split/:/,$ENV{PATH}//''){return abs_path("$_/$n")if-x"$_/$n";}
   die"required executable $n";
}
my$stella=findexe($ENV{VCSC_STELLA}||$ENV{STELLA}||'stella');
my$xvfb=findexe($ENV{VCSC_XVFB}||$ENV{XVFB}||'Xvfb');
my$helpers=slurp("$repo/test/stella_png_sequence.pl");
$helpers=~s/\n\@ARGV>=2.*\z//s or die 'PNG helpers';eval$helpers;die$@if$@;
my(undef,$display)=vcsc_reserve_x_display(310,20);
my$xp=spawn("$tmp/x.log",$xvfb,$display,'-ac','-screen','0','1024x768x24');
vcsc_xvfb_assert_ready($display,$xp);
local$ENV{DISPLAY}=$display;local$ENV{XAUTHORITY}='/dev/null';local$ENV{SDL_AUDIODRIVER}='dummy';
sub capture {
   my($name,$bin,$count,$frames)=@_;my$d="$tmp/snap_$name";my$u="$tmp/user_$name";
   !-e$d or die 'stale snapshots';make_path($d,$u);
   my$p=spawn("$tmp/$name.log",$stella,vcsc_stella_palette_args($repo,$u),
      '-plr.bankrandom','0','-plr.ramrandom','0','-plr.tiarandom','0',
      '-dev.bankrandom','0','-dev.ramrandom','0','-dev.cpurandom','0','-dev.tiarandom','0',
      '-dev.hsrandom','0','-dev.tiadriven','0','-video','software','-turbo','1','-audio.enabled','0','-bs','4K',
      '-framesnap',($frames//($count==1?'200':'200-239')),'-snapsavedir',$d,'-snapname','rom','-sssingle','1','-ss1x','1',
      '-exitlauncher','0','-confirmexit','0','-userdir',$u,$bin);
   my@png=vcsc_stella_wait_snapshots("$d/*.png",$count);stop($p);@png>=$count or die 'missing snapshots';
   return[map{[decode_rgb($_)]}@png];
}

# Exact checks use private fixtures, never the editable presentation sources.
my@leaves=qw(no_score score_below score_above);
my$family='examples/04_renderers/cooperating_layers';
my$fixtures="$repo/test/fixtures/layers/examples";
my$mos="$repo/simulator/mos6502";my$obj=-f"$mos/mos6502.o"?"$mos/mos6502.o":"$mos/mos6502.cpp";
my$original=slurp("$repo/test/vcs_frame_timing.cpp");
my$hook=<<'CPP';
      static unsigned frame=0,stage=0,pf=0;
      static uint64_t first=0,start=0;
      static bool game=false;
      if (!(event.address & 0x1080)) {
         const unsigned reg=event.address & 63;
         if (reg==0 && (event.value & 2)) stage=0;
         if (reg==1) {
            if (event.value & 2) {
               if (game && (pf!=GAME_LINES*4 || virtual_cycles-start!=(MODE==2?GAME_LINES:192)*76+2)) {
                  std::fprintf(stderr,"example gameplay extent/count mismatch\n");std::exit(1);
               }
               game=false;
            } else {
               ++stage;
               const unsigned f=stage==1?frame++:frame-1,clock=f&255,phase=(10+f/4)%(2*MAX_Y);
               const unsigned y=phase<MAX_Y?phase:2*MAX_Y-phase;
               if (stage==1) first=virtual_cycles;
               auto word=[](unsigned a){return unsigned(peek_memory(a))+(unsigned(peek_memory(a+1))<<8);};
               if (peek_memory(CLOCK)!=clock || peek_memory(PHASE)!=phase) {
                  std::fprintf(stderr,"example speed/turnaround state mismatch\n");std::exit(1);
               }
               const unsigned ys[]={Y0,Y1,YM0,YM1,YB},want[]={y+8,y+8,y+6,y+6,y+4};
               for(unsigned i=0;i<5;++i) if(peek_memory(ys[i])!=want[i]) {
                  std::fprintf(stderr,"example public Y mismatch\n");std::exit(1);
               }
               const unsigned xs[]={20,100,50,110,80};
               for(unsigned i=0;i<5;++i) if(peek_memory(XS+i)!=xs[i]) {
                  std::fprintf(stderr,"example public X changed\n");std::exit(1);
               }
               if(word(G0)!=P0+((clock>>3)&3)*8 || word(G1)!=P1+((clock>>3)&3)*8) {
                  std::fprintf(stderr,"example graphics/animation mismatch\n");std::exit(1);
               }
               const unsigned prime=MODE==2 && stage==1?0:1;
               if(peek_memory(C0)!=y+8-prime || peek_memory(C1)!=y+9-prime) {
                  std::fprintf(stderr,"example vertical preparation/prime mismatch\n");std::exit(1);
               }
               for(unsigned i=0;i<(MODE?88:96);++i) {
                  const unsigned t=i+1,b=((t>=y+2&&t<=y+7)?4:0)|((t>=y&&t<=y+7)?8:0)|((t>=y+3&&t<=y+6)?2:0);
                  if(peek_memory(MASK+i)!=b) {
                     std::fprintf(stderr,"example enable stream/lifetime mismatch\n");std::exit(1);
                  }
               }
#if MODE
               const unsigned values[]={(12+f/16)%100,(34+f/16)%100},scores[]={S0,S1};
               for(unsigned side=0;side<2;++side) {
                  const unsigned v=values[side];
                  if(peek_memory(scores[side])!=((v/10)<<4)+(v%10) ||
                     word(MASK+88+side*4)!=FONT_H+(v/10)*8 || word(MASK+90+side*4)!=FONT_L+(v%10)*8) {
                     std::fprintf(stderr,"example runtime score/workspace mismatch\n");std::exit(1);
                  }
               }
#endif
               game=MODE!=2 || stage==2;
               if(game) {
                  if(MODE==2 && virtual_cycles-first!=20*76) {
                     std::fprintf(stderr,"example score-above prefix mismatch\n");std::exit(1);
                  }
                  start=virtual_cycles;pf=0;
               }
            }
         } else if(game && virtual_cycles-start<GAME_LINES*76 && (reg==14||reg==15)) {
            const unsigned regs[]={14,15,15,14},even[]={3,32,48,53},odd[]={18,23,48,53};
            const unsigned line=pf/4,slot=pf++%4;
            const unsigned phase=!line&&!slot?8:(line&1?odd[slot]:even[slot]);
            if(reg!=regs[slot] || virtual_cycles%76!=phase) {
               std::fprintf(stderr,"example PF write deadline mismatch\n");std::exit(1);
            }
         } else if(game && virtual_cycles-start<GAME_LINES*76 && reg>=27&&reg<=31) {
            const unsigned phases[]={72,2,12,13,60};
            if(virtual_cycles%76!=phases[reg-27]) {
               std::fprintf(stderr,"example object write deadline mismatch\n");std::exit(1);
            }
         }
      }
CPP
my@stems;
for my$mode(0..2){my$leaf=$leaves[$mode];my$stem="$tmp/layers_$leaf";
   my$source=slurp("$fixtures/main.c26");$source=~s/DEMO_MODE/$mode/g;
   $source=~s!\.\./\.\./\.\./_common!$fixtures/_common!g;save("$stem.c26",$source);
   my$out=run("$repo/driver/vcsc",'-I',"$repo/libraries/vcs",'-Map',"$stem.map","$stem.c26",'-o',"$stem.bin");
   my$ram=$mode?128:126;my$data=$mode?126:124;
   $out=~/ram\s+used=$ram bytes.*objects=$data bytes hardware-stack=2 bytes/s or die "$leaf RAM/stack budget";
   push@stems,$stem;-s"$stem.bin"==4096 or die 'example bank budget';
   my%defines=(MODE=>$mode,GAME_LINES=>($mode==0?192:$mode==1?176:172),MAX_Y=>($mode==0?86:$mode==1?78:76));
   my%names=(CLOCK=>'motion_clock',PHASE=>'motion_phase',XS=>'layers_object_x',MASK=>'layers_object_masks',
      Y0=>'layers_player0_y',Y1=>'layers_player1_y',YM0=>'layers_missile0_y',YM1=>'layers_missile1_y',YB=>'layers_ball_y',
      G0=>'layers_player0_graphics',G1=>'layers_player1_graphics',P0=>'demo_p0',P1=>'demo_p1',
      C0=>'layers_player0_counter',C1=>'layers_player1_counter');
   %names=(%names,S0=>'score_left_score',S1=>'score_right_score',FONT_H=>'vcs_two_plus_two_font_high',FONT_L=>'vcs_two_plus_two_font_low')if$mode;
   $defines{$_}=address($stem,$names{$_})for keys%names;
   my$cpu=join('',map{"#define $_ $defines{$_}\n"}sort keys%defines).$original;
   $cpu=~s/(   for \(const WriteEvent &event : writes\) \{)/$1\n$hook/ or die 'CPU hook';
   save("$tmp/cpu_$mode.cpp",$cpu);
   run($ENV{CXX}||'c++','-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,"$tmp/cpu_$mode.cpp",$obj,'-o',"$tmp/cpu_$mode");
   run("$tmp/cpu_$mode","$stem.bin",'1600','--no-audio','--released-inputs','--raw-lines','264');
}

# Exact RGB is calibrated independently with solid fields, not candidate glyphs.
my@codes=(0x46,0x48,0x0a,0x0c,0x0e,0x26,0x28,0x2a,0x2c,0x2e,0x80,0x84,0xb0,0xb4,0x20,0x24);
my$cal="include \"vcs.c26\"\ninclude \"frame_ntsc.c26\"\nvoid main(void){VBLANK:=2;while(1){vcs_ntsc_vsync();vcs_ntsc_begin_vblank();vcs_ntsc_end_vblank();\n";
$cal.="COLUBK:=$_;vcs_ntsc_wait_scanlines(12);\n"for@codes;
$cal.="vcs_ntsc_begin_overscan();vcs_ntsc_end_overscan();}}\n";save("$tmp/palette.c26",$cal);
run("$repo/driver/vcsc",'-I',"$repo/libraries/vcs","$tmp/palette.c26",'-o',"$tmp/palette.bin");
my$calrgb=capture('palette',"$tmp/palette.bin",1)->[0];my$w=$calrgb->[0];$w==320 or die 'unexpected raster width';
my@stripes;my$last='';for my$y(0..$calrgb->[1]-1){my$c=substr($calrgb->[2],($y*$w+160)*3,3);
   if($c ne$last){push@stripes,$c if$c ne"\0\0\0";$last=$c;}}
@stripes==@codes or die 'palette stripe count';my%rgb;$rgb{$codes[$_]}=$stripes[$_]for 0..$#codes;
my@colors=([0x46,0x48,0x0a,0x0c,0x0c,0x0e,0x0e,0x0c],[0x26,0x28,0x2a,0x2c,0x2c,0x2e,0x2e,0x2c]);
my@bodies=([0,0,0xdb,0x7e,0x7e,0x3c,0x3c,0x18],[0,0,0x7e,0x3c,0x7e,0x7e,0x3c,0x18]);
my@exhaust=(0x24,0x18,0x3c,0x18);
my@font=([7,5,5,5,5,5,5,7],[2,6,2,2,2,2,2,7],[7,1,1,7,4,4,4,7],[7,1,1,7,1,1,1,7],[5,5,5,7,1,1,1,1],
   [7,4,4,7,1,1,1,7],[7,4,4,7,5,5,5,7],[7,1,1,2,2,4,4,4],[7,5,5,7,5,5,5,7],[7,5,5,7,1,1,1,7]);
sub paint {my($s,$x,$n,$c)=@_;substr($$s,$x*6,$n*6)=$c x($n*2);}
sub pixels {
   my($mode,$f)=@_;my$max=$mode==0?86:$mode==1?78:76;my$lines=$mode==0?192:$mode==1?176:172;
   my$phase=(10+int($f/4))%(2*$max);my$y=$phase<$max?$phase:2*$max-$phase;
   my$frame=(($f&255)>>3)&3;my@out=("\0"x($w*3))x192;my$offset=$mode==2?20:0;
   for my$l(0..$lines-1){my$scene=int($l/64);my@rows=(0x80000001,0xc0000003,0xe0000007);
      my@bk=(0x80,0xb0,0x20);my@pf=(0x84,0xb4,0x24);my$s=$rgb{$bk[$scene]}x32;
      $s.=($_ eq'1'?$rgb{$pf[$scene]}:$rgb{$bk[$scene]})x8for split//,sprintf('%032b',$rows[$scene]);$s.=$rgb{$bk[$scene]}x32;
      my@row=($y+7-int($l/2),$l==0?$y+8:$y+7-int(($l-1)/2));
      my$t0=int($l/2)+1;my$t1=$l==0?1:int(($l-1)/2)+1;
      paint(\$s,78,4,$rgb{$pf[$scene]})if$t1>=$y+3&&$t1<=$y+6;
      for my$p(1,0){my$r=$row[$p];my$c=$rgb{$colors[$p][$r>=0&&$r<=7?$r:0]};
         if($r>=0&&$r<=7){my$glyph=$r==1?$exhaust[$frame]:$bodies[$p][$r];
            for my$b(0..7){paint(\$s,($p?99:19)+$b,1,$c)if$glyph&(128>>$b);}}
         if($p){paint(\$s,108,4,$c)if$t1>=$y&&$t1<=$y+7;}
         else{paint(\$s,48,4,$c)if$t0>=$y+2&&$t0<=$y+7;}
      }
      $out[$offset+$l]=$s;
   }
   if($mode){my$score_y=$mode==1?176:0;
      for my$r(0..7){for my$field([32,(12+int($f/16))%100],[96,(34+int($f/16))%100]){
         my($x,$v)=@$field;my$packed=($font[int($v/10)][$r]<<5)|($font[$v%10][$r]<<1);
         for my$b(0..7){paint(\$out[$score_y+4+$r],$x+2*$b,2,$rgb{14})if$packed&(128>>$b);}
      }}
   }
   return join'',@out;
}
for my$mode(0..2){for my$range('40-79','200-239'){
   my$images=capture("$leaves[$mode]_$range","$stems[$mode].bin",40,$range);my$first;
   my@sky=grep{substr($images->[0][2],($_*$w+20)*3,3)eq$rgb{0x80}}0..$images->[0][1]-1;
   @sky==64 or die 'example sky extent';$first=$sky[0]-($mode==2?20:0);
   my@candidates=grep{pixels($mode,$_)eq substr($images->[0][2],$first*$w*3,192*$w*3)}0..511;
   @candidates or die 'example first pose is not independently matched';
   for my$i(1..39){@candidates=grep{pixels($mode,$_+$i)eq substr($images->[$i][2],$first*$w*3,192*$w*3)}@candidates;
      @candidates or die "example $leaves[$mode] motion/score RGB mismatch at snapshot$i";}
   @candidates==1 or die 'example moving phase is not unique';
   my$seam=$range eq'40-79'?64:128;my$max=$mode==0?86:$mode==1?78:76;my$crossed=0;
   for my$i(0..39){my$phase=(10+int(($candidates[0]+$i)/4))%(2*$max);my$y=$phase<$max?$phase:2*$max-$phase;
      $crossed=1 if 2*($y+3)<$seam && 2*($y+6)>$seam;
   }
   $crossed or die "example lacks complete all-five crossing at seam$seam";
}}

# Installed examples must build without reaching into tests or another leaf.
save("$tmp/smoke_timing.cpp",$original);
run($ENV{CXX}||'c++','-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,"$tmp/smoke_timing.cpp",$obj,'-o',"$tmp/smoke_timing");
run($^X,"$repo/packaging/install_manifest.pl",'install','--manifest',"$repo/packaging/install.manifest",'--scope','libraries',
   '--source-root',$repo,'--dest-root',"$tmp/installed");
run($^X,"$repo/packaging/install_manifest.pl",'install','--manifest',"$repo/packaging/install.manifest",'--scope','examples',
   '--source-root',$repo,'--dest-root',"$tmp/installed/examples");
for my$mode(0..2){my$leaf=$leaves[$mode];my$d="$tmp/installed/$family/$leaf";
   run('make','-C',$d,"VCSC=$repo/driver/vcsc","VCS_DIR=$tmp/installed/libraries/vcs");
   run("$repo/driver/vcsc",'-I',"$repo/libraries/vcs","$repo/$family/$leaf/main.c26",'-o',"$tmp/source_$leaf.bin");
   slurp("$d/layers_$leaf.bin")eq slurp("$tmp/source_$leaf.bin")or die 'installed example differs from source build';
   run("$tmp/smoke_timing","$d/layers_$leaf.bin",'1600','--no-audio','--released-inputs','--raw-lines','264');
   run('make','-C',$d,'clean');
   !-e"$d/layers_$leaf.bin"or die 'example clean left its ROM';
}
print "vcs_layers_examples ok\n";
