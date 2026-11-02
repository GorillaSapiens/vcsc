# Private backend for the display-wide plan; not a user-facing generator/ABI.
use strict;
use warnings;
return sub {
   my($repo,$heights,$pal,$bad,undef,$uniform,undef,$procedures,$donors)=@_;
   my$planner=do "$repo/test/fixtures/all_five_colors_sections_preview/fine_global_plan.pl";
   die$@ if$@;my$plan=$planner->($heights);
   $plan->{donors}=$donors if$donors;
   my$base=do "$repo/test/fixtures/all_five_colors_sections_preview/fine_spread.pl";
   die$@ if$@;my$c=$base->($repo,$heights,$pal,0,0,$uniform);
   $c=~s/TEMPLATE_packed_route\[2\]/TEMPLATE_packed_route[4]/ or die 'global route storage';
   if($plan->{boundary}){
      $c="uint8_t TEMPLATE_global_pf1_abs \@[none/0x10E];\nuint8_t TEMPLATE_global_pf2_abs \@[none/0x10F];\n".$c;
   }
   my$at=sub{$plan->{section}[$_[0]]%@$pal};
   my%seam=map{$_=>1}@{$plan->{seams}};
   my$key_for=sub{my$r=shift;return'T' if$r>=11;return$seam{$r*16+14}?$at->($r*16+14):'D';};
   for my$which(0,1){my@v;for my$r(0..11){push@v,map{$pal->[$at->($r*16+8+$_*2)][$which]}0..3;}
      $c='page const uint8_t TEMPLATE_sections_'.($which?'bk':'pf').'1[48] := {'.join(',',@v)."};\n".$c;
   }
   if($plan->{boundary}){for my$which(0,1){my@v;for my$r(0..11){my$l=($r+1)*16;$l=191 if$l>191;push@v,($pal->[$at->($l)][$which])x4;}
      $c='page const uint8_t TEMPLATE_global_'.($which?'bk':'pf').'[48] := {'.join(',',@v)."};\n".$c;
   }}
   # Share the non-writing packed path across rows that have no phase14 seam.
   # Only actual phase14 events require distinct palette tails, not every
   # palette that happens to span a row. This bounds code by event count.
   for my$parity(0,1){my$side=$parity?'B':'A';my%used;for my$r(0..11){$used{$key_for->($r)}=1 if$r%2==$parity;}
      my@blocks=$c=~/(   asm \.align 256, \$[\da-f]+;\n   asm \@TEMPLATE_fine_${side}_([0-7T])_u7_p1_zero:;.*?)(?=   asm \.align 256, \$[\da-f]+;)/sg;
      my$dead;
      while(@blocks){my($body,$key)=splice@blocks,0,2;my$n=$body;
         if($key ne'T'&&$used{D}&&!defined$dead){$dead=$body;$dead=~s/TEMPLATE_fine_${side}_${key}_/TEMPLATE_fine_${side}_D_/g;$dead=~s/TEMPLATE_fine_barrier_/TEMPLATE_global_dead_${side}_barrier_/g;$dead=~s/   COLU(?:PF|BK) := \d+;/   asm lda #0;\n   asm bit.z \$00;/g;}
         if(!$used{$key}){$c=~s/\Q$body\E// or die 'global unused packed path';}
         elsif($key eq'T'&&!$seam{190}){$n=~s/   COLU(?:PF|BK) := \d+;/   asm lda #0;\n   asm bit.z \$00;/g;$c=~s/\Q$body\E/$n/ or die 'global terminal pad';}
      }
      $c=~s/(   asm \.align 256, \$[\da-f]+;\n   asm \@TEMPLATE_A_boundary:;)/$dead$1/ or die 'global dead packed path' if defined$dead;
   }
   my%donor=map{($_->{parity}.':'.$_->{phase})=>$_}@{$plan->{donors}};
   for my$parity(0,1){my$side=$parity?'B':'A';my($normal)=$c=~/(   asm \@TEMPLATE_${side}_u1:;.*?)(?=   \/\/ $side pair 7)/s;
      defined$normal or die 'global normal body';
      my($event)=$normal=~/(   asm \@TEMPLATE_${side}_u1:;.*?)(?=   \/\/ $side pair 2:)/s;
      my($ordinary)=$normal=~/(   asm \@TEMPLATE_${side}_u2:;.*?)(?=   \/\/ $side pair 3:)/s;
      defined$event&&defined$ordinary or die 'global pair templates';my$replacement='';
      for my$n(1..6){my$d=$donor{"$parity:$n"};my$p;
         if($plan->{busy}{$parity}{$n}||($d&&$d->{late})){
            $p=$event;$p=~s/TEMPLATE_${side}_u1/TEMPLATE_${side}_u$n/g;
            my($plane,$index)=$n<4?(0,$n):(1,$n-4);
            $p=~s/TEMPLATE_sections_(pf|bk)0 \+ 1/TEMPLATE_sections_${1}$plane + $index/g;
            if($d&&$d->{late}){my$m1=$parity?12:5;
               $p=~s/   asm lsr.z TEMPLATE_row_cache \+ $m1;/   asm lda.zx TEMPLATE_object_masks + 9,x;\n   asm sta.z TEMPLATE_row_cache + $m1;/ or die 'global late M1 refill';
               $p=~s/   asm nop;\n(   asm lda.z TEMPLATE_row_cache \+ \d+;\n   asm sta PF2;)/$1/ or die 'global late M1 pad';
            }
         }else{
            $p=$ordinary;$p=~s/TEMPLATE_${side}_u2/TEMPLATE_${side}_u$n/g;
            if($d){my$load;
               if($d->{kind}eq'route'){my$name=($d->{destination}?'B':'A').($d->{byte}?'hi':'lo');my$offset=$d->{destination}*2+$d->{byte};$load="   asm lda.ax \@TEMPLATE_global_route_$name,x;\n   asm sta.z TEMPLATE_packed_route + $offset;";}
               else{my$offset=$d->{advance}*4+1;my$cache=$d->{destination}?12:5;$load="   asm lda.zx TEMPLATE_object_masks + $offset,x;\n   asm sta.z TEMPLATE_row_cache + $cache;";}
               $p=~s/   asm lda.ax \@TEMPLATE_fine_route_lo,x;\n   asm sta.z TEMPLATE_packed_route \+ 0;/$load/ or die 'global donor';
            }else{
               $p=~s/   asm lda.ax \@TEMPLATE_fine_route_lo,x;\n   asm sta.z TEMPLATE_packed_route \+ 0;/   asm nop;\n   asm nop;\n   asm bit.z \$00;/ or die 'global dead slot';
            }
         }
         # Copying a kernel must also namespace its folding barriers.
         $p=~s/\@TEMPLATE_fine_barrier_(\d+)/\@TEMPLATE_global_${side}_${n}_barrier_$1/g;
         if($n==1&&$plan->{boundary}){
            if($plan->{busy}{$parity}{$n}){$p=~s/   asm nop;\n(   asm lda.z TEMPLATE_row_cache \+ \d+;\n   asm sta PF2;\n   asm cpy.a)/   asm txs;\n$1/ or die 'global event row stack';}
            else{my$bl=$parity?11:4;$p=~s/(   asm lsr.z TEMPLATE_row_cache \+ $bl;)\n   asm nop;/$1\n   asm txs;/ or die 'global ordinary row stack';}
         }
         if($n==6){my$bl=$parity?11:4;my$offset=$parity*2;
            if($plan->{busy}{$parity}{$n}||($d&&$d->{late})){
               # Pair7 reads its packed BL bit: the final five-cycle shift is
               # dead and becomes the five-cycle indirect jump directly.
               $p=~s/   asm lsr.z TEMPLATE_row_cache \+ $bl;\n\s*\z/   asm jmp (TEMPLATE_packed_route + $offset);\n/ or die 'global event dispatch';
            }else{
               $p=~s/   asm lsr.z TEMPLATE_row_cache \+ $bl;\n   asm nop;\n\s*\z/   asm nop;\n   asm jmp (TEMPLATE_packed_route + $offset);\n/ or die 'global ordinary dispatch';
            }
         }
         $replacement.=$p;
      }
      $c=~s/\Q$normal\E/$replacement/ or die 'global replace normal';
   }
   # BL and M1 are fetched at their successor boundary, not in six separate
   # per-row refill slots. Moving BL's accumulator shift into HBLANK preserves
   # every later phase; A folds one PF load, B already budgets LSRabs's cycle.
   for my$parity($plan->{boundary}?(): (0,1)){my$side=$parity?'B':'A';my$next=$parity?'even':'odd';my$bl=$parity?4:11;my$m1=$bl+1;
      my($body)=$c=~/(   asm \@TEMPLATE_${side}_boundary:;.*?)(?=   asm \.align 256, \$[\da-f]+;)/s;
      defined$body or die 'global boundary';my$n=$body;
      $n=~s/   asm lda.z TEMPLATE_row_cache \+ $bl;/   asm lda.zx TEMPLATE_object_masks + 4,x;/ or die 'global BL load';
      $n=~s/(   asm sta ENABL;)/$1\n   asm lsr;\n   asm sta.z TEMPLATE_row_cache + $bl;/ or die 'global BL shift';
      $n=~s/   asm lsr\.(?:z|a) TEMPLATE_row_cache \+ $bl;\n// or die 'global old BL shift';
      if(!$parity){$n=~s/   asm lda.z TEMPLATE_row_cache \+ 0;\n   asm sta PF1;/   PF1 := TEMPLATE_even_pf0;/ or die 'global A HBLANK cycle';}
      $n=~s/   asm lda.z TEMPLATE_row_cache \+ $m1;/   asm lda.zx TEMPLATE_object_masks + 5,x;/ or die 'global M1 load';
      $n=~s/   asm lsr.z TEMPLATE_row_cache \+ $m1;/   asm lsr;\n   asm sta.z TEMPLATE_row_cache + $m1;/ or die 'global M1 shift';
      my$pf=$parity?0:7;
      $n=~s/   asm lda.z TEMPLATE_row_cache \+ $pf;\n   asm sta PF1;/   PF1 := TEMPLATE_${next}_pf0;/ or die 'global M1 cycle';
      $c=~s/\Q$body\E/$n/ or die 'global boundary replace';
   }
   if($plan->{boundary}){
      my$preview=main::slurp("$repo/test/fixtures/all_five_colors_sections_preview/component.c26");
      my($template)=$preview=~/(   asm \@TEMPLATE_A_boundary:;.*?)(?=   \/\/ B pair 1:)/s;
      defined$template or die 'global palette boundary template';
      for my$parity(0,1){my$side=$parity?'B':'A';my$next=$parity?'A':'B';my$pat=$parity?'odd':'even';my$nextpat=$parity?'even':'odd';my$t=$template;
         $t=~s/\@TEMPLATE_B_u1/\@NEXT_u1/g;$t=~s/TEMPLATE_A_/TEMPLATE_${side}_/g;$t=~s/TEMPLATE_spread_A_/TEMPLATE_spread_${side}_/g;$t=~s/\@NEXT_u1/\@TEMPLATE_${next}_u1/g;$t=~s/TEMPLATE_odd_pf/TEMPLATE_${nextpat}_pf/g;
         $t=~s/(   asm \@TEMPLATE_${side}_boundary:;)/$1\n   asm sta GRP0;/;
         $t=~s/(   asm dec.z TEMPLATE_object_masks \+ 0;)/   asm sty.z TEMPLATE_object_masks + 0;\n$1/ or die 'global boundary P0';
         $t=~s/   asm sty.a ENAM1;/   asm sty ENAM1;/g;
         for my$i(0..3){my$reg=($i==0||$i==3)?1:2;$t=~s/   asm lda\.(?:z|a) TEMPLATE_row_cache \+ $i;\n   asm sta PF$reg;/   PF$reg := TEMPLATE_${pat}_pf$i;/g;}
         $t=~s/   asm dey;\n   asm sty.z TEMPLATE_object_masks \+ 1;\n// or die 'global defer P1';
         $t=~s/(   PF2 := TEMPLATE_${pat}_pf2;)/   asm nop;\n$1\n   asm dey;/ or die 'global boundary P1 decrement';
         $t=~s/(   asm sta COLUP1;)/$1\n   asm sty.z TEMPLATE_object_masks + 1;/ or die 'global active P1';
         $t=~s/   asm ldy #0;\n   asm lda.ay TEMPLATE_player1_colors,y;/   asm sty.z TEMPLATE_object_masks + 1;\n   asm lda.z TEMPLATE_packed_p1_zero;/ or die 'global zero P1';
         $t=~s/(   asm lda #0;\n)(   asm ldy.z TEMPLATE_row_cache \+ 12;)/$1   asm bit.z \$00;\n$2/ or die 'global zero pad';
         $t=~s/(   asm cpy.z TEMPLATE_player0_height;)\n   asm inx;/$1/g;
         $t=~s/(   PF1 := TEMPLATE_${nextpat}_pf3;)/$1\n   asm inx;/g;
         # Read/shift BL directly in HBLANK; the absolute PF1 mirror and
         # removed NOP balance indexed addressing without moving right PF.
         $t=~s/   asm lda.z TEMPLATE_row_cache \+ 11;/   asm lda.zx TEMPLATE_object_masks + 4,x;/ or die 'global boundary BL';
         $t=~s/(   asm sta ENABL;)/$1\n   asm lsr;\n   asm sta.z TEMPLATE_row_cache + 11;/;
         $t=~s/   asm lsr.z TEMPLATE_row_cache \+ 11;\n// or die 'global boundary old BL shift';
         $t=~s/PF1 := TEMPLATE_${pat}_pf0;/TEMPLATE_global_pf1_abs := TEMPLATE_${pat}_pf0;/;
         $t=~s/   asm nop;\n(   PF2 := TEMPLATE_${pat}_pf2;)/$1/ or die 'global boundary BL pad';
         # M1 was loaded by the opposite row after this lane became dead.
         # Move CPY beyond right PF; pair1 restores row-X in its own pad.
         $t=~s/   asm cpy.z TEMPLATE_player0_height;\n//g;
         $t=~s/PF2 := TEMPLATE_${nextpat}_pf2;/TEMPLATE_global_pf2_abs := TEMPLATE_${nextpat}_pf2;/g;
         $t=~s/(   PF1 := TEMPLATE_${nextpat}_pf3;\n)   asm inx;/$1   asm cpy.z TEMPLATE_player0_height;/g;
         $t=~s/(   TEMPLATE_global_pf2_abs := TEMPLATE_${nextpat}_pf2;)/   asm inx;\n$1/g;
         $t=~s/(   asm cpy.z TEMPLATE_player0_height;\n)   asm inx;/$1/g;
         $t=~s/   asm sta.a GRP0;/   asm sta GRP0;/g;
         $t=~s/   asm nop;\n   asm jmp/   asm inx;\n   asm jmp/g;
         if($parity){my%map=(6=>13,11=>4,12=>5);$t=~s/TEMPLATE_row_cache \+ (6|11|12)\b/'TEMPLATE_row_cache + '.$map{$1}/ge;}
         $t=~s/TEMPLATE_sections_(pf|bk) \+ 4/TEMPLATE_global_$1/g;
         my$serial=0;$t=~s/(   (?:PF[12]|TEMPLATE_global_pf[12]_abs) := \w+;)/'   asm @TEMPLATE_global_bound_'.$side.'_'.($serial++).":;\n".$1/ge;
         my$following=$parity?'fine_terminal':'B_boundary';
         $c=~s/   asm \@TEMPLATE_${side}_boundary:;.*?(?=   asm \.align 256, \$[\da-f]+;\n   asm \@TEMPLATE_$following:;)/$t/s or die 'global palette boundary replacement';
      }
   }
   # Every route byte is relocatable data in the drawing function. No main+
   # offsets, visible searches, extra stack vectors, or cartridge RAM.
   my$tables="   asm .align 256;\n";
   for my$d(grep{$_->{kind}eq'route'}@{$plan->{donors}}){my$side=$d->{destination}?'B':'A';my$plane=$d->{byte}?'hi':'lo';my$op=$d->{byte}?'>':'<';
      $tables.="   asm \@TEMPLATE_global_route_$side$plane:;\n";
      for my$row(0..11){my$target=$row+$d->{advance};$target=$d->{destination} if$target>=12||$target%2!=$d->{destination};
         my$key=$key_for->($target);
         $tables.='   asm .byte '.join(',',("$op\@TEMPLATE_fine_${side}_${key}_u7")x4).";\n";
      }
   }
   $c=~s/   asm \.align 256, \$00;\n   asm \@TEMPLATE_fine_route_lo:;.*?(?=   asm \.align 256, \$[\da-f]+;)/$tables/s or die 'global route tables';
   # A scoped zero-byte global anchor exports the actual relocated entry while
   # restoring the compiler's enclosing local-label scope immediately afterward.
   $c=~s/(   asm \@TEMPLATE_fine_([AB])_([0-7DT])_u7:;)/   asm .scope TEMPLATE_global_scope_${2}_${3};\n   asm TEMPLATE_global_entry_${2}_${3}:;\n   asm .endscope;\n$1/g;
   my$initial='';for my$row(0,1){my$side=$row?'B':'A';my$key=$key_for->($row);
      for my$byte(0,1){my$op=$byte?'>':'<';my$offset=$row*2+$byte;
         $initial.="   asm lda #$op\{TEMPLATE_global_entry_${side}_${key}\};\n   asm sta.z TEMPLATE_packed_route + $offset;\n";
      }
   }
   $c=~s/(   asm sta.z TEMPLATE_packed_p1_zero;)/$1\n$initial/ or die 'global initial routes';
   $c=~s/asm lda #95/asm lda #96/g; # Full 192-line missile endpoint.
   if($bad){$c=~s/TEMPLATE_sections_pf0 \+ 1/TEMPLATE_sections_pf0 + 0/ or die 'global palette mutation';}
   if($procedures){
      my$lower=do "$repo/test/fixtures/all_five_colors_sections_preview/fine_global_procedures.pl";die$@ if$@;
      return$lower->($c);
   }
   my$layout=do "$repo/test/fixtures/all_five_colors_sections_preview/fine_layout.pl";die$@ if$@;
   my$cursor=0;
   $c=~s{   asm \.align 256, \$[\da-f]+;\n(.*?)(?=   asm \.align 256, \$[\da-f]+;|\n\})}{
      my$body=$1;
      # The first anchor may be preceded by a comment; all modelled blocks are
      # independent JMP exits. Keep final assembler branch contracts intact.
      my$info=$layout->($body,'any');my%legal=map{$_->[0]=>1}@{$info->{phases}};
      my($pad)=grep{$legal{($cursor+$_)%256}}0..255;defined$pad or die 'global phase packing';
      my$phase=($cursor+$pad)%256;$cursor+=$pad+$info->{size};
      sprintf("   asm .align 256, \$%02x;\n",$phase).$body
   }sge;
   return$c;
};
