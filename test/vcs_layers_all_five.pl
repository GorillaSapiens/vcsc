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
my$edge_mode=$ARGV[2];
!defined($edge_mode)||$edge_mode=~/^(?:[0-7]|geometry)$/ or die 'edge mode must be0..7 or geometry';
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
      static unsigned layers_pf = 0, layers_boundary = ~0u;
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
             if (layers_visible) { layers_pf=0; layers_boundary=~0u; layers_start=virtual_cycles; }
          } else if (layers_visible && reg==9) {
             layers_boundary=(virtual_cycles-layers_start+3)/76;
          } else if (layers_visible && (reg == 14 || reg == 15)) {
            static const unsigned regs[] = {14,15,15,14};
              static const unsigned even[] = {18,33,48,51};
              static const unsigned odd[] = {19,24,48,53};
            const unsigned line = layers_pf/4, slot=layers_pf++%4;
            unsigned phase = (line&1)?odd[slot]:even[slot];
             if (!(line&1) && !slot && line==layers_boundary) phase=23;
             if (!line && !slot) phase=8;
             const unsigned raster=(virtual_cycles-layers_start+3)/76;
              const unsigned expected_line=line;
             if (reg != regs[slot] || virtual_cycles%76 != phase || raster!=expected_line) {
               std::fprintf(stderr,"layers PF phase mismatch: line=%u slot=%u reg=%u phase=%llu expected=%u\n",line,slot,reg,(unsigned long long)(virtual_cycles%76),phase); std::exit(1);
            }
         } else if (layers_visible && reg >= 27 && reg <= 31) {
              static const unsigned phases[] = {13,3,3,14,9};
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
   my$p=spawn("$tmp/$n.log",vcsc_stella_capture_launcher($repo,$stella),vcsc_stella_palette_args($repo,$u),
      '-plr.bankrandom','0','-plr.ramrandom','0','-plr.tiarandom','0',
      '-dev.bankrandom','0','-dev.ramrandom','0','-dev.cpurandom','0','-dev.tiarandom','0',
      '-dev.hsrandom','0','-dev.tiadriven','0','-video','software','-turbo','1',
       '-audio.enabled','0','-bs','4K','--capture-frames',($count==1?'200':'200-'.(199+$count)),'--capture-dir',$d,
       '-exitlauncher','0','-confirmexit','0','-userdir',$u,"$tmp/$n.bin");
   my@png=vcsc_stella_wait_snapshots("$d/*.png",$count);stop($p);
    @png>=$count or die "$n missing snapshots";return[map{[decode_stella_rgb($_)]}@png];
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
   {seam=>8,ys=>[9,9,4,5,5],hs=>[7,7,3,3,3],no_witness=>1}, # six transitions, seven runs; seam witnesses above
);
sub source {
   my($case)=@_;my$s=$fixture;
   $s=~s/(as sky \(number_of_scanlines:=)6,/$1$case->{seam},/ or die 'first height';
   my$rest=192-$case->{seam};$s=~s/(as ground \(number_of_scanlines:=)186,/$1$rest,/ or die 'second height';
   for my$i(0..4){
      $s=~s/(layers_$objects[$i]_y:=)\d+;/$1$case->{ys}[$i];/ or die 'pose';
      $s=~s/(layers_$objects[$i]_height:=)\d+;/$1$case->{hs}[$i];/ or die 'height';
   }
   if($case->{frames}){for my$p(0..1){my$off=$case->{frames}[$p]*8;
      $s=~s/layers_player${p}_graphics:=p$p;/asm lda #<{p$p + $off}; asm sta.z layers_player${p}_graphics; asm lda #>{p$p + $off}; asm sta.z layers_player${p}_graphics + 1;/ or die 'frame pointer';
   }}
   if($case->{nusiz}){for my$p(0..1){$s=~s/player${p}_nusiz:=0x20/player${p}_nusiz:=$case->{nusiz}[$p]/ or die 'intro width parameter';}}
   if($case->{ball_width}){$s=~s/CTRLPF:=0x21;/CTRLPF:=0x11;/ or die 'Ball width';}
   if($case->{xs}){for my$i(0..4){$s=~s/(layers_object_x\[$i\]:=)\d+;/$1$case->{xs}[$i];/ or die 'runtime X';}}
   if($case->{high_bits}){
      $s=~s/GLYPH\((0x[0-9a-fx,]+)\)/
         my@r=split(',',$1);$r[$_]=sprintf('0x%02x',oct($r[$_])^128)for 0..6;
         'GLYPH('.join(',',@r).')'/eg;
   }
   return$s;
}
sub masks {
   my($c)=@_;my@result;
   for my$t(1..96){my$b=0;
      for my$o(2..4){my$last=($c->{ys}[$o]+($o==4?2:1))&255;my$first=($last-$c->{hs}[$o])&255;
         my$on=$first<=$last?($t>=$first&&$t<=$last):($t>=$first||$t<=$last);
          $b|=(4,1,2)[$o-2] if$on;
      }push@result,$b;
   }return@result;
}
sub event_bytes {
   my$c=shift;my@m=masks($c);my@starts=(0,grep{$m[$_]!=$m[$_-1]}1..95);my@events;
   for my$i(0..$#starts){push@events,($i==$#starts?255:$starts[$i+1]-$starts[$i]),$m[$starts[$i]];}
   @events<=14 or die 'more than six enable transitions';return@events;
}
sub event_expect {
   my($n,$c)=@_;my@events=event_bytes($c);my$a=address($n,'layers_event_data');my@expect;
   push@expect,'--expect-memory',$a+$_,$events[$_]for 0..$#events;return@expect;
}
sub timing {
   my($n,$c,$frames)=@_;$frames//=420;my@expect=event_expect($n,$c);
   for my$p(0..1){push@expect,'--expect-memory',address($n,"layers_player${p}_counter"),($c->{ys}[$p]-97)&255;}
   for my$p(0..1){
      my$frame=$c->{frames}?$c->{frames}[$p]:0;my$ptr=address($n,"p$p")+$frame*8;my$a=address($n,"layers_player${p}_graphics");
       push@expect,'--expect-memory',$a,$ptr&255,'--expect-memory',$a+1,$ptr>>8;
   }
   for my$i(0..4){push@expect,'--expect-memory',address($n,"layers_$objects[$i]_y"),$c->{ys}[$i],'--expect-memory',address($n,"layers_$objects[$i]_height"),$c->{hs}[$i];}
   my$xbase=address($n,'layers_object_x');my@xs=$c->{xs}?@{$c->{xs}}:(20,130,50,110,80);
   push@expect,'--expect-memory',$xbase+$_,$xs[$_]for 0..4;
   run("$tmp/timing","$tmp/$n.bin",$frames,'--no-audio','--released-inputs','--raw-lines','264',@expect);
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
# NUSIZ low bits are a hardware mode, not a simple copy count. Stretching
# adds one pixel to the primary graphic's start on the TIA. Missile copies
# follow the mode's offsets but never inherit the player's stretch factor.
my@copy_offsets=([0],[0,16],[0,32],[0,16,32],[0,64],[0],[0,32,64],[0]);
sub paint {
   my($row,$x,$length,$color)=@_;
   for my$i(0..$length-1){my$at=$x+$i;next if$at<0||$at>=160;substr($$row,$at*6,6)=$color x2;}
}
sub paint_wrapped {
   my($row,$x,$length,$color)=@_;
   for my$i(0..$length-1){my$at=($x+$i)%160;substr($$row,$at*6,6)=$color x2;}
}
sub logical_image {
   my($image,$c,$first,$witness)=@_;my($width,$height,$actual)=@$image;
   $width==320 or die 'unexpected raster width';my@m=masks($c);my%seen;
   for my$line(0..($c->{lines}//192)-1){
      my$scene=$line<$c->{seam}?0:1;my$bits=sprintf('%032b',$scene?0x3c96a569:0x81244596);
      my$bk=$rgb{$scene?0x26:0xc2};my$pf=$rgb{$scene?0x8e:0x46};
      my$want=$bk x32;$want.=($_ eq'1'?$pf:$bk)x8for split//,$bits;$want.=$bk x32;
      my$scenery=$want;my@row=($c->{ys}[0]-1-int($line/2),$line==0?$c->{ys}[1]:$c->{ys}[1]-1-int(($line-1)/2));
      my@xs=$c->{xs}?@{$c->{xs}}:(20,130,50,110,80);
      my$i0=int($line/2);my$i1=$line==0?0:int(($line-1)/2);
      my$mw0=$c->{nusiz}?(1<<(($c->{nusiz}[0]>>4)&3)):4;
      my$mw1=$c->{nusiz}?(1<<(($c->{nusiz}[1]>>4)&3)):4;
      my$bw=$c->{ball_width}//4;
      # CTRLPF priority=0: P0/M0 > P1/M1 > PF/BL. Paint back to front so
      # runtime placements may overlap without changing the logical oracle.
       paint_wrapped(\$want,$xs[4]-2,$bw,$pf)if$m[$i1]&2;
      for my$p(1,0){
         my$r=$row[$p];my$mode=$c->{nusiz}?($c->{nusiz}[$p]&7):0;
         my$scale=$mode==5?2:$mode==7?4:1;
         if($r>=0&&$r<=$c->{hs}[$p]){my$frame=$c->{frames}?$c->{frames}[$p]:0;my$glyph=$graphics[$p][$frame][$r];
             $glyph^=128 if$c->{high_bits}&&$r;
             for my$offset(@{$copy_offsets[$mode]}){for my$b(0..7){next unless$glyph&(128>>$b);
                paint_wrapped(\$want,$xs[$p]-1+($scale==1?0:1)+$offset+$b*$scale,$scale,$rgb{$colors[$p][$r]});
            }}
         }
          my$index=$p?$i1:$i0;next unless$m[$index]&($p?1:4);
         my$init=$c->{ys}[$p]-1+$p;
         my$color=$r>$c->{hs}[$p]?$colors[$p][$init<=$c->{hs}[$p]?$init:0]:$colors[$p][$r<0?0:$r];
          for my$offset(@{$copy_offsets[$mode]}){paint_wrapped(\$want,$xs[2+$p]-2+$offset,$p?$mw1:$mw0,$rgb{$color});}
      }
      my$got=substr($actual,($first+$line)*$width*3,$width*3);
       if($got ne$want){for my$x(0..$width-1){substr($got,$x*3,3)eq substr($want,$x*3,3)or die"logical RGB mismatch seam=$c->{seam} line=$line x=$x got=".unpack('H*',substr($got,$x*3,3))." want=".unpack('H*',substr($want,$x*3,3))."\n";}}
      if($witness&&$line>=$c->{seam}-2&&$line<=$c->{seam}+1){
         my$side=$line<$c->{seam}?0:1;
         for my$o(['P0',2*$xs[0]-2,2*$xs[0]+14],['P1',2*$xs[1]-2,2*$xs[1]+14],
                  ['M0',2*$xs[2]-4,2*$xs[2]-4+2*$mw0],['M1',2*$xs[3]-4,2*$xs[3]-4+2*$mw1],
                  ['BL',2*$xs[4]-4,2*$xs[4]-4+2*$bw]){
            my($name,$a,$b)=@$o;$seen{"$name/$side"}=1 if substr($got,$a*3,($b-$a)*3)ne substr($scenery,$a*3,($b-$a)*3);
         }
      }
   }
   if($witness){for my$n(qw(P0 P1 M0 M1 BL)){for my$s(0,1){$seen{"$n/$s"}or die"$n not visibly crossing seam $c->{seam} side$s";}}}
}
if(defined($edge_mode)&&$edge_mode eq'geometry'){
   build('geometry_origin',source($cases[0]));my$origin=capture('geometry_origin')->[0];
   my@visible=grep{substr($origin->[2],($_*$w+20)*3,3)eq$rgb{0xc2}}0..$origin->[1]-1;
   @visible==6 or die 'geometry visible origin';my$first=$visible[0];
   for my$height(map{2*$_}1..95){my$y=$height/2+6;
      my$c={seam=>$height,ys=>[$y,$y,$y-4,$y-4,$y-5],hs=>[7,7,5,7,3]};
      my$n="height_$height";build($n,source($c));timing($n,$c,60);
      logical_image(capture($n)->[0],$c,$first,1);
   }
   for my$height(map{2*$_}96..127){my$s=source($cases[0]);
      $s=~s/number_of_scanlines:=6/number_of_scanlines:=$height/;
      $s=~s/ground_draw\(\);//;
      my$n="large_height_$height";build($n,$s);
      run("$tmp/timing","$tmp/$n.bin",'60','--no-audio','--released-inputs','--raw-lines','264')if$height==192;
   }
   print "vcs_layers_all_five ok\n";exit 0;
}
if(defined$edge_mode){
   build('edge_origin',source($cases[0]));my$origin=capture('edge_origin')->[0];
   my@visible=grep{substr($origin->[2],($_*$w+20)*3,3)eq$rgb{0xc2}}0..$origin->[1]-1;
   @visible==6 or die 'edge visible origin';my$first=$visible[0];
   for my$p(0,1){
      my@xs=(20,80,50,110,80);$xs[$p]=0;$xs[2+$p]=0;
      my@ys=(255,255,255,255,4);$ys[$p]=9;$ys[2+$p]=5;
       my$nusiz=[0x20,0x20];$nusiz->[$p]=(($edge_mode&3)<<4)|$edge_mode;
      my$c={seam=>6,ys=>\@ys,hs=>[7,7,5,7,3],xs=>\@xs,nusiz=>$nusiz,
         frames=>[0,1],high_bits=>1};
      my$update=<<ASM;
      asm inc.z layers_object_x + $p;
      asm lda.z layers_object_x + $p;
      asm cmp #160;
      asm bcc.same \@edge_no_wrap;
      asm lda #0;
      asm sta.z layers_object_x + $p;
      asm \@edge_no_wrap:;
      asm sta.z layers_object_x + @{[2+$p]};
ASM
      for my$player(0,1){
         $update.="asm lda.z layers_object_x + $p;\n";
         $update.="asm clc; asm adc #1;\n"if$player;
         $update.="asm and #3; asm asl; asm asl; asm asl; asm clc; asm adc #<p$player; asm sta.z layers_player${player}_graphics; asm lda #>p$player; asm sta.z layers_player${player}_graphics + 1;\n";
      }
      my$n="sweep_p${p}_mode$edge_mode";my$s=source($c);
      $s=~s/(      vcs_ntsc_end_overscan\(\);)/$update\n$1/ or die 'edge overscan update';
       my$budget=build($n,$s);$budget=~/objects=42 bytes hardware-stack=2 bytes/ or die 'edge sweep RAM/stack budget';
      my$xbase=address($n,'layers_object_x');my@g=map{address($n,"layers_player${_}_graphics")}0..1;
      my@tables=map{address($n,"p$_")}0..1;
      my@counter=map{address($n,"layers_player${_}_counter")}0..1;
       my$a=address($n,'layers_event_data');my@m=event_bytes($c);
      my$model=<<CPP;
      if (!(event.address & 0x1080) && (event.address & 63)==1 && !(event.value & 2)) {
         static unsigned frame=0;
         const unsigned x=frame++%160;
         const unsigned xs[]={@{[join ',',@xs]}}, pointers[]={@{[join ',',@g]}}, tables[]={@{[join ',',@tables]}};
         const unsigned counters[]={@{[join ',',@counter]}}, ys[]={@{[join ',',@ys[0,1]]}};
         static const unsigned masks[]={@{[join ',',@m]}};
         for(unsigned i=0;i<5;++i) if(peek_memory($xbase+i)!=((i==$p || i==@{[2+$p]})?x:xs[i])) {
            std::fprintf(stderr,"edge live X sequence mismatch\\n"); std::exit(1);
         }
         for(unsigned i=0;i<2;++i) {
            const unsigned ptr=tables[i]+((x+i)&3)*8;
            if(peek_memory(pointers[i])!=(ptr&255) || peek_memory(pointers[i]+1)!=(ptr>>8) ||
               peek_memory(counters[i])!=((ys[i]-1)&255)) {
               std::fprintf(stderr,"edge live pointer/mode/prime mismatch\\n"); std::exit(1);
            }
         }
         for(unsigned i=0;i<sizeof(masks)/sizeof(masks[0]);++i) if(peek_memory($a+i)!=masks[i]) {
            std::fprintf(stderr,"edge live enable stream mismatch\\n"); std::exit(1);
         }
      }
CPP
      my$cpu=$timing;$cpu=~s/\Q$hook\E/$hook\n$model/ or die 'edge live hook';
      save("$tmp/edge_timing.cpp",$cpu);
      run($ENV{CXX}||'c++','-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,"$tmp/edge_timing.cpp",$obj,'-o',"$tmp/edge_timing");
      run("$tmp/edge_timing","$tmp/$n.bin",'420','--no-audio','--released-inputs','--raw-lines','264');
      my$pose=sub{my$x=shift;my@positions=@xs;$positions[$p]=$positions[2+$p]=$x;
         my@sizes=@$nusiz;
         return{%$c,xs=>\@positions,nusiz=>\@sizes,frames=>[$x&3,($x+1)&3]};
      };
      my$images=capture($n,160);my@matches;
      for my$x(0..159){push@matches,$x if eval{logical_image($images->[0],$pose->($x),$first,0);1};}
      @matches==1 or die "$n: live edge origin not uniquely identifiable";
      my$x=$matches[0];my%seen;
      for my$image(@$images){
         eval{logical_image($image,$pose->($x),$first,0);1}or die"$n X$x: $@";
         $seen{$x}=1;$x=($x+1)%160;
      }
      keys(%seen)==160 or die 'edge sweep omitted a coordinate';
   }
   print "vcs_layers_all_five ok\n";exit 0;
}
my$first;
for my$index(0..$#cases){my$c=$cases[$index];my$s=source($c);my$n="sections_$index";
   my$b=build($n,$s);$b=~/objects=42 bytes hardware-stack=2 bytes/ or die 'shared RAM/stack budget';timing($n,$c);
   my$image=capture($n)->[0];
   if(!defined$first){my@visible=grep{substr($image->[2],($_*$w+20)*3,3)eq$rgb{0xc2}}0..$image->[1]-1;@visible==$c->{seam}or die 'visible origin';$first=$visible[0];}
   logical_image($image,$c,$first,!$c->{no_witness});
}
for my$mode(0..7){
   my$c={%{$cases[0]},xs=>[10,40,30,65,120],nusiz=>[0x20|$mode,0x20|$mode]};
   my$n="copies_$mode";build($n,source($c));timing($n,$c);
   eval{logical_image(capture($n)->[0],$c,$first,0);1}or die"$n: $@";
}
for my$xs([0,0,30,65,120],[1,1,30,65,120],[80,100,50,110,80]){
   my$c={%{$cases[0]},xs=>$xs};my$n='position_'.join('_',@$xs);
   build($n,source($c));timing($n,$c);
   eval{logical_image(capture($n)->[0],$c,$first,0);1}or die"$n: $@";
}
# Previously failing witnesses are now positive complete-image regressions.
for my$probe(
   ['p0_right',[150,80,50,110,80],[0x20,0x20]],
   ['p1_right',[20,150,50,110,80],[0x20,0x20]],
   ['m1_copy_right',[20,80,50,110,80],[0x22,0x22]],
){
   my($name,$xs,$nusiz)=@$probe;my$c={%{$cases[0]},xs=>$xs,nusiz=>$nusiz};
   build($name,source($c));timing($name,$c);my$image=capture($name)->[0];
   logical_image($image,$c,$first,0);
}
for my$mode(0..7){for my$p(0,1){for my$x(0,127,143,150,159){
   my@xs=(20,80,50,110,80);$xs[$p]=$x;
   my$nusiz=[0x20,0x20];$nusiz->[$p]|=$mode;
   my$c={%{$cases[0]},xs=>\@xs,nusiz=>$nusiz};
   my$n="edge_p${p}_mode${mode}_x$x";build($n,source($c));timing($n,$c);
   eval{logical_image(capture($n)->[0],$c,$first,0);1}or die"$n: $@";
}}}
for my$controls(0,1){
   my$name=$controls?'motion_controls':'motion';
   my$b=build($name,"alias LAYERS_MOTION\n".($controls?"alias LAYERS_CONTROLS\n":'').$fixture);
     $b=~/ram\s+used=45 bytes.*objects=43 bytes hardware-stack=2 bytes/s or die 'animated shared RAM budget';
   run("$tmp/timing","$tmp/$name.bin",'420','--no-audio','--released-inputs','--raw-lines','264');
   my$frames=capture($name,40);my$pose;my%animation;my%modes;my$crossed=0;
   my$pose_case=sub{my$p=shift;my$c={seam=>6,ys=>[$p,$p,$p-4,$p-4,($p-5)&255],hs=>[7,7,5,7,3],frames=>[($p-4)&3,($p-3)&3]};
       if($controls){my$delta=$p&1;$c->{nusiz}=[0x20,0x20];$c->{xs}=[map{$_+$delta}(10,40,30,65,120)];}
      return$c;
   };
   my@matches;
   for my$p(4..19){push@matches,$p if eval{logical_image($frames->[0],$pose_case->($p),$first,0);1};}
   @matches==1 or die 'motion origin is not independently identifiable';$pose=$matches[0];
   for my$image(@$frames){my$c=$pose_case->($pose);logical_image($image,$c,$first,!$controls&&$pose==9);
      $crossed=1 if$pose==9;$animation{$c->{frames}[0]}=1;$modes{$c->{nusiz}[0]&7}=1 if$controls;$pose=4+(($pose-3)&15);
   }
   $crossed&&keys(%animation)==4 or die 'motion lacks a complete seam/four-frame sweep';
    keys(%modes)==1 or die 'intro mode must remain constant' if$controls;
}
{
   my$n='human_preview';my$b=build($n,slurp("$repo/test/fixtures/layers/preview.c26"));
     $b=~/ram\s+used=47 bytes.*objects=45 bytes hardware-stack=2 bytes/s or die 'preview RAM budget';
   my@ys=map{address($n,"layers_${_}_y")}@objects;
   my@graphics=map{address($n,"layers_player${_}_graphics")}0..1;
   my@sources=map{address($n,"preview_p$_")}0..1;
   my@state=map{address($n,"preview_$_")}qw(clock y direction);
   my$model=<<CPP;
      if (!(event.address & 0x1080) && (event.address & 63)==1 && !(event.value & 2)) {
         static unsigned clock=0, y=10, direction=0;
         const unsigned state[]={@{[join ',',@state]}};
         const unsigned inputs[]={@{[join ',',@ys]}};
         const unsigned pointers[]={@{[join ',',@graphics]}};
         const unsigned tables[]={@{[join ',',@sources]}};
         const unsigned expected[]={y+8,y+8,y+6,y+6,y+4};
         if (peek_memory(state[0])!=clock || peek_memory(state[1])!=y || peek_memory(state[2])!=direction) {
            std::fprintf(stderr,"preview motion rate/turnaround mismatch\\n"); std::exit(1);
         }
         for (unsigned i=0;i<5;++i) if (peek_memory(inputs[i])!=expected[i]) {
            std::fprintf(stderr,"preview public pose mismatch\\n"); std::exit(1);
         }
         for (unsigned p=0;p<2;++p) {
            const unsigned ptr=tables[p]+((clock>>3)&3)*8;
            if (peek_memory(pointers[p])!=(ptr&255) || peek_memory(pointers[p]+1)!=(ptr>>8)) {
               std::fprintf(stderr,"preview exhaust animation rate mismatch\\n"); std::exit(1);
            }
         }
         clock=(clock+1)&255;
         if (!(clock&3)) {
            if (direction) { if (--y==0) direction=0; }
            else { if (++y==86) direction=1; }
         }
      }
CPP
   my$cpu=$timing;$cpu=~s/\Q$hook\E/$hook\n$model/ or die 'preview model hook';
   save("$tmp/preview_timing.cpp",$cpu);
   run($ENV{CXX}||'c++','-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,"$tmp/preview_timing.cpp",$obj,'-o',"$tmp/preview_timing");
   run("$tmp/preview_timing","$tmp/$n.bin",'800','--no-audio','--released-inputs','--raw-lines','264');
}

# The score borrows only the unused final eight stream bytes. Its first176
# gameplay lines must remain identical to the same independent object model.
for my$order(qw(below above)){
   my$n="score_$order";my$s=slurp("$repo/test/fixtures/layers/$n.c26");
   $s=~s#include "score_sprites.c26"#include "$repo/test/fixtures/layers/score_sprites.c26"# or die 'score assets';
     my$b=build($n,$s);$b=~/ram\s+used=54 bytes.*objects=52 bytes hardware-stack=2 bytes/s or die 'score RAM budget';
   my$c={lines=>($order eq'below'?176:172),seam=>64,ys=>[38,38,34,34,33],hs=>[7,7,5,7,3]};
   $c->{xs}=[20,100,50,110,80]if$order eq'above';
   my$cpu=$timing;
   $cpu=~s/layers_pf != 768/layers_pf != 704/ or die 'score PF count';
   $cpu=~s/layers_visible && \(reg == 14/layers_visible \&\& virtual_cycles-layers_start < 176*76 \&\& (reg == 14/ or die 'score PF region';
   $cpu=~s/layers_visible && reg >= 27/layers_visible \&\& virtual_cycles-layers_start < 176*76 \&\& reg >= 27/ or die 'score object region';
   if($order eq'above'){
      my$above_hook=<<'CPP';
      static bool layers_visible=false;
       static unsigned layers_pf=0, layers_stage=0, layers_resp=0, layers_boundary=~0u;
      static uint64_t layers_start=0, layers_frame_start=0;
      if (!(event.address & 0x1080)) {
         const unsigned reg=event.address & 63;
         if (reg==0 && (event.value & 2)) { layers_stage=0; }
         if (layers_stage==1 && reg>=16 && reg<=20 && virtual_cycles-layers_frame_start>=12*76) {
            const unsigned index=reg-16, x=peek_memory(LAYERS_X_BASE+index);
            const uint64_t line=(virtual_cycles-layers_frame_start+3)/76;
            if (line!=17-index || virtual_cycles%76!=23+5*(x/15)) {
               std::fprintf(stderr,"score-above RESP position/phase mismatch\n"); std::exit(1);
            }
            ++layers_resp;
         }
         if (reg==1) {
            if (event.value & 2) {
               if (layers_stage==1 && virtual_cycles-layers_frame_start!=12*76+10) {
                  std::fprintf(stderr,"score-above score return/blanking phase mismatch\n"); std::exit(1);
               }
               if (layers_visible && (layers_pf!=688 || virtual_cycles-layers_start!=172*76+2)) {
                  std::fprintf(stderr,"score-above gameplay extent/count mismatch\n"); std::exit(1);
               }
               layers_visible=false;
            } else {
               ++layers_stage;
               if (layers_stage==1) { layers_frame_start=virtual_cycles; layers_resp=0; }
               if (layers_stage==2) {
                  if (virtual_cycles-layers_frame_start!=20*76 || layers_resp!=5) {
                     std::fprintf(stderr,"score-above positioning deadline mismatch\n"); std::exit(1);
                  }
                   layers_visible=true; layers_pf=0; layers_boundary=~0u; layers_start=virtual_cycles;
               }
            }
          } else if (layers_visible && reg==9) {
             layers_boundary=(virtual_cycles-layers_start+3)/76;
          } else if (layers_visible && (reg==14 || reg==15)) {
            static const unsigned regs[]={14,15,15,14};
             static const unsigned even[]={18,33,48,51}, odd[]={19,24,48,53};
            const unsigned line=layers_pf/4, slot=layers_pf++%4;
            unsigned phase=(line&1)?odd[slot]:even[slot];
             if (!(line&1) && !slot && line==layers_boundary) phase=23;
             if (!line && !slot) phase=8;
            const unsigned raster=(virtual_cycles-layers_start+3)/76;
             const unsigned expected_line=line;
            if (reg!=regs[slot] || virtual_cycles%76!=phase || raster!=expected_line) {
               std::fprintf(stderr,"score-above gameplay PF deadline mismatch\n"); std::exit(1);
            }
         } else if (layers_visible && reg>=27 && reg<=31) {
             static const unsigned phases[]={13,3,3,14,9};
             if (virtual_cycles%76!=phases[reg-27]) {
               std::fprintf(stderr,"score-above object deadline mismatch\n"); std::exit(1);
            }
         }
      }
CPP
      my$xbase=address($n,'layers_object_x');$above_hook=~s/LAYERS_X_BASE/$xbase/g;
      $cpu=$timing;$cpu=~s/\Q$hook\E/$above_hook/ or die 'score-above hook';
   }
   save("$tmp/score_timing.cpp",$cpu);
   run($ENV{CXX}||'c++','-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,"$tmp/score_timing.cpp",$obj,'-o',"$tmp/score_timing");
   my@expect=event_expect($n,$c);my$a=address($n,'score_glyphs');
   for my$entry([0,'high',1],[2,'low',2],[4,'high',3],[6,'low',4]){
      my($offset,$table,$digit)=@$entry;my$ptr=address($n,"vcs_two_plus_two_font_$table")+$digit*8;
      push@expect,'--expect-memory',$a+$offset,$ptr&255,'--expect-memory',$a+1+$offset,$ptr>>8;
   }
   run("$tmp/score_timing","$tmp/$n.bin",'420','--no-audio','--released-inputs','--raw-lines','264',@expect);
   if($order eq'above'){
      for my$positions([0,0,0,0,0],[119,119,119,119,119],[0,119,1,118,60]){
         my$alt=$s;for my$i(0..4){$alt=~s/(layers_object_x\[$i\]:=)\d+;/$1$positions->[$i];/ or die 'position proof';}
         my$variant='visible_intro_'.join('_',@$positions);build($variant,$alt);
         address($variant,'layers_object_x')==address($n,'layers_object_x')or die 'position proof RAM layout changed';
         run("$tmp/score_timing","$tmp/$variant.bin",'420','--no-audio','--released-inputs','--raw-lines','264');
      }
      for my$players([0,0],[5,7],[255,255]){
         my$alt=$s;for my$p(0..1){$alt=~s/(layers_player${p}_y:=)38;/$1$players->[$p];/ or die 'priming proof';}
         my$variant='visible_prime_'.join('_',@$players);build($variant,$alt);
         run("$tmp/score_timing","$tmp/$variant.bin",'420','--no-audio','--released-inputs','--raw-lines','264');
      }
   }
   my$image=capture($n)->[0];my$game_origin=$first+($order eq'above'?20:0);
   logical_image($image,$c,$game_origin,1);
   my@font=(
      [7,5,5,5,5,5,5,7],[2,6,2,2,2,2,2,7],[7,1,1,7,4,4,4,7],
      [7,1,1,7,1,1,1,7],[5,5,5,7,1,1,1,1],[7,4,4,7,1,1,1,7],
      [7,4,4,7,5,5,5,7],[7,1,1,2,2,4,4,4],[7,5,5,7,5,5,5,7],[7,5,5,7,1,1,1,7]);
   my$score_image=sub{my($image,$left,$right,$placement)=@_;$placement//=[32,96,14,14];
   for my$line(0..($order eq'below'?15:19)){my$want="\0"x($w*3);
      if($line>=4&&$line<12){my$r=$line-4;
         for my$field([$placement->[0],int($left/10),$left%10,$placement->[2]],
                      [$placement->[1],int($right/10),$right%10,$placement->[3]]){my($x,$tens,$ones,$color)=@$field;
            my$packed=($font[$tens][$r]<<5)|($font[$ones][$r]<<1);
            for my$bit(0..7){paint(\$want,$x+$bit*2,2,$rgb{$color})if$packed&(128>>$bit);}
         }
      }
      my$score_origin=$first+($order eq'below'?176:0);
      my$got=substr($image->[2],($score_origin+$line)*$w*3,$w*3);
      if($got ne$want){for my$x(0..$w-1){substr($got,$x*3,3)eq substr($want,$x*3,3)or die"score $order RGB mismatch line=$line x=$x\n";}}
   }
   };
   $score_image->($image,12,34);
   for my$profile([0,99,1,2],[56,78,2,3],[90,12,3,1],[45,67,1,3,0,144,46,78],[89,0,2,0,64,32,78,46]){
      my($left,$right,$frame0,$frame1)=@$profile;my$alt=$s;
      $alt=~s/score_left_score:=12;/score_left_score:=$left;/ or die 'left score';
      $alt=~s/score_right_score:=34;/score_right_score:=$right;/ or die 'right score';
      my$placement;
      if(@$profile>4){$placement=[@$profile[4..7]];my($lx,$rx,$lc,$rc)=@$placement;
         $alt=~s/as score(?: \(gameplay_scanlines:=172\))?\n/as score (gameplay_scanlines:=$c->{lines},left_x:=$lx,right_x:=$rx,left_color:=$lc,right_color:=$rc)\n/ or die 'score placement';
      }
      for my$p(0..1){my$off=$profile->[2+$p]*8;
         $alt=~s/layers_player${p}_graphics:=p$p;/asm lda #<{p$p + $off}; asm sta.z layers_player${p}_graphics; asm lda #>{p$p + $off}; asm sta.z layers_player${p}_graphics + 1;/ or die 'score sprite frame';
      }
      my$variant="${n}_${left}_$right";build($variant,$alt);
      run("$tmp/score_timing","$tmp/$variant.bin",'420','--no-audio','--released-inputs','--raw-lines','264');
      my$rgb=capture($variant)->[0];my$pose={%$c,frames=>[$frame0,$frame1]};
      logical_image($rgb,$pose,$game_origin,1);$score_image->($rgb,$left,$right,$placement);
   }
   {
      my$alt="alias LAYERS_MOTION\n".$s;
      $alt=~s#include "score_motion.c26"#include "$repo/test/fixtures/layers/score_motion.c26"# or die 'score motion asset';
      my$variant="${n}_motion";my$budget=build($variant,$alt);
        $budget=~/ram\s+used=55 bytes.*objects=53 bytes hardware-stack=2 bytes/s or die 'moving score RAM budget';
      address($variant,'layers_object_x')==address($n,'layers_object_x')or die 'moving score RAM layout changed';
      run("$tmp/score_timing","$tmp/$variant.bin",'420','--no-audio','--released-inputs','--raw-lines','264');
      my$images=capture($variant,40);my@left;
      for my$v(0..99){push@left,$v if eval{$score_image->($images->[0],$v,($v+22)%100);1};}
      @left==1 or die 'moving score value is not uniquely identifiable';
      my$pose_for=sub{my$phase=shift;my$y=30+($phase&15);
         return{%$c,ys=>[$y,$y,$y-4,$y-4,$y-5],frames=>[$phase&3,($phase+1)&3]};
      };
      my@phases;
      for my$phase(0..399){next unless(12+$phase)%100==$left[0];
         push@phases,$phase if eval{logical_image($images->[0],$pose_for->($phase),$game_origin,0);1};
      }
      @phases==1 or die 'moving score pose/value phase is not unique';my$phase=$phases[0];
      my%animation;my%values;my$crossed=0;
      for my$rgb(@$images){my$pose=$pose_for->($phase);my$witness=($phase&15)==8;
         logical_image($rgb,$pose,$game_origin,$witness);
         $score_image->($rgb,(12+$phase)%100,(34+$phase)%100);
         $crossed=1 if$witness;$animation{$phase&3}=1;$values{(12+$phase)%100}=1;++$phase;
      }
      $crossed&&keys(%animation)==4&&keys(%values)==40 or die 'moving score lacks seam/four-frame/runtime-value coverage';
   }
   {
      my$bad=slurp("$repo/libraries/vcs/layers/score.c26");
       $bad=~s/sta.ay TEMPLATE_glyphs,y/sta.ay TEMPLATE_glyphs + 1,y/g or die 'score pointer mutation';
       save("$tmp/wrong_score_pointer.c26",$bad);
       my$alt=$s;$alt=~s!layers/score.c26!$tmp/wrong_score_pointer.c26!;
       my$variant="${n}_wrong_pointer";build($variant,$alt);
      eval{run("$tmp/score_timing","$tmp/$variant.bin",'200','--no-audio','--released-inputs','--raw-lines','264',@expect);1}
          and die 'wrong score pointer bytes were accepted';
       $@=~/memory .*expected/ or die 'score pointer mutation rejected for wrong reason';
   }
   for my$height(0,1,175,178,192){
      my$alt=$s;
      if($order eq'above'){$alt=~s/gameplay_scanlines:=172/gameplay_scanlines:=$height/;}
      else{$alt=~s/as score\n/as score (gameplay_scanlines:=$height)\n/;}
      eval{build("${n}_height_$height",$alt);1}and die "invalid score gameplay height $height accepted";
   }
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
for my$row('0x00000000','0xffffffff','0x00700000') {for my$height(4,6){
   my$c={%{$cases[0]},seam=>$height};my$s=source($c);
   $s=~s/playfield_row:=0x[0-9a-f]+/playfield_row:=$row/g;
   $s=~s/pf_color:=0x[0-9a-f]+/pf_color:=14/g;
   $s=~s/bk_color:=0x[0-9a-f]+/bk_color:=0/g;
   my$n="constant_fold_${row}_$height";build($n,$s);
   run("$tmp/timing","$tmp/$n.bin",'420','--no-audio','--released-inputs','--raw-lines','264');
}}
for my$height(0,1,3,255,256,-2){my$s=source($cases[0]);$s=~s/number_of_scanlines:=6/number_of_scanlines:=$height/;
   eval{build("bad_height_$height",$s);1}and die"invalid height $height accepted";
}
for my$mutation(['pf_color:=0x46','pf_color:=256'],['bk_color:=0xc2','bk_color:=-1']){
   my$s=source($cases[0]);$s=~s/\Q$mutation->[0]\E/$mutation->[1]/ or die 'colour mutation';
   eval{build('bad_colour',$s);1}and die 'invalid colour accepted';
}
{
   my$bad=slurp("$repo/libraries/vcs/layers/all_five_section.c26");
   $bad=~s/asm stx GRP0;/asm nop; asm stx GRP0;/ or die 'phase mutation';save("$tmp/wrong_phase_component.c26",$bad);
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
