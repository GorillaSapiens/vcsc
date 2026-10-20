# Internal feasibility transformation, not a user-facing source generator.
# Keep every inherited .same/.cross contract and explicit page containment.
# Known incomplete: packed P1 COLUP1 is early at right-edge wrapped residues.
use strict;
use warnings;
return sub {
   my($repo,$heights,$pal,$bad_feed)=@_;
   my$component=main::slurp("$repo/libraries/vcs/renderers/all_five_player_color_192/all_five_player_color_192.c26");
   my$prime=join('',map{"   asm lda.a TEMPLATE_playfield + ".(4+$_).";\n   asm sta.z TEMPLATE_row_cache + ".(7+$_).";\n"}0..3);
   $prime.=join('',map{"   asm lda.z TEMPLATE_object_masks + ".(4+$_).";\n   asm sta.z TEMPLATE_row_cache + ".(11+$_).";\n"}0..2);
   $component =~ s/(   asm lda.z TEMPLATE_player0_y;)/$prime$1/ or die 'fine priming';
   my$decl="uint8_t TEMPLATE_packed_pf;\nuint8_t TEMPLATE_packed_bk;\nuint8_t TEMPLATE_saved_s;\n";
   for my$c(qw(even odd)){for my$i(0..3){$decl.="const uint8_t TEMPLATE_${c}_pf$i := TEMPLATE_playfield[".(($c eq 'odd'?4:0)+$i)."];\n";}}
   my$palette_at=sub{my$l=shift;my$end=0;for my$n(0..7){$end+=$heights->[$n];return$n%4 if$l<$end;}die 'line outside geometry';};
   for my$which(0,1){for my$plane(0,1){
      my@v;for my$r(0..11){push@v,map{$pal->[$palette_at->($r*16+$plane*8+$_*2)][$which]}0..3;}
      $decl.='page const uint8_t TEMPLATE_sections_'.($which?'bk':'pf').$plane.'[48] := {'.join(',',@v)."};\n";
   }}
   $component=$decl.$component;
   for my$c(qw(A B)){
      my$base=$c eq 'A'?0:7;my$next=$c eq 'A'?7:0;my$pat=$c eq 'A'?'even':'odd';my$m0=$base+6;my$m1=$base+5;my$bl=$base+4;
      for my$n(1..4){
         my$nextn=$n+1;my($pair)=$component =~ /(   asm \@TEMPLATE_${c}_u$n:;.*?)(?=   \/\/ $c pair $nextn:)/s;
         defined$pair or die "fine pair $c$n";my$old=$pair;
         if($n==2||$n==4){
            my$kind=$n==2?'pf':'bk';my$slot=$next+$n-1;
            $pair =~ s/   asm lda.ax TEMPLATE_playfield \+ \d,x;\n   asm sta.z TEMPLATE_row_cache \+ $slot;/   asm lda.ax TEMPLATE_sections_${kind}1 + 3,x;\n   asm sta.z TEMPLATE_packed_$kind;/ or die "fine prefetch $c$n";
         }else{
            for my$i(0..3){my$slot=$base+$i;$pair =~ s/   asm lda\.(?:z|a) TEMPLATE_row_cache \+ $slot;\n   asm sta PF[12];/'   PF'.(($i==0||$i==3)?1:2).' := TEMPLATE_'.$pat.'_pf'.$i.';'/ge;}
            my$slot=$next+$n-1;
            $pair =~ s/   asm lda.ax TEMPLATE_playfield \+ \d,x;\n   asm sta.z TEMPLATE_row_cache \+ $slot;/   asm dec.z TEMPLATE_object_masks + 0;/ or die "fine early work $c$n";
            # CPY must follow the M0 shift; LSR would otherwise destroy carry.
            $pair =~ s/(   asm cpy.z TEMPLATE_player1_height;)/   asm lsr.z TEMPLATE_row_cache + $m0;\n$1/ or die 'fine restore P1 carry';
            $pair =~ s/(   asm sta ENAM1;.*?)   asm lsr.z TEMPLATE_row_cache \+ $m0;\n/$1/s or die 'fine old M0';
            $pair =~ s/(   asm ldy.z TEMPLATE_object_masks \+ 0;)\n   asm dey;\n   asm sty.z TEMPLATE_object_masks \+ 0;/$1/ or die 'fine old P0';
            $pair =~ s/   asm sta ENABL;/   asm sta.a ENABL;/ or die 'fine P1 phase';
            $pair =~ s/(   asm sta ENAM1;)\n   asm lsr.z TEMPLATE_row_cache \+ $m1;/$1\n   asm lda.ax TEMPLATE_sections_pf0 + $n,x;\n   asm sta COLUPF;\n   asm lda.ax TEMPLATE_sections_bk0 + $n,x;\n   asm sta COLUBK;/ or die 'fine palette';
            $pair =~ s/(   asm sta COLUBK;.*?   PF2 := TEMPLATE_${pat}_pf1;)/$1\n   asm lsr.z TEMPLATE_row_cache + $m1;/s or die 'fine M1 shift';
            my$right=$base+2;
            $pair =~ s/   asm cpy.z TEMPLATE_player0_height;\n   PF2 := TEMPLATE_${pat}_pf2;/   asm nop;\n   asm lda.z TEMPLATE_row_cache + $right;\n   asm sta PF2;\n   asm cpy.a TEMPLATE_player0_height;/ or die 'fine P0 compare';
            $pair =~ s/(   asm lsr.z TEMPLATE_row_cache \+ $bl;)\n   asm nop;/$1/ or die 'fine tail';
            my$b=0;$pair =~ s/(   PF[12] := TEMPLATE_${pat}_pf\d;)/'   asm @TEMPLATE_fine_'.$c.'_'.$n.'_'.($b++).":;\n".$1/ge;
         }
         $component =~ s/\Q$old\E/$pair/ or die 'fine pair replace';
      }
      # Packed pair stages live M1 in X, restoring row X from S after the
      # palette writes. Duplicate P1 tails to keep the first pixels on time.
      my($packed)=$component =~ /(   asm \@TEMPLATE_${c}_u7:;.*?)(?=   asm \@TEMPLATE_${c}_boundary:;)/s;
      defined$packed or die 'fine packed';my$old=$packed;
      for my$i(0..3){my$slot=$base+$i;$packed =~ s/   asm lda\.(?:z|a) TEMPLATE_row_cache \+ $slot;\n   asm sta PF[12];/'   PF'.(($i==0||$i==3)?1:2).' := TEMPLATE_'.$pat.'_pf'.$i.';'/ge;}
      $packed =~ s/   asm ldy.zx TEMPLATE_object_masks \+ 6,x;\n// or die 'fine next M0 move';
      $packed =~ s/(   asm lda.zx TEMPLATE_object_masks \+ 3,x;)/   asm ldy.zx TEMPLATE_object_masks + 6,x;\n$1/ or die 'fine next M0 early';
      $packed =~ s/(   asm sta ENABL;\n   asm lsr;)/$1\n   asm tax;/ or die 'fine M1 stage';
      my$prefixright=$base+3;
      $packed =~ s/   asm sta.z TEMPLATE_row_cache \+ $m0;/   asm sta.a TEMPLATE_row_cache + $m0;/ or die 'fine prefix right2 phase';
      $packed =~ s/   PF1 := TEMPLATE_${pat}_pf3;/   asm lda.z TEMPLATE_row_cache + $prefixright;\n   asm sta PF1;/ or die 'fine packed prefix phase';
      $packed =~ s/   asm sty.z TEMPLATE_object_masks \+ 1;\n// or die 'fine defer packed P1';
      my($prefix,$a,$z,$tail)=$packed =~ /\A(.*?   asm bcs.same \@TEMPLATE_${c}_u7_p1_zero;\n)(.*?)   asm jmp \@TEMPLATE_${c}_u7_p1_ready;\n   asm \@TEMPLATE_${c}_u7_p1_zero:;\n(.*?)   asm bit.z \$00;\n   asm \@TEMPLATE_${c}_u7_p1_ready:;\n(.*)\z/s;
      defined$tail or die 'fine packed tails';
      $z =~ s/   asm ldy #0;\n   asm lda.ay TEMPLATE_player1_colors,y;/   asm lda.a TEMPLATE_player1_colors;\n   asm nop;/ or die 'fine preserve packed P1 raw Y';
      $a =~ s/(   asm sta COLUP1;)/$1\n   asm lda.z TEMPLATE_packed_bk;\n   asm sta COLUBK;/ or die 'fine active background';
      $z =~ s/(   asm sta COLUP1;)/$1\n   asm lda.z TEMPLATE_packed_bk;\n   asm sta COLUBK;/ or die 'fine zero background';
      $tail =~ s/   asm lda.zx TEMPLATE_object_masks \+ 3,x;\n   asm lsr;\n   asm sta ENAM1;/   asm stx ENAM1;\n   asm lda.z TEMPLATE_packed_pf;\n   asm sta COLUPF;/ or die 'fine packed palette';
      my$right2=$base+2;
      $tail =~ s/   PF2 := TEMPLATE_${pat}_pf2;/   asm lda.z TEMPLATE_row_cache + $right2;\n   asm sta PF2;\n   asm tsx;/ or die 'fine packed X restore';
      $tail =~ s/(   PF1 := TEMPLATE_${pat}_pf0;)/$1\n   asm sty.z TEMPLATE_object_masks + 1;/ or die 'fine packed P1 store';
      $tail =~ s/   asm sty.z TEMPLATE_object_masks \+ 0;\n// or die 'fine packed P0';
      $tail =~ s/(   asm lda #0;\n)   asm tay;/$1   asm nop;/ or die 'fine packed raw Y';
      my$zt=$tail;$zt =~ s/\@TEMPLATE_${c}_u7_/\@TEMPLATE_${c}_u7_zero_/g;
      $packed=$prefix.$a.$tail."   asm jmp \@TEMPLATE_${c}_boundary;\n   asm \@TEMPLATE_${c}_u7_p1_zero:;\n".$z.$zt."   asm jmp \@TEMPLATE_${c}_boundary;\n";
      my$b=0;$packed =~ s/(   PF[12] := TEMPLATE_${pat}_pf\d;)/'   asm @TEMPLATE_fine_packed_'.$c.'_'.($b++).":;\n".$1/ge;
      $component =~ s/\Q$old\E/$packed/ or die 'fine packed replace';
   }
   $component =~ s/(   asm \@TEMPLATE_A_boundary:;.*?)   asm nop;\n   asm bit.z \$00;/$1   asm nop;\n   asm sty.z TEMPLATE_object_masks + 0;/s or die 'fine A deferred P0';
   my($boundary_b)=$component =~ /(   asm \@TEMPLATE_B_boundary:;.*?)(?=   \/\/ Row 11 is terminal)/s;
   defined$boundary_b or die 'fine B boundary';my$old=$boundary_b;
   $boundary_b =~ s/   asm lda.z TEMPLATE_row_cache \+ 7;\n   asm sta PF1;/   PF1 := TEMPLATE_odd_pf0;/ or die 'fine B left1';
   $boundary_b =~ s/   asm lda.z TEMPLATE_row_cache \+ 8;\n   asm sta PF2;/   PF2 := TEMPLATE_odd_pf1;/ or die 'fine B left2';
   $boundary_b =~ s/(   asm cpx #44;)/   asm sty.z TEMPLATE_object_masks + 0;\n$1/ or die 'fine B deferred P0';
   $boundary_b =~ s/   asm lsr.a TEMPLATE_row_cache \+ 4;/   asm lsr.z TEMPLATE_row_cache + 4;/ or die 'fine B shift';
   $component =~ s/\Q$old\E/$boundary_b/ or die 'fine B replace';
   $component =~ s/(   asm \@TEMPLATE_terminal_boundary:;)\n   asm bit.z \$00;/$1\n   asm nop;/ or die 'fine terminal';
   $component =~ s/   asm \.align 256, \$90;//;
   $component =~ s/(   asm \@TEMPLATE_A_u1:;)/   asm .align 256, \$39;\n$1/ or die 'fine A anchor';
   my($ab)=$component =~ /(   asm \@TEMPLATE_A_boundary:;.*?)(?=   \/\/ B pair 1:)/s;
   defined$ab or die 'fine A exit';my$abold=$ab;
   $ab =~ s/   asm nop;\n   asm bit.z \$00;/   asm nop;\n   asm jmp \@TEMPLATE_B_u1;/ or die 'fine A jump';
   $component =~ s/\Q$abold\E/$ab/ or die 'fine A exit replace';
   $component =~ s/(   asm \@TEMPLATE_B_u1:;)/   asm .align 256, \$39;\n$1/ or die 'fine B anchor';
   $component =~ s/(   asm \@TEMPLATE_first_p0_ready:;\n   asm sta GRP0;)\n   asm nop;\n   asm nop;/$1\n   asm ldx #0;\n   asm txs;/ or die 'fine initial stack row';
   for my$c(qw(A B)){
      $component =~ s/(   asm inx;)\n   asm nop;\n   asm jmp \@TEMPLATE_${c}_u1;/$1\n   asm txs;\n   asm jmp \@TEMPLATE_${c}_u1;/ or die 'fine stack row';
   }
   $component =~ s/(   asm \@TEMPLATE_terminal_boundary:;)\n   asm nop;\n   asm bit.z \$00;/$1\n   asm ldx.z TEMPLATE_saved_s;\n   asm txs;/ or die 'fine restore stack';
   # Include boundary writes: equal PF bytes must never elide an LDA.
   my$barrier=0;
   $component =~ s/(   PF[12] := TEMPLATE_\w+;)/'   asm @TEMPLATE_fine_barrier_'.($barrier++).":;\n".$1/ge;
   $component=main::bank_preparation($component);
   $component =~ s/(   TEMPLATE_prepare\(\);)/$1\n   asm tsx;\n   asm stx.z TEMPLATE_saved_s;/ or die 'fine save stack';
   if($bad_feed){
      # Same instruction timing, wrong prefetched packed playfield colour.
      $component =~ s/TEMPLATE_sections_pf1 \+ 3,x/TEMPLATE_sections_pf1 + 2,x/ or die 'fine feed mutation';
   }
   return$component;
};
