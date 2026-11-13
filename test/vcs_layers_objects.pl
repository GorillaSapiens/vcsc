#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 180
# expectstdout: vcs_layers_objects ok
# expectexit: 0
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use IPC::Open3;
use Symbol qw(gensym);
my($repo,$tmp)=@ARGV;$repo=abs_path($repo);make_path($tmp);$tmp=abs_path($tmp);
sub readfile {open my$f,'<:raw',$_[0] or die$!;local$/;return <$f>;}
sub save {open my$f,'>:raw',$_[0] or die$!;print $f $_[1];}
sub run {
   my(@cmd)=@_;my$err=gensym;my$p=open3(my$i,my$o,$err,@cmd);close$i;
   local$/;my$out=<$o>//'';my$e=<$err>//'';waitpid($p,0);
   $?==0 or die "@cmd\n$out$e";return$out;
}
my$mos="$repo/simulator/mos6502";my$obj=-f"$mos/mos6502.o"?"$mos/mos6502.o":"$mos/mos6502.cpp";
run($ENV{CXX}||'c++','-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,
   "$repo/test/vcs_frame_timing.cpp",$obj,'-o',"$tmp/timing");
my@cases=(
   [[0,0,0],[0,0,0]], [[6,18,94],[7,7,7]],
   [[250,255,200],[255,3,220]], [[95,96,97],[0,255,17]],
   [[15,31,47],[1,8,15]],
);
sub mask_bytes {
   my($ys,$hs)=@_;my@bits;
   # Direct interval oracle, not the component's byte/range-building algorithm.
   for my$o(0..2){
      my$last=($ys->[$o]+($o==0?2:1))&255;my$first=($last-$hs->[$o])&255;
      for my$t(1..96){$bits[$o][$t]=($first<=$last?($t>=$first&&$t<=$last):($t>=$first||$t<=$last))?1:0;}
   }
   my@bytes;
   for my$r(0..11){my@v;
      for my$o(0..2){my$b=0;$b|=$bits[$o][$r*8+$_+1]<<$_ for 0..7;push@v,$b;}
      push@bytes,map{($_<<1)&255}@v;
      push@bytes,(($v[0]>>7)<<1)|(($v[1]>>7)<<2)|(($v[2]>>7)<<3);
   }
   return@bytes;
}
for my$case(0..$#cases){
   my($ys,$hs)=@{$cases[$case]};my@bytes=mask_bytes($ys,$hs);
   my$p0=($case*17)&255;my$p1=($case*29)&255;my$h0=$case&7;my$h1=7-$h0;
   my$src=<<'C26';
include "vcs.c26"
include "frame_ntsc.c26"
include "layers/all_five_objects.c26"
instantiate "layers/section.c26" as blank (number_of_scanlines:=192)
page const uint8_t glyph[8] := {0,1,2,3,4,5,6,7};
uint8_t failed;
uint8_t i;
C26
   $src.='const uint8_t expected[48] := {'.join(',',@bytes)."};\nvoid main(void) {\n";
   $src.="failed:=0; VBLANK:=2; PF0:=0; CTRLPF:=1;\nlayers_player0_y:=$p0; layers_player1_y:=$p1; layers_player0_height:=$h0; layers_player1_height:=$h1;\n";
   for my$o(0..2){my$n=(qw(ball missile1 missile0))[$o];$src.="layers_${n}_y:=$ys->[$o]; layers_${n}_height:=$hs->[$o];\n";}
   $src.="layers_player0_graphics:=glyph; layers_player1_graphics:=glyph;\n";
   $src.="layers_object_x[0]:=0; layers_object_x[1]:=13; layers_object_x[2]:=14; layers_object_x[3]:=150; layers_object_x[4]:=159;\n";
   # Validation runs outside the timed frame; it is not renderer work.
   $src.="for(i:=0;i<48;i++){layers_object_masks[i]:=255;} layers_prepare_vertical(); layers_prepare_vertical();\n";
   $src.="for(i:=0;i<48;i++){if(layers_object_masks[i]!=expected[i]){failed:=1;}}\n";
   for my$v(['player0_counter',$p0],['player1_counter',($p1+1)&255],['player0_limit',$h0+1],['player1_limit',$h1+1],['ball_bits',$bytes[0]],['missile1_bits',$bytes[1]],['missile0_bits',$bytes[2]],['player0_y',$p0],['player1_y',$p1],['player0_height',$h0],['player1_height',$h1]){
      $src.="if(layers_$v->[0]!=$v->[1]){failed:=1;}\n";
   }
   for my$o(0..2){my$n=(qw(ball missile1 missile0))[$o];$src.="if(layers_${n}_y!=$ys->[$o] || layers_${n}_height!=$hs->[$o]){failed:=1;}\n";}
   my@x=(0,13,14,150,159);$src.="if(layers_object_x[$_]!=$x[$_]){failed:=1;}\n" for 0..4;
   for my$p(0..1){
      my$limit=($p?$h1:$h0)+1;
      my%seen;
      for my$before(0,1,$limit,$limit+1,128,255){
         next if $seen{$before}++;
         my$after=($before-1)&255;
         my$wrong_carry=$after>=$limit?'bcc':'bcs';
         my$tag="p${p}_$before";
         $src.="layers_player${p}_counter:=$before;\n";
         $src.="asm lda #90; asm ldx #165; layers_step_player$p();\n";
         $src.="asm $wrong_carry.same \@bad_$tag; asm cmp #90; asm bne.same \@bad_$tag; asm cpx #165; asm bne.same \@bad_$tag; asm cpy #$after; asm bne.same \@bad_$tag; asm jmp \@checked_$tag;\n";
         $src.="asm \@bad_$tag:; failed:=1; asm \@checked_$tag:;\n";
         $src.="if(layers_player${p}_counter!=$after){failed:=1;}\n";
      }
   }
   $src.="while(1){vcs_ntsc_vsync();vcs_ntsc_begin_vblank();layers_prepare_vertical();vcs_ntsc_end_vblank();blank_draw();vcs_ntsc_begin_overscan();vcs_ntsc_end_overscan();}}\n";
   for my$bad(0,($case==1?1:()),($case==2?2:())){
      my$name="objects_${case}_$bad";my$s=$src;
      if($bad){
         my$c=readfile("$repo/libraries/vcs/layers/all_five_objects.c26");
         if($bad==1){$c=~s/asm adc #2;/asm adc #1;/ or die 'Ball bias mutation';}
         else{$c=~s/asm dey;/asm nop;/ or die 'shared step mutation';}
         save("$tmp/bad_owner.c26",$c);$s=~s!layers/all_five_objects.c26!$tmp/bad_owner.c26!;
      }
      save("$tmp/$name.c26",$s);
      my$build=run("$repo/driver/vcsc",'-I',"$repo/libraries/vcs","$tmp/$name.c26",'-o',"$tmp/$name.bin");
      my$map=readfile("$tmp/$name.map");my$state_bytes=0;
      $state_bytes+=hex($1) while $map=~/BSS\.__vcsc_object\$layers_\w+\s+run=\$[0-9A-Fa-f]+ size=\$([0-9A-Fa-f]+)/g;
       $state_bytes==74 or die "shared state is $state_bytes bytes, not 74";
      # The diagnostic's C expressions/loop also need six compiler
      # scratch/activation bytes, in addition to its failed/i variables.
       $build=~/objects=82 bytes hardware-stack=6 bytes/ or die "diagnostic RAM/stack budget\n$build";
      my$sym=readfile("$tmp/$name.sym");$sym=~/^failed\s+([0-9a-fA-F]{4})\s*$/m or die 'failed symbol';my$a=hex$1;
      $sym=~/^glyph\s+([0-9a-fA-F]{4})\s*$/m or die 'glyph symbol';my$glyph=hex$1;my@pointers;
      for my$p(qw(layers_player0_graphics layers_player1_graphics)){
         $sym=~/^\Q$p\E\s+([0-9a-fA-F]{4})\s*$/m or die "pointer symbol $p";my$address=hex$1;
         push@pointers,'--expect-memory',$address,$glyph&255,'--expect-memory',$address+1,$glyph>>8;
      }
      run("$tmp/timing","$tmp/$name.bin",'200','--no-audio','--released-inputs','--raw-lines','264','--expect-memory',$a,$bad?1:0,@pointers);
   }
}
print "vcs_layers_objects ok\n";
