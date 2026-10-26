# Private single later-row dense proof, not general geometry support.
use strict;
use warnings;
return sub {
   my($repo,$heights,$pal,$bad)=@_;
   my$last=7%scalar(@$pal);
   my$row=int($heights->[0]/16);
   $row>=1&&$row<=10&&$heights->[0]==$row*16+2
      &&!(grep{$heights->[$_]!=2}1..6)
      &&$heights->[7]==192-$row*16-14 or die "unsupported later dense geometry\n";
   my$side=$row%2?'B':'A';my$prior=$side eq 'A'?'B':'A';
   my$current_bl=$side eq 'A'?0:3;my$next_bl=$side eq 'A'?3:0;my$next_m1=$next_bl+1;
   my$base=do "$repo/test/fixtures/all_five_colors_sections_preview/fine_spread.pl";
   die$@ if$@;ref$base eq 'CODE' or die 'later dense base';
   my@args=@_;$args[3]=0;my$c=$base->(@args);
   # These inherited PF cache primes target lanes reclaimed by the return
   # vector and are overwritten before drawing. Remove their dead blanking
   # work to fund the two live successor-mask primes at worst-case heights.
   my$dead=$c =~ s/   asm lda.a TEMPLATE_prepare_playfield(?: \+ [0-7])?;\n   asm sta.z TEMPLATE_row_cache \+ (?:[6-9]|1[0-3]);\n//g;
   $dead==8 or die 'later dense dead PF prime count';
   $c="uint8_t TEMPLATE_dense_next_bl;\nuint8_t TEMPLATE_dense_next_m1;\n".$c;
   my$prime='';for my$spec(['bl',0],['m1',1]){
      $prime.='   asm lda.z TEMPLATE_object_masks + '.(($row+1)*4+$spec->[1]).";\n";
      $prime.="   asm lsr;\n" if$spec->[0]eq'bl';
      $prime.="   asm sta.z TEMPLATE_dense_next_$spec->[0];\n";
   }
   $c =~ s/(   asm sta.z TEMPLATE_packed_p1_zero;)/$1\n$prime/ or die 'later dense prime';
   my($normal)=$c =~ /(   asm \@TEMPLATE_${side}_u1:;.*?)(?=   \/\/ $side pair 7)/s;
   defined$normal or die 'later dense normal';my$dense=$normal;
   for my$spec([2,5],[4,6]){
      my($from,$to)=@$spec;my$next=$from+1;
      my($pair)=$normal =~ /(   asm \@TEMPLATE_${side}_u$from:;.*?)(?=   \/\/ $side pair $next:)/s;
      my($old)=$to==5
         ?$dense =~ /(   asm \@TEMPLATE_${side}_u5:;.*?)(?=   \/\/ $side pair 6:)/s
         :$dense =~ /(   asm \@TEMPLATE_${side}_u6:;.*)\z/s;
      defined$pair&&defined$old or die 'later dense pair';
      $pair =~ s/TEMPLATE_${side}_u$from/TEMPLATE_${side}_u$to/g;
      $pair =~ s/\@TEMPLATE_(fine_barrier|rts_fold)_/\@TEMPLATE_copy${to}_${1}_/g;
      my$plane=$from==2?0:1;my$index=$from==2?2:0;my$dest=$to-4;
      $pair =~ s/TEMPLATE_sections_(pf|bk)$plane \+ $index/TEMPLATE_sections_${1}1 + $dest/g;
      if($to==6){
         $pair =~ s/   asm lsr.z TEMPLATE_row_cache \+ $current_bl;\n\z/   asm rts;\n/ or die 'later dense return';
         $pair =~ s/cpy.a TEMPLATE_player0_height/cpy.z TEMPLATE_player0_height/ or die 'later dense CPY';
      }
      $dense =~ s/\Q$old\E/$pair/ or die 'later dense replace';
   }
   # Only the specialised row changes colours. Fold its known table reads
   # into equal-size/equal-cycle immediate loads. Ordinary rows keep their
   # current palette through seven-cycle non-writing pads, so the four page
   # tables can be omitted without adding a palette-dependent normal body.
   $dense =~ s{   asm lda.ax TEMPLATE_sections_(pf|bk)([01]) \+ ([0-3]),x;}{
      my($which,$plane,$index)=($1,$2,$3);my$line=$plane*8+$index*2;
      my$key=$line/2;my$value=$pal->[$key%scalar(@$pal)][$which eq 'bk'?1:0];
      "   asm lda #$value;\n   asm nop;"
   }ge;
   # PHA3/PLA4 is a two-byte seven-cycle non-writing pad. S points at the
   # already-consumed route high byte (or dead next-M0 lane before row0's
   # first RTS), never at a future vector entry. A and S are restored exactly;
   # next-M0 is freshly staged by packed pair7 before its first use.
   $c =~ s{   asm lda.ax TEMPLATE_sections_(?:pf|bk)[01] \+ [0-3],x;\n   asm sta COLU(?:PF|BK);}{   asm pha;\n   asm pla;}g;
   $c =~ s/^page const uint8_t TEMPLATE_sections_(?:pf|bk)[01]\[48\] := \{[^\n]+\};\n//mg;
   $dense =~ s/\@TEMPLATE_/\@TEMPLATE_dense_/g;
   my($boundary_a)=$c =~ /(   asm \@TEMPLATE_A_boundary:;.*?)(?=   asm \.align 256, \$[\da-f]+;\n   asm \@TEMPLATE_B_boundary:;)/s;
   my($boundary_b)=$c =~ /(   asm \@TEMPLATE_B_boundary:;.*?)(?=   asm \.align 256, \$[\da-f]+;\n   asm \@TEMPLATE_fine_terminal:;)/s;
   defined$boundary_a&&defined$boundary_b or die 'later dense boundaries';
   my$after=$side eq 'A'?$boundary_a:$boundary_b;my$before=$side eq 'A'?$boundary_b:$boundary_a;
   $after =~ s/\@TEMPLATE_${side}_/\@TEMPLATE_dense_${side}_/g;
   $before =~ s/\@TEMPLATE_${prior}_/\@TEMPLATE_dense_${prior}_/g;
   $after =~ s/\@TEMPLATE_(fine_barrier|rts_fold)_/\@TEMPLATE_after_${1}_/g;
   $before =~ s/\@TEMPLATE_(fine_barrier|rts_fold)_/\@TEMPLATE_before_${1}_/g;
   $before =~ s/   asm inx;\n   asm inx;\n   asm inx;/   asm ldx #@{[$row*4]};\n   asm stx.a TEMPLATE_packed_row;/ or die 'later dense row save';
   $before =~ s/   asm inx;/   asm nop;/ or die 'later dense last increment';
   $before =~ s/\@TEMPLATE_${side}_u1/\@TEMPLATE_dense_${side}_u1/g;
   # BL's A value is overwritten by left PF before its old shift slot. Prime
   # its shifted byte in blanking, stage raw bit0 from the original mask, then
   # copy in six cycles. On A, left PF1/PF2 move one cycle earlier inside
   # HBLANK by using STAzp instead of STAabs; all following phases are unchanged.
   $after =~ s/   asm lda.z TEMPLATE_row_cache \+ $next_bl;/   asm lda.z TEMPLATE_object_masks + @{[($row+1)*4]};/ or die 'later dense BL stage';
   if($side eq 'A'){
      $after =~ s/   asm sta.a PF1;/   asm sta PF1;/ or die 'later dense BL pad';
   }
   # B already budgets LSRabs6, exactly the six-cycle copy. A's LSRzp5
   # needs the one-cycle left-PF saving above; do not shift B's left PF.
   $after =~ s/   asm lsr\.(?:z|a) TEMPLATE_row_cache \+ $next_bl;/   asm lda.z TEMPLATE_dense_next_bl;\n   asm sta.z TEMPLATE_row_cache + $next_bl;/ or die 'later dense BL copy';
   # M1 is shifted immediately after its commit, while A still holds its raw
   # mask: LSR A2 + STAzp3 exactly replaces LSRzp5.
   $after =~ s/   asm lda.z TEMPLATE_row_cache \+ $next_m1;/   asm lda.z TEMPLATE_dense_next_m1;/ or die 'later dense M1 stage';
   $after =~ s/   asm lsr.z TEMPLATE_row_cache \+ $next_m1;/   asm lsr;\n   asm sta.z TEMPLATE_row_cache + $next_m1;/ or die 'later dense M1 copy';
   $after =~ s/TEMPLATE_dense_next_bl/TEMPLATE_dense_next_m1/ if$bad;
   my$extra='';
   for my$spec([$side,$last,'D',"dense_${side}_boundary"],[$prior,0,'D',"dense_${prior}_boundary"]){
      my($packed_side,$key,$newkey,$target)=@$spec;
      my($packed)=$c =~ /(   asm \@TEMPLATE_fine_${packed_side}_${key}_u7_p1_zero:;.*?)(?=   asm \.align 256, \$[\da-f]+;)/s;
      defined$packed or die 'later dense packed';
      $packed =~ s/TEMPLATE_fine_(addr_)?${packed_side}_$key/'TEMPLATE_fine_'.(defined$1?$1:'').$packed_side.'_'.$newkey/ge;
      $packed =~ s/\@TEMPLATE_(fine_barrier|rts_fold)_/\@TEMPLATE_dense_${packed_side}_${1}_/g;
      $packed =~ s/\@TEMPLATE_${packed_side}_boundary/\@TEMPLATE_$target/g;
      $packed =~ s/(   asm lda.ay TEMPLATE_player0_colors,y;\n)   asm sta.a COLUP0;/$1   asm sta COLUP0;/ or die 'later dense packed phase' if$packed_side eq $side;
      $extra.="   asm .align 256, \$00;\n".$packed;
   }
   # Redirect exactly the preceding row and the dense row in the return vector.
   my$route=0;
   $c =~ s/(   asm lda #[<>]\{main \+ TEMPLATE_fine_addr_)([AB])_([0-7T])( - 1\};)/
      my$r=int($route++\/2);$1.$2.'_'.(($r==$row||$r==$row-1)?'D':$3).$4
   /ge;
   $route==24 or die 'later dense route count';
   # No ordinary row has a phase14 seam. Elide equal-cost dead colour stores
   # and share its packed tail across palettes; the two D routes stay distinct.
   for my$packed_side(qw(A B)){
      my@packed=$c =~ /(   asm \.align 256, \$[\da-f]+;\n   asm \@TEMPLATE_fine_${packed_side}_(?:0|$last|T)_u7_p1_zero:;.*?)(?=   asm \.align 256, \$[\da-f]+;)/sg;
      my$have_zero=grep{/fine_${packed_side}_0_u7_p1_zero/}@packed;
      for my$p(@packed){my($key)=$p =~ /fine_${packed_side}_(0|$last|T)_u7_p1_zero/;
         if($key eq "$last"&&$have_zero){
            $c =~ s/\Q$p\E// or die 'later dense packed remove';
            $c =~ s/TEMPLATE_fine_addr_${packed_side}_$last\b/TEMPLATE_fine_addr_${packed_side}_0/g;
         }else{my$n=$p;$n =~ s/   COLU(?:PF|BK) := \d+;/   asm lda #0;\n   asm bit.z \$00;/g;
            $c =~ s/\Q$p\E/$n/ or die 'later dense dead stores';
         }
      }
      if(!$have_zero){
         # If row1 is dense, no ordinary B row uses palette0. Keep its final
         # palette tail as the shared body, rather than aliasing a missing0.
         $c =~ s/TEMPLATE_fine_(addr_)?${packed_side}_$last/'TEMPLATE_fine_'.(defined$1?$1:'').$packed_side.'_0'/ge;
      }
   }
   $c =~ s/(   asm \.align 256, \$[\da-f]+;\n   asm \@TEMPLATE_A_boundary:;)/   asm .align 256, \$00;\n$dense$extra   asm .align 256, \$00;\n$before   asm .align 256, \$00;\n$after$1/ or die 'later dense insert';
   my$layout=do "$repo/test/fixtures/all_five_colors_sections_preview/fine_layout.pl";
   die$@ if$@;ref$layout eq 'CODE' or die 'later dense layout';
   my(@blocks,$terminal);
   $c =~ s{   asm \.align 256, \$[\da-f]+;\n(.*?)(?=   asm \.align 256, \$[\da-f]+;|\z)}{
      my$block=$1;$block =~ s/\A(?:\s*\/\/[^\n]*\n|\s*\n)+//;my$size;
      if($block =~ /^   asm \@TEMPLATE_[AB]_u1:;/){$size=663;}
      elsif($block =~ /^   asm \@TEMPLATE_dense_[AB]_u1:;/){$size=688;}
      elsif($block =~ /^   asm \@TEMPLATE_fine_([AB])_([0DT])_u7_p1_zero:;/){$size=($1 eq $side&&$2 eq 'D')?126:127;}
      elsif($block =~ /^   asm \@TEMPLATE_dense_[AB]_boundary:;/){$size=122;}
      elsif($block =~ /^   asm \@TEMPLATE_[AB]_boundary:;/){$size=120;}
      elsif($block =~ /^   asm \@TEMPLATE_fine_terminal:;/){$size=0;}
      else{die 'later dense unknown block: '.substr($block,0,100);}
      if($size){my$ranges=$layout->($block,$size);my%legal=map{$_->[0]=>1}@$ranges;
         my@pads;for my$ph(0..255){my($pad)=grep{$legal{($ph+$_)%256}}0..255;defined$pad or die 'later dense phase';push@pads,$pad;}
         push@blocks,[$block,$size,\@pads];
      }else{$terminal=$block;}
      ''
   }sge;
   # Every block ends with RTS/JMP. Reorder independent blocks to avoid
   # burning a page per specialised tail; assembler contracts still validate
   # each emitted phase. Bounded beam search keeps fixture preparation cheap.
   my@states=map{[$_,0,[],0]}0..255;
   for(1..scalar@blocks){my@next;
      for my$state(@states){my($cursor,$mask,$order,$cost)=@$state;
         for my$i(0..$#blocks){next if$mask&(1<<$i);
            my$pad=$blocks[$i][2][$cursor%256];my$phase=($cursor+$pad)%256;
            push@next,[$cursor+$pad+$blocks[$i][1],$mask|(1<<$i),[@$order,[$i,$phase]],$cost+$pad+$blocks[$i][1]];
         }
      }
      my%seen;@states=grep{!$seen{$_->[1].':'.($_->[0]%256)}++}
         sort{($a->[3]+(($a->[2][0][1]-0xe6)%256))<=>($b->[3]+(($b->[2][0][1]-0xe6)%256))}@next;
      splice@states,256 if@states>256;
   }
   # Prefer a first anchor near the end of the existing setup prefix as well
   # as low inter-block padding; otherwise a zero-pad body can waste nearly
   # a full page before its first block. Final linking owns actual placement.
   @states=sort{($a->[3]+(($a->[2][0][1]-0xe6)%256))<=>($b->[3]+(($b->[2][0][1]-0xe6)%256))}@states;
   my$packed=join('',map{sprintf("   asm .align 256, \$%02x;\n",$_->[1]).$blocks[$_->[0]][0]}@{$states[0][2]});
   defined$terminal or die 'later dense missing terminal';
   $c.=$packed.$terminal;
   return$c;
};
