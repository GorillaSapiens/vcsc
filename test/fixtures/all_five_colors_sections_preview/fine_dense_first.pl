# Private first-row dense proof. All section seams must be within row zero.
use strict;
use warnings;
return sub {
   my($repo,$heights,$pal,$bad)=@_;
   my$end=0;my$key;
   for my$n(0..7){
      $end+=$heights->[$n];
      die "dense first-row seam outside row zero\n" if$end>14&&$end<192;
      $key=$n%scalar(@$pal) if!defined$key&&$end>14;
   }
   my$base=do "$repo/test/fixtures/all_five_colors_sections_preview/fine_spread.pl";
   die$@ if$@;ref$base eq 'CODE' or die 'dense base helper';
   my$c=$base->(@_);
   my($normal)=$c =~ /(   asm \@TEMPLATE_A_u1:;.*?)(?=   \/\/ A pair 7)/s;
   defined$normal or die 'dense normal';my$dense=$normal;
   # Both caches are primed before drawing. Only this first A row can omit
   # the BL/M1 refills without borrowing another palette slot. Later A rows
   # retain the ordinary live-refill schedule and their independently timed
   # packed routes. No graphics tables are duplicated.
   for my$spec([2,5],[4,6]){
      my($from,$to)=@$spec;my$next=$from+1;
      my($pair)=$normal =~ /(   asm \@TEMPLATE_A_u$from:;.*?)(?=   \/\/ A pair $next:)/s;
      my($old)=$to==5
         ?$dense =~ /(   asm \@TEMPLATE_A_u5:;.*?)(?=   \/\/ A pair 6:)/s
         :$dense =~ /(   asm \@TEMPLATE_A_u6:;.*)\z/s;
      defined$pair&&defined$old or die 'dense pair';
      $pair =~ s/TEMPLATE_A_u$from/TEMPLATE_A_u$to/g;
      $pair =~ s/\@TEMPLATE_(fine_barrier|rts_fold)_/\@TEMPLATE_copy${to}_${1}_/g;
      my$oldplane=$from==2?0:1;my$oldindex=$from==2?2:0;my$newindex=$to-4;
      $pair =~ s/TEMPLATE_sections_(pf|bk)$oldplane \+ $oldindex/TEMPLATE_sections_${1}1 + $newindex/g;
      if($to==6){
         $pair =~ s/   asm lsr.z TEMPLATE_row_cache \+ 0;\n\z/   asm rts;\n/ or die 'dense return';
         $pair =~ s/cpy.a TEMPLATE_player0_height/cpy.z TEMPLATE_player0_height/ or die 'dense CPY';
      }
      $dense =~ s/\Q$old\E/$pair/ or die 'dense replace';
   }
   $dense =~ s/\@TEMPLATE_/\@TEMPLATE_dense_/g;
   $c =~ s/(   asm \.align 256, \$94;)/   asm .align 256, \$dd;\n$dense$1/ or die 'dense insert';
   $c =~ s/   asm jmp \@TEMPLATE_A_u1;/   asm jmp \@TEMPLATE_dense_A_u1;/ or die 'dense entry';
   # The first-row X value is known before drawing. Later rows still use
   # their runtime STX save. Keep this after the banked preparation returns.
   $c =~ s/(   asm sta.z TEMPLATE_packed_p1_zero;)/$1\n   asm lda #0;\n   asm sta.z TEMPLATE_packed_row;/ or die 'dense row index';
   my($packed)=$c =~ /(   asm \.align 256, \$[\da-f]+;\n   asm \@TEMPLATE_fine_A_${key}_u7_p1_zero:;.*?)(?=   asm \.align 256, \$[\da-f]+;)/s;
   defined$packed or die 'dense packed';my$extra=$packed;
   $extra =~ s/TEMPLATE_fine_(addr_)?A_$key/'TEMPLATE_fine_'.(defined$1?$1:'').'A_D'/ge;
   $extra =~ s/\@TEMPLATE_(fine_barrier|rts_fold)_/\@TEMPLATE_dense_packed_${1}_/g;
   $extra =~ s/(   asm lda.ay TEMPLATE_player0_colors,y;\n)   asm sta.a COLUP0;/$1   asm sta COLUP0;/ or die 'dense packed phase';
   # All later packed rows share the final palette, so a wrong route there
   # cannot change its colour. Mutate this distinct first-row tail instead.
   $extra =~ s/COLUPF := \d+;/COLUPF := $pal->[0][0];/ or die 'dense palette mutation' if$bad;
   $c =~ s/(   asm \.align 256, \$[\da-f]+;\n   asm \@TEMPLATE_B_u1:;)/$extra$1/ or die 'dense extra route';
   for my$byte('<','>'){
      $c =~ s/(   asm lda #\Q$byte\E\{main \+ TEMPLATE_fine_addr_A_)$key( - 1\};)/${1}D$2/ or die 'dense first route';
   }
   # All seams are in row zero, so exactly one ordinary A palette, its dense
   # route, one ordinary B palette and B terminal are needed. Pack those fixed
   # 127/126/687/127/127/120/120-byte bodies without an extra page per tail.
   for my$anchor(["fine_A_${key}_u7_p1_zero",'43'],['fine_A_D_u7_p1_zero','c2'],
      ['B_u1','42'],["fine_B_${key}_u7_p1_zero",'00'],['fine_B_T_u7_p1_zero','7f'],
      ['A_boundary','fe'],['B_boundary','76'],['fine_terminal','ee']){
      my($label,$phase)=@$anchor;
      $c =~ s/   asm \.align 256, \$[\da-f]+;\n(?=   asm \@TEMPLATE_$label:;)/   asm .align 256, \$$phase;\n/ or die 'dense compact anchor';
   }
   return$c;
};
