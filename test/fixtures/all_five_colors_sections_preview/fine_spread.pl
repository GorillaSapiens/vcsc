# Private sparse-phase feasibility transformation, not a user-facing generator.
use strict;
use warnings;
return sub {
   my($repo,$heights,$pal,$bad_feed,$rts,$uniform)=@_;
   my$c=main::slurp("$repo/libraries/vcs/renderers/all_five_player_color_192/all_five_player_color_192.c26");
   my$prime=join('',map{"   asm lda.a TEMPLATE_playfield + ".(4+$_).";\n   asm sta.z TEMPLATE_row_cache + ".(7+$_).";\n"}0..3);
   $prime.=join('',map{"   asm lda.z TEMPLATE_object_masks + ".(4+$_).";\n   asm sta.z TEMPLATE_row_cache + ".(11+$_).";\n"}0..2);
   $c =~ s/(   asm lda.z TEMPLATE_player0_y;)/$prime$1/ or die 'fine prime';
   my$decl=($rts?"uint8_t TEMPLATE_packed_row;\n":"uint8_t TEMPLATE_packed_route[2];\n")."uint8_t TEMPLATE_saved_s;\nuint8_t TEMPLATE_packed_p1_zero;\n";
   for my$p(qw(even odd)){for my$i(0..3){$decl.="const uint8_t TEMPLATE_${p}_pf$i := TEMPLATE_playfield[".(($p eq 'odd'?4:0)+$i)."];\n";}}
   my$at=sub{my$l=shift;my$end=0;for my$n(0..7){$end+=$heights->[$n];return$n%scalar(@$pal) if$l<$end;}die 'fine extent';};
   for my$which(0,1){for my$plane(0..($rts?1:0)){
      my@v;for my$r(0..11){push@v,map{$pal->[$at->($r*16+$plane*8+$_*2)][$which]}0..3;}
      $decl.='page const uint8_t TEMPLATE_sections_'.($which?'bk':'pf').$plane.'[48] := {'.join(',',@v)."};\n";
   }}
   $c=$decl.$c;
   for my$side(qw(A B)){
      my$b=$side eq 'A'?0:7;my$next=$side eq 'A'?7:0;my$p=$side eq 'A'?'even':'odd';my$m0=$b+6;my$m1=$b+5;my$bl=$b+4;
      for my$n(1..4){
         my$nn=$n+1;my($pair)=$c =~ /(   asm \@TEMPLATE_${side}_u$n:;.*?)(?=   \/\/ $side pair $nn:)/s;
         defined$pair or die 'fine pair';my$old=$pair;my$slot=$next+$n-1;
         if(!$rts&&($n==2||$n==4)){
            my$plane=$n==2?'lo':'hi';my$byte=$n==2?0:1;
            $pair =~ s/   asm lda.ax TEMPLATE_playfield \+ \d,x;\n   asm sta.z TEMPLATE_row_cache \+ $slot;/   asm lda.ax \@TEMPLATE_fine_route_$plane,x;\n   asm sta.z TEMPLATE_packed_route + $byte;/ or die 'fine route prefetch';
         }else{
            my$plane=$n==4?1:0;my$index=$n==4?0:$n;
            for my$i(0..3){my$s=$b+$i;$pair =~ s/   asm lda\.(?:z|a) TEMPLATE_row_cache \+ $s;\n   asm sta PF[12];/'   PF'.(($i==0||$i==3)?1:2).' := TEMPLATE_'.$p.'_pf'.$i.';'/ge;}
            $pair =~ s/   asm lda.ax TEMPLATE_playfield \+ \d,x;\n   asm sta.z TEMPLATE_row_cache \+ $slot;/   asm dec.z TEMPLATE_object_masks + 0;/ or die 'fine early P0';
            $pair =~ s/(   asm cpy.z TEMPLATE_player1_height;)/   asm lsr.z TEMPLATE_row_cache + $m0;\n$1/ or die 'fine P1 carry';
            $pair =~ s/(   asm sta ENAM1;.*?)   asm lsr.z TEMPLATE_row_cache \+ $m0;\n/$1/s or die 'fine old M0 shift';
            $pair =~ s/(   asm ldy.z TEMPLATE_object_masks \+ 0;)\n   asm dey;\n   asm sty.z TEMPLATE_object_masks \+ 0;/$1/ or die 'fine old P0';
            $pair =~ s/   asm sta ENABL;/   asm sta.a ENABL;/ or die 'fine P1 phase';
            $pair =~ s/(   asm sta ENAM1;)\n   asm lsr.z TEMPLATE_row_cache \+ $m1;/$1\n   asm lda.ax TEMPLATE_sections_pf$plane + $index,x;\n   asm sta COLUPF;\n   asm lda.ax TEMPLATE_sections_bk$plane + $index,x;\n   asm sta COLUBK;/ or die 'fine palette';
            $pair =~ s/(   asm sta COLUBK;.*?   PF2 := TEMPLATE_${p}_pf1;)/$1\n   asm lsr.z TEMPLATE_row_cache + $m1;/s or die 'fine M1 shift';
            my$r=$b+2;
            $pair =~ s/   asm cpy.z TEMPLATE_player0_height;\n   PF2 := TEMPLATE_${p}_pf2;/   asm nop;\n   asm lda.z TEMPLATE_row_cache + $r;\n   asm sta PF2;\n   asm cpy.a TEMPLATE_player0_height;/ or die 'fine P0 phase';
            $pair =~ s/(   asm lsr.z TEMPLATE_row_cache \+ $bl;)\n   asm nop;/$1/ or die 'fine normal tail';
         }
         $c =~ s/\Q$old\E/$pair/ or die 'fine replace pair';
      }
      # This shift is dead: pair 7 obtains BL from the packed ROM byte, not
      # the exhausted BL cache. NOP + indirect JMP has the same seven cycles.
      if($rts){
         my($six)=$c =~ /(   asm \@TEMPLATE_${side}_u6:;.*?)(?=   \/\/ $side pair 7)/s;
         defined$six or die 'RTS pair6';my$old=$six;
         for my$i(0..2){my$slot=$b+$i;$six =~ s/   asm lda.z TEMPLATE_row_cache \+ $slot;\n   asm sta PF[12];/'   PF'.($i==1||$i==2?2:1).' := TEMPLATE_'.$p.'_pf'.$i.';'/e or die 'RTS pair6 PF';}
         $six =~ s/(   asm cpy.z TEMPLATE_player1_height;)/$1\n   asm stx.z TEMPLATE_packed_row;/ or die 'RTS row index';
         $c =~ s/\Q$old\E/$six/ or die 'RTS pair6 replace';
         $c =~ s/   asm lsr.z TEMPLATE_row_cache \+ $bl;\n   asm nop;\n(   \/\/ $side pair 7)/   asm rts;\n$1/ or die 'RTS packed dispatch';
      }else{
         $c =~ s/   asm lsr.z TEMPLATE_row_cache \+ $bl;\n   asm nop;\n(   \/\/ $side pair 7)/   asm nop;\n   asm jmp (TEMPLATE_packed_route);\n$1/ or die 'fine packed dispatch';
      }
   }
   # Extract the original boundary tails before generating palette variants.
   my($a)=$c =~ /(   asm \@TEMPLATE_A_boundary:;.*?)(?=   \/\/ B pair 1:)/s;
   my($b)=$c =~ /(   asm \@TEMPLATE_B_boundary:;.*?)(?=\n\})/s;
   defined$a&&defined$b or die 'fine boundaries';
   $a =~ s/   asm nop;\n   asm bit.z \$00;/   asm nop;\n   asm sty.z TEMPLATE_object_masks + 0;/ or die 'fine A P0 store';
   $a =~ s/   asm nop;\n   asm bit.z \$00;\n\z/   asm nop;\n   asm jmp \@TEMPLATE_B_u1;\n/ or die 'fine A row exit';
   $b =~ s/   asm lda.z TEMPLATE_row_cache \+ 7;\n   asm sta PF1;/   PF1 := TEMPLATE_odd_pf0;/ or die 'fine B left1';
   $b =~ s/   asm lda.z TEMPLATE_row_cache \+ 8;\n   asm sta PF2;/   PF2 := TEMPLATE_odd_pf1;/ or die 'fine B left2';
   $b =~ s/(   asm cpx #44;)/   asm sty.z TEMPLATE_object_masks + 0;\n$1/ or die 'fine B P0 store';
   $b =~ s/   asm lsr.a TEMPLATE_row_cache \+ 4;/   asm lsr.z TEMPLATE_row_cache + 4;/ or die 'fine B shift';
   my($close)=$b =~ /(   asm lda.z TEMPLATE_row_cache \+ 9;\n   asm sta PF2;\n   asm lda.z TEMPLATE_row_cache \+ 10;\n   asm sta PF1;\n   asm sta WSYNC;)/s;
   defined$close or die 'fine close';
   $b =~ s/   asm \@TEMPLATE_terminal_boundary:;.*\z/   asm \@TEMPLATE_terminal_boundary:;\n   asm ldx.z TEMPLATE_saved_s;\n   asm txs;\n   asm bit.z \$00;\n   asm jmp \@TEMPLATE_fine_close;\n/s or die 'fine terminal stub';
   # A already has a direct B jump; both row exits update the row-X stack.
   $a =~ s/(   asm inx;)\n   asm nop;\n   asm jmp/$1\n   asm txs;\n   asm jmp/ or die 'fine A row stack';
   $b =~ s/(   asm inx;)\n   asm nop;\n   asm jmp/$1\n   asm txs;\n   asm jmp/ or die 'fine B row stack';
   # Packed GRP0 is committed in the shared boundary during HBLANK. Absorb
   # its three cycles in early PF/counter padding, without moving right PF.
   $a =~ s/   asm nop;\n   asm sty.z TEMPLATE_object_masks \+ 0;/   asm sty.z TEMPLATE_object_masks + 0;/ or die 'fine shared A pad';
   $a =~ s/   asm lda.z TEMPLATE_row_cache \+ 1;\n   asm sta PF2;/   PF2 := TEMPLATE_even_pf1;/ or die 'fine shared A left';
   $b =~ s/   asm cpx #44;\n   asm beq.same \@TEMPLATE_terminal_boundary;\n// or die 'fine shared B check';
   $b =~ s/   asm lsr.z TEMPLATE_row_cache \+ 4;/   asm lsr.a TEMPLATE_row_cache + 4;/ or die 'fine shared B pad';
   $b =~ s/   asm \@TEMPLATE_terminal_boundary:;.*\z//s or die 'fine shared B terminal remove';
   my$terminal="   asm \@TEMPLATE_fine_terminal:;\n   asm sta GRP0;\n   asm lda.z TEMPLATE_row_cache + 13;\n   asm sta ENAM0;\n   asm lda.z TEMPLATE_row_cache + 4;\n   asm sta ENABL;\n   asm lda.z TEMPLATE_row_cache + 7;\n   asm sta PF1;\n   PF2 := TEMPLATE_odd_pf1;\n   asm sty.z TEMPLATE_object_masks + 0;\n   asm ldx.z TEMPLATE_saved_s;\n   asm txs;\n   asm nop;\n   asm nop;\n";
   $a =~ s/(   asm \@TEMPLATE_A_boundary:;)/$1\n   asm sta GRP0;/;
   $b =~ s/(   asm \@TEMPLATE_B_boundary:;)/$1\n   asm sta GRP0;/;
   # Keep compact anchors as palette counts change. These legal phase ranges
   # are for the fixed 667-byte normal and 126-byte packed bodies; final-link
   # .same contracts remain authoritative, not this packing preference.
   my$choose=sub{
      my($cursor,$ranges)=@_;
      for my$pad(0..255){my$p=($cursor+$pad)%256;return$p if grep{$p>=$_->[0]&&$p<=$_->[1]}@$ranges;}
      die 'fine phase packing';
   };
   my@normal_ranges=$rts?([6,34],[40,60],[66,82],[98,108],[124,132],[148,149],[155,175],[181,197],[213,223],[239,246]):([0,5],[21,41],[47,73],[79,82],[98,111],[130,150],[168,182],[188,197],[213,220],[226,229],[245,255]);
   my@packed_ranges=$rts?([0,131],[148,194]):([0,132],[151,196]);
   my$normal_size=$rts?687:667;my$packed_size=$rts?127:126;my$normal_a_phase=$rts?0x94:0x62;
   my($normal_b_phase,$boundary_a_phase,$boundary_b_phase,$terminal_phase);
   for my$side(qw(A B)){
      my$base=$side eq 'A'?0:7;my$p=$side eq 'A'?'even':'odd';my$m0=$base+6;
      my($packed)=$c =~ /(   asm \@TEMPLATE_${side}_u7:;.*?)(?=   asm \@TEMPLATE_${side}_boundary:;)/s;
      defined$packed or die 'fine packed';my$old=$packed;
      for my$i(0..3){my$s=$base+$i;$packed =~ s/   asm lda\.(?:z|a) TEMPLATE_row_cache \+ $s;\n   asm sta PF[12];/'   PF'.(($i==0||$i==3)?1:2).' := TEMPLATE_'.$p.'_pf'.$i.';'/ge;}
      $packed =~ s/   asm ldy.zx TEMPLATE_object_masks \+ 6,x;\n// or die 'fine move M0';
      $packed =~ s/(   asm lda.zx TEMPLATE_object_masks \+ 3,x;)/   asm ldy.zx TEMPLATE_object_masks + 6,x;\n$1/ or die 'fine early M0';
      $packed =~ s/(   asm sta ENABL;\n   asm lsr;)/$1\n   asm tax;/ or die 'fine stage M1';
      $packed =~ s/   asm sta.z TEMPLATE_row_cache \+ $m0;/   asm sta.a TEMPLATE_row_cache + $m0;/ or die 'fine packed phase';
      $packed =~ s/   asm sta COLUP0;/   asm sta.a COLUP0;/ or die 'RTS packed entry phase' if$rts;
      my$r1=$base+3;my$r2=$base+2;
      $packed =~ s/   PF1 := TEMPLATE_${p}_pf3;/   asm lda.z TEMPLATE_row_cache + $r1;\n   asm sta PF1;/ or die 'fine packed right1';
      my($prefix,$active,$zero,$tail)=$packed =~ /\A(.*?   asm bcs.same \@TEMPLATE_${side}_u7_p1_zero;\n)(.*?)   asm jmp \@TEMPLATE_${side}_u7_p1_ready;\n   asm \@TEMPLATE_${side}_u7_p1_zero:;\n(.*?)   asm bit.z \$00;\n   asm \@TEMPLATE_${side}_u7_p1_ready:;\n(.*)\z/s;
      defined$tail or die 'fine packed split';
      $active =~ s/(   asm sta COLUP1;)/$1\n   asm stx ENAM1;/ or die 'fine active M1';
      $zero =~ s/   asm ldy #0;\n   asm lda.ay TEMPLATE_player1_colors,y;/   asm lda.z TEMPLATE_packed_p1_zero;/ or die 'fine zero colour';
      $zero =~ s/(   asm sta COLUP1;)/$1\n   asm stx ENAM1;/ or die 'fine zero M1';
      $zero.="   asm jmp \@TEMPLATE_${side}_u7_p1_ready;\n";
      $tail =~ s/   asm lda.zx TEMPLATE_object_masks \+ 3,x;\n   asm lsr;\n   asm sta ENAM1;/   COLUBK := FINE_BK;\n   COLUPF := FINE_PF;/ or die 'fine immediate palette';
      $tail =~ s/   asm ldy.z TEMPLATE_object_masks \+ 0;/   asm ldy.a TEMPLATE_object_masks + 0;/ or die 'fine packed P0 load';
      $tail =~ s/   PF2 := TEMPLATE_${p}_pf2;/   asm lda.a TEMPLATE_row_cache + $r2;\n   asm sta PF2;/ or die 'fine packed right2';
      my$restore=$rts?'ldx.z TEMPLATE_packed_row':'tsx';
      $tail =~ s/   PF1 := TEMPLATE_${p}_pf3;/   asm lda.z TEMPLATE_row_cache + $r1;\n   asm sta.a PF1;\n   asm $restore;/ or die 'fine packed row restore';
      $tail =~ s/   asm sty.z TEMPLATE_object_masks \+ 0;\n// or die 'fine defer P0';
      $tail =~ s/   asm tay;/   asm nop;/ or die 'fine raw P0';
      if(!$rts){
         $tail =~ s/   asm sta COLUP0;/   asm sta.a COLUP0;/ or die 'fine packed P0 colour phase';
         $tail =~ s/(   asm lda #0;\n)   asm nop;/$1   asm bit.z \$00;/ or die 'fine packed inactive P0 phase';
      }
      $tail =~ s/   asm sta GRP0;/   asm jmp \@TEMPLATE_${side}_boundary;/ or die 'fine packed common exit';
      my%used;for my$row(0..11){next if($row%2==0?'A':'B')ne$side;$used{$row==11?'T':$at->($row*16+14)}=1;}
      my$variants='';my$cursor=($side eq 'A'?$normal_a_phase:$normal_b_phase)+$normal_size;
      for my$key(0..$#$pal,'T'){
         next unless$used{$key};my$n=$key eq 'T'?$at->(190):$key;
         my$phase=$choose->($cursor,\@packed_ranges);$cursor=$phase+$packed_size;
         my$v=sprintf("   asm .align 256, \$%02x;\n",$phase)."   asm \@TEMPLATE_${side}_u7_p1_zero:;\n".$zero.$prefix.$active."   asm \@TEMPLATE_${side}_u7_p1_ready:;\n".$tail;
         $v =~ s/FINE_PF/$pal->[$n][0]/ge;$v =~ s/FINE_BK/$pal->[$n][1]/ge;
         $v =~ s/\@TEMPLATE_${side}_/\@TEMPLATE_fine_${side}_${key}_/g;
         my$target=$key eq 'T'?'fine_terminal':"${side}_boundary";
         $v =~ s/\@TEMPLATE_fine_${side}_${key}_boundary/\@TEMPLATE_$target/g;
         $variants.=$v;
      }
      if($side eq 'A'){$normal_b_phase=$choose->($cursor,\@normal_ranges);}
      else{
         $boundary_a_phase=$choose->($cursor,$rts?[[0,147],[153,203],[214,255]]:[[0,152],[158,205],[216,255]]);
         $boundary_b_phase=$choose->($boundary_a_phase+($rts?120:115),$rts?[[0,147],[153,203],[214,255]]:[[0,151],[157,204],[215,255]]);
         $terminal_phase=($boundary_b_phase+($rts?120:116))%256;
      }
      if($side eq 'A'){$c =~ s/\Q$old\E   asm \@TEMPLATE_A_boundary:;.*?(?=   \/\/ B pair 1:)/$variants/s or die 'fine A variants';}
      else{$c =~ s/\Q$old\E   asm \@TEMPLATE_B_boundary:;.*?(?=\n\})/$variants\n$a\n$b\n$terminal\n   asm \@TEMPLATE_fine_close:;\n$close/s or die 'fine B variants';}
   }
   my$routes=$rts?'':"   asm .align 256, \$00;\n";my$initialize='';my$offset=6;
   for my$plane(qw(lo hi)){
      $routes.="   asm \@TEMPLATE_fine_route_$plane:;\n" if!$rts;
      for my$row(0..11){my$s=$row%2?'B':'A';my$n=$at->($row*16+14);$n=$at->(46) if$bad_feed&&$row==0;my$key=$row==11?'T':$n;
         if($rts){
            next if$plane eq 'hi';
            for my$byte('<','>'){
               # Private proof is inlined into main. The assembler equate is
               # segment-relative; add the real relocated main base explicitly.
               $initialize.="   asm lda #$byte\{main + TEMPLATE_fine_addr_${s}_${key} - 1\};\n   asm sta.z TEMPLATE_row_cache + ".$offset++.";\n";
            }
         }else{
            $routes.=join('',map{'   asm .byte '.($plane eq 'lo'?'<':'>')."\@TEMPLATE_fine_${s}_${key}_u7;\n"}0..3);
         }
      }
   }
   my$a_phase=sprintf('%02x',$normal_a_phase);
   $c =~ s/   asm \.align 256, \$90;/$routes   asm .align 256, \$$a_phase;/ or die 'fine route tables';
   my$b_phase=sprintf('%02x',$normal_b_phase);
   $c =~ s/(   asm \@TEMPLATE_B_u1:;)/   asm .align 256, \$$b_phase;\n$1/ or die 'fine B anchor';
   for my$anchor(['A_boundary',$boundary_a_phase],['B_boundary',$boundary_b_phase],['fine_terminal',$terminal_phase]){
      my($name,$value)=@$anchor;my$phase=sprintf('%02x',$value);
      $c =~ s/(   asm \@TEMPLATE_$name:;)/   asm .align 256, \$$phase;\n$1/ or die 'fine boundary anchor';
   }
   if($rts){
      $c =~ s/(require inline void TEMPLATE_draw\(void\) \{.*?)   asm bit.z \$00;\n   asm bit.z \$00;\n   asm nop;/$1   asm ldx #RTS_STACK_BASE;\n   asm txs;\n   asm ldx #0;\n   asm nop;/s or die 'RTS initial stack';
      # The test PF has two explicit alternating aliases, not twelve arbitrary
      # rows. Reclaim its eight cache lanes for the contiguous return vector.
      $c =~ s/TEMPLATE_row_cache;/TEMPLATE_row_cache + 0;/g;
      my%pf=(0=>['even',0],1=>['even',1],2=>['even',2],3=>['even',3],7=>['odd',0],8=>['odd',1],9=>['odd',2],10=>['odd',3]);
      my$label=0;
      $c =~ s/   asm lda\.(z|a) TEMPLATE_row_cache \+ (\d+);\n   asm sta(\.a)? (PF[12]);/
         my($mode,$slot,$absolute,$reg)=($1,$2,$3,$4);
         if(exists$pf{$slot}){
            my$cycles=($mode eq 'a'?4:3)+($absolute?4:3);my($pattern,$column)=@{$pf{$slot}};
            my@bytes=$uniform?(255,255,255,255):$pattern eq 'even'?(0x81,0x18,0x42,0x24):(0x36,0x81,0x18,0xa5);
            '   asm @TEMPLATE_rts_fold_'.($label++).":;\n   asm lda #".$bytes[$column].";\n".
            ($cycles==6?"   asm sta.a $reg;\n":$cycles==7?"   asm nop;\n   asm sta $reg;\n":"   asm nop;\n   asm sta.a $reg;\n")
         }else{$&}
      /ge;
      my@remap=(6,7,8,9,0,1,2,10,11,12,13,3,4,5);
      $c =~ s/TEMPLATE_row_cache \+ (\d+)\b/'TEMPLATE_row_cache + '.$remap[$1]/ge;
      $c =~ s/uint8_t TEMPLATE_row_cache\[14\]/uint8_t TEMPLATE_row_cache[30]/ or die 'RTS RAM cache';
      $c =~ s/RTS_STACK_BASE/<{TEMPLATE_row_cache + 5}/ or die 'RTS stack base';
      $c =~ s/   asm txs;\n   asm jmp/   asm nop;\n   asm jmp/g;
      # Equates expose offsets without introducing global labels, which would
      # change the assembler scope of the compiler's enclosing loop labels.
      $c =~ s/(   asm \@TEMPLATE_fine_([AB])_([0-7T])_u7:;)/   asm TEMPLATE_fine_addr_${2}_${3} = \@TEMPLATE_fine_${2}_${3}_u7;\n$1/g;
   }else{
      $c =~ s/(   asm \@TEMPLATE_first_p0_ready:;\n   asm sta GRP0;)\n   asm nop;\n   asm nop;/$1\n   asm ldx #0;\n   asm txs;/ or die 'fine initial row';
   }
   my$barrier=0;$c =~ s/(   (?:PF[12]|COLUPF|COLUBK) := \w+;)/'   asm @TEMPLATE_fine_barrier_'.($barrier++).":;\n".$1/ge;
   $c=main::bank_preparation($c);
   $c =~ s/(   TEMPLATE_prepare\(\);)/$1\n   asm tsx;\n   asm stx.z TEMPLATE_saved_s;\n   asm lda.a TEMPLATE_player1_colors;\n   asm sta.z TEMPLATE_packed_p1_zero;/ or die 'fine stack save';
   $c =~ s/(   asm sta.z TEMPLATE_packed_p1_zero;)/$1\n$initialize/ or die 'RTS route preparation' if$rts;
   return$c;
};
