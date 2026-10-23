# Private late-refill feasibility schedule, not a public geometry generator.
use strict;
use warnings;
return sub {
   my($repo,$heights,undef,undef,undef,undef,$adaptive)=@_;
   my$end=0;my%phases;
   for(@$heights){
      $end+=$_;
      $phases{int($end/16)%2?'B':'A'}{$end%16}=1 if$end>0&&$end<192;
      die "late refill conflicts with palette phase ".($end%16)."\n"
         if!$adaptive&&$end>0&&$end<192&&($end%16==4||$end%16==8);
   }
   my%late;
   for my$side(qw(A B)){
      $late{$side}=!$adaptive||$phases{$side}{10}||$phases{$side}{12};
      die "mixed refill conflicts in $side rows\n" if$adaptive&&$late{$side}&&($phases{$side}{4}||$phases{$side}{8});
   }
   my$build=do "$repo/test/fixtures/all_five_colors_sections_preview/fine_spread.pl";
   die$@ if$@;ref$build eq 'CODE' or die 'late base helper';
   my$c=$build->(@_);
   for my$side(qw(A B)){
      next unless$late{$side};
      # Pair2's unused phase4 slot takes next BL's seven-cycle refill from
      # pair5. Pair5 gets the existing exact-phase palette schedule instead.
      my($two)=$c =~ /(   asm \@TEMPLATE_${side}_u2:;.*?)(?=   \/\/ $side pair 3:)/s;
      my($five)=$c =~ /(   asm \@TEMPLATE_${side}_u5:;.*?)(?=   \/\/ $side pair 6:)/s;
      defined$two&&defined$five or die 'late phase10 pairs';
      my$newfive=$two;my$newtwo=$five;
      $newfive =~ s/TEMPLATE_${side}_u2/TEMPLATE_${side}_u5/g;
      $newfive =~ s/TEMPLATE_sections_(pf|bk)0 \+ 2/TEMPLATE_sections_${1}1 + 1/g;
      $newtwo =~ s/TEMPLATE_${side}_u5/TEMPLATE_${side}_u2/g;
      $c =~ s/\Q$two\E/$newtwo/ or die 'late phase10 donor';
      $c =~ s/\Q$five\E/$newfive/ or die 'late phase10 receiver';
      # Pair4 similarly takes next M1's refill plus the row-X save from pair6.
      # The old RTS tail becomes ordinary shift5/NOP2. Pair6's palette tail
      # uses RTS6 instead of shift5; zero-page CPY saves its extra cycle.
      my($four)=$c =~ /(   asm \@TEMPLATE_${side}_u4:;.*?)(?=   \/\/ $side pair 5:)/s;
      my($six)=$c =~ /(   asm \@TEMPLATE_${side}_u6:;.*?)(?=   \/\/ $side pair 7)/s;
      defined$four&&defined$six or die 'late phase12 pairs';
      my$newfour=$six;my$newsix=$four;my$bl=$side eq 'A'?0:3;
      $newfour =~ s/TEMPLATE_${side}_u6/TEMPLATE_${side}_u4/g;
      $newfour =~ s/   asm rts;/   asm lsr.z TEMPLATE_row_cache + $bl;\n   asm nop;/ or die 'late donor tail';
      $newsix =~ s/TEMPLATE_${side}_u4/TEMPLATE_${side}_u6/g;
      $newsix =~ s/TEMPLATE_sections_(pf|bk)1 \+ 0/TEMPLATE_sections_${1}1 + 2/g;
      $newsix =~ s/   asm lsr.z TEMPLATE_row_cache \+ $bl;\n\z/   asm rts;\n/ or die 'late return';
      $newsix =~ s/cpy.a TEMPLATE_player0_height/cpy.z TEMPLATE_player0_height/ or die 'late CPY phase';
      $c =~ s/\Q$four\E/$newfour/ or die 'late phase12 donor';
      $c =~ s/\Q$six\E/$newsix/ or die 'late phase12 receiver';
      # Pair6 is back to 152 cycles, so remove the old 151-cycle dispatch's
      # compensating absolute COLUP0. Strict right-edge probes guard this phase.
      $c =~ s/(   asm \@TEMPLATE_fine_${side}_[0-7T]_u7:;\n   asm lda.ay TEMPLATE_player0_colors,y;\n)   asm sta.a COLUP0;/$1   asm sta COLUP0;/g;
   }
   # Same 687-byte normal bodies with changed branch offsets; packed bodies
   # shrink to126. These are preferences; final .same/.cross remain mandatory.
   my@ranges=([10,35],[41,62],[68,79],[95,106],[122,135],[155,175],[181,197],[213,223],[239,250]);
   my@early=([6,34],[40,60],[66,82],[98,108],[124,132],[148,149],[155,175],[181,197],[213,223],[239,246]);
   my$choose=sub{
      my($cursor,$rs)=@_;
      for my$pad(0..255){my$ph=($cursor+$pad)%256;return$ph if grep{$ph>=$_->[0]&&$ph<=$_->[1]}@$rs;}
      die 'late phase packing';
   };
   my$cursor=$late{A}?0x9b:0x94;
   for my$side(qw(A B)){
      my$normal=$side eq 'A'?$cursor:$choose->($cursor,$late{$side}?\@ranges:\@early);my$hex=sprintf('%02x',$normal);
      $c =~ s/   asm \.align 256, \$[\da-f]+;\n(?=(?:   \/\/[^\n]*\n)?   asm \@TEMPLATE_${side}_u1:;)/   asm .align 256, \$$hex;\n/ or die 'late normal anchor';
      $cursor=$normal+687;
      $c =~ s/   asm \.align 256, \$[\da-f]+;\n(?=   asm \@TEMPLATE_fine_${side}_[0-7T]_u7_p1_zero:;)/
         my$ph=$choose->($cursor,$late{$side}?[[0,132],[149,195]]:[[0,131],[148,194]]);$cursor=$ph+($late{$side}?126:127);
         sprintf("   asm .align 256, \$%02x;\n",$ph)
      /ge;
   }
   for my$spec(['A_boundary',120],['B_boundary',120],['fine_terminal',0]){
      my($name,$size)=@$spec;my$ph=$choose->($cursor,[[0,147],[153,203],[214,255]]);
      $cursor=$ph+$size;my$hex=sprintf('%02x',$ph);
      $c =~ s/   asm \.align 256, \$[\da-f]+;\n(?=   asm \@TEMPLATE_$name:;)/   asm .align 256, \$$hex;\n/ or die 'late boundary anchor';
   }
   return$c;
};
