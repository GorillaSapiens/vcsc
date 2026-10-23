# Private composition of fine phases with row-boundary palette handoffs.
use strict;
use warnings;
return sub {
   my($repo,$heights,undef,$bad)=@_;my@args=@_;$args[3]=0;
   my$base=do "$repo/test/fixtures/all_five_colors_sections_preview/fine_late.pl";
   die$@ if$@;ref$base eq 'CODE' or die 'boundary base helper';
   my$c=$base->(@args);
   my(%phases,$end);
   $end=0;
   for(@$heights){$end+=$_;$phases{int($end/16)%2?'B':'A'}{$end%16}=1 if$end>0&&$end<192;}
   # If a parity has no phase14 seam, its packed colour stores are dead.
   # Keep their exact five cycles/four bytes, then share one nonterminal body
   # across all its row palettes. Terminal retains its distinct restore path.
   for my$side(qw(A B)){
      next if$phases{$side}{14};my$keep;
      my@bodies=$c =~ /(   asm \.align 256, \$[\da-f]+;\n   asm \@TEMPLATE_fine_${side}_[0-7T]_u7_p1_zero:;.*?)(?=   asm \.align 256, \$[\da-f]+;)/sg;
      for my$body(@bodies){
         my($key)=$body =~ /fine_${side}_([0-7T])_u7_p1_zero/;
         if($key ne 'T'&&defined$keep){
            $c =~ s/\Q$body\E// or die 'boundary packed duplicate';
            $c =~ s/TEMPLATE_fine_addr_${side}_$key\b/TEMPLATE_fine_addr_${side}_$keep/g;
         }else{
            $keep=$key if$key ne 'T';my$replacement=$body;
            $replacement =~ s/   COLU(?:PF|BK) := \d+;/   asm lda #0;\n   asm bit.z \$00;/g;
            $c =~ s/\Q$body\E/$replacement/ or die 'boundary dead packed colours';
         }
      }
   }
   # Use the frozen preview handoff, never the user's editable example source.
   my$p=main::slurp("$repo/test/fixtures/all_five_colors_sections_preview/component.c26");
   my($template)=$p =~ /(   asm \@TEMPLATE_A_boundary:;.*?)(?=   \/\/ B pair 1:)/s;
   defined$template or die 'boundary template';
   for my$side(qw(A B)){
      my$t=$template;my$next=$side eq 'A'?'B':'A';
      my$pat=$side eq 'A'?'even':'odd';my$nextpat=$side eq 'A'?'odd':'even';
      $t =~ s/\@TEMPLATE_B_u1/\@NEXT_u1/g;
      $t =~ s/TEMPLATE_A_/TEMPLATE_${side}_/g;
      $t =~ s/TEMPLATE_spread_A_/TEMPLATE_spread_${side}_/g;
      $t =~ s/\@NEXT_u1/\@TEMPLATE_${next}_u1/g;
      $t =~ s/TEMPLATE_odd_pf/TEMPLATE_${nextpat}_pf/g;
      # The packed path defers GRP0 and its raw P0 counter store to here.
      $t =~ s/(   asm \@TEMPLATE_${side}_boundary:;)/$1\n   asm sta GRP0;/;
      $t =~ s/(   asm dec.z TEMPLATE_object_masks \+ 0;)/   asm sty.z TEMPLATE_object_masks + 0;\n$1/ or die 'boundary raw P0';
      $t =~ s/   asm sty.a ENAM1;/   asm sty ENAM1;/g;
      for my$i(0..3){my$reg=($i==0||$i==3)?1:2;
         $t =~ s/   asm lda\.(?:z|a) TEMPLATE_row_cache \+ $i;\n   asm sta PF$reg;/   PF$reg := TEMPLATE_${pat}_pf$i;/g;
      }
      # Preserve preceding-line right PF2/PF1 at cycles45/52. Delay the P1
      # decrement across PF2, but commit its counter only after COLUP1 on the
      # active path. The zero path uses cached colour0 plus an equal-cost pad.
      # This also preserves COLUP1's active/zero phases64/67 at the right edge.
      $t =~ s/   asm dey;\n   asm sty.z TEMPLATE_object_masks \+ 1;\n// or die 'boundary defer P1 counter';
      $t =~ s/(   PF2 := TEMPLATE_${pat}_pf2;)/   asm nop;\n$1\n   asm dey;/ or die 'boundary P1 decrement';
      $t =~ s/(   asm sta COLUP1;)/$1\n   asm sty.z TEMPLATE_object_masks + 1;/ or die 'boundary active P1 counter';
      $t =~ s/   asm ldy #0;\n   asm lda.ay TEMPLATE_player1_colors,y;/   asm sty.z TEMPLATE_object_masks + 1;\n   asm lda.z TEMPLATE_packed_p1_zero;/ or die 'boundary zero P1 counter';
      $t =~ s/(   asm lda #0;\n)(   asm ldy.z TEMPLATE_row_cache \+ 12;)/$1   asm bit.z \$00;\n$2/ or die 'boundary zero pad';
      # Move the first X increment beyond next-row right PF1. Remove the
      # obsolete post-GRP0 NOP: both paths still advance X by4 in152 cycles.
      $t =~ s/(   asm cpy.z TEMPLATE_player0_height;)\n   asm inx;/$1/g;
      $t =~ s/(   PF1 := TEMPLATE_${nextpat}_pf3;)/$1\n   asm inx;/g;
      $t =~ s/(   asm inx;)\n   asm nop;\n   asm jmp/$1\n   asm jmp/g;
      my%map=$side eq 'A'?(6=>2,11=>3,12=>4):(6=>5,11=>0,12=>1);
      $t =~ s/TEMPLATE_row_cache \+ (\d+)/'TEMPLATE_row_cache + '.$map{$1}/ge;
      $t =~ s/TEMPLATE_sections_(pf|bk) \+ 4/TEMPLATE_sections_${1}0 + 4/g;
      $t =~ s/TEMPLATE_sections_pf0 \+ 4/TEMPLATE_sections_pf0 + 3/g if$bad;
      my$label=0;
      $t =~ s/(   (?:PF[12]|COLUPF|COLUBK) := \w+;)/'   asm @TEMPLATE_bound_'.$side.'_'.($label++).":;\n".$1/ge;
      my$following=$side eq 'A'?'B_boundary':'fine_terminal';
      $c =~ s/   asm \@TEMPLATE_${side}_boundary:;.*?(?=   asm \.align 256, \$[\da-f]+;\n   asm \@TEMPLATE_$following:;)/$t/s or die 'boundary replace';
   }
   my$choose=sub{
      my($cursor,$ranges)=@_;
      for my$pad(0..255){my$phase=($cursor+$pad)%256;return$phase if grep{$phase>=$_->[0]&&$phase<=$_->[1]}@$ranges;}
      die 'boundary phase packing';
   };
   my@early=([6,34],[40,60],[66,82],[98,108],[124,132],[148,149],[155,175],[181,197],[213,223],[239,246]);
   my@late=([10,35],[41,62],[68,79],[95,106],[122,135],[155,175],[181,197],[213,223],[239,250]);
   my$cursor;
   for my$side(qw(A B)){
      my$late=$phases{$side}{10}||$phases{$side}{12};
      my$normal=$side eq 'A'?($late?0x9b:0x94):$choose->($cursor,$late?\@late:\@early);
      my$hex=sprintf('%02x',$normal);
      $c =~ s/   asm \.align 256, \$[\da-f]+;\n(?=(?:   \/\/[^\n]*\n)?   asm \@TEMPLATE_${side}_u1:;)/   asm .align 256, \$$hex;\n/ or die 'boundary normal anchor';
      $cursor=$normal+687;
      $c =~ s/   asm \.align 256, \$[\da-f]+;\n(?=   asm \@TEMPLATE_fine_${side}_[0-7T]_u7_p1_zero:;)/
         my$phase=$choose->($cursor,$late?[[0,132],[149,195]]:[[0,131],[148,194]]);
         $cursor=$phase+($late?126:127);sprintf("   asm .align 256, \$%02x;\n",$phase)
      /ge;
   }
   for my$label(qw(A_boundary B_boundary fine_terminal)){
      my$phase=$label eq 'fine_terminal'?$cursor%256:$choose->($cursor,[[0,82],[92,144],[216,255]]);
      $cursor=$phase+183;my$hex=sprintf('%02x',$phase);
      $c =~ s/   asm \.align 256, \$[\da-f]+;\n(?=   asm \@TEMPLATE_$label:;)/   asm .align 256, \$$hex;\n/ or die 'boundary final anchor';
   }
   return$c;
};
