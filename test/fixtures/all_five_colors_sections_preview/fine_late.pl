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
   # Each parity shares one body, so a donor must be unused across ALL of its
   # rows. Refills5/6 may move into any free pair1..4 without changing their
   # dependencies. Prefer the original2/4 locations to minimize layout churn.
   my(%donors,%swap6);
   for my$side(qw(A B)){
      my%free=map{$_=>1}grep{!$phases{$side}{$_*2}}1..4;
      for my$target(5,6){
         next if$adaptive&&!$phases{$side}{$target*2};
         my$preferred=$target==5?2:4;
         my$donor=(!$adaptive||$free{$preferred})?$preferred:(sort{$a<=>$b}keys%free)[0];
         defined$donor or die "mixed refill conflicts in $side rows\n";
         $donors{$side}{$target}=$donor;delete$free{$donor};
         $swap6{$side}=1 if$target==6;
      }
   }
   my$build=do "$repo/test/fixtures/all_five_colors_sections_preview/fine_spread.pl";
   die$@ if$@;ref$build eq 'CODE' or die 'late base helper';
   my$c=$build->(@_);
   for my$side(qw(A B)){
      for my$target(5,6){
         next unless exists$donors{$side}{$target};
         my$donor=$donors{$side}{$target};my$after=$donor+1;
         my($palette)=$c =~ /(   asm \@TEMPLATE_${side}_u$donor:;.*?)(?=   \/\/ $side pair $after:)/s;
         my($refill)=$target==5
            ?$c =~ /(   asm \@TEMPLATE_${side}_u5:;.*?)(?=   \/\/ $side pair 6:)/s
            :$c =~ /(   asm \@TEMPLATE_${side}_u6:;.*?)(?=   \/\/ $side pair 7)/s;
         defined$palette&&defined$refill or die 'adaptive refill pair';
         my$newpalette=$palette;my$newrefill=$refill;
         $newpalette =~ s/TEMPLATE_${side}_u$donor/TEMPLATE_${side}_u$target/g;
         my$plane=$donor==4?1:0;my$index=$donor==4?0:$donor;my$dest=$target-4;
         $newpalette =~ s/TEMPLATE_sections_(pf|bk)$plane \+ $index/TEMPLATE_sections_${1}1 + $dest/g;
         $newrefill =~ s/TEMPLATE_${side}_u$target/TEMPLATE_${side}_u$donor/g;
         # Pair6 must retain the RTS dispatch. Replacing its donor's LSR5
         # with RTS6 is balanced by CPYzp3 instead of CPYabs4. Its relocated
         # refill ends with LSR5/NOP2 instead; no mask shift is lost.
         if($target==6){my$bl=$side eq 'A'?0:3;
            $newrefill =~ s/   asm rts;/   asm lsr.z TEMPLATE_row_cache + $bl;\n   asm nop;/ or die 'adaptive donor tail';
            $newpalette =~ s/   asm lsr.z TEMPLATE_row_cache \+ $bl;\n\z/   asm rts;\n/ or die 'adaptive return';
            $newpalette =~ s/cpy.a TEMPLATE_player0_height/cpy.z TEMPLATE_player0_height/ or die 'adaptive CPY';
         }
         $c =~ s/\Q$palette\E/$newrefill/ or die 'adaptive donor';
         $c =~ s/\Q$refill\E/$newpalette/ or die 'adaptive receiver';
      }
      if($swap6{$side}){
         $c =~ s/(   asm \@TEMPLATE_fine_${side}_[0-7T]_u7:;\n   asm lda.ay TEMPLATE_player0_colors,y;\n)   asm sta.a COLUP0;/$1   asm sta COLUP0;/g;
      }
   }
   my$layout=do "$repo/test/fixtures/all_five_colors_sections_preview/fine_layout.pl";
   die$@ if$@;ref$layout eq 'CODE' or die 'normal layout helper';
   my%ranges;
   for my$side(qw(A B)){
      my($body)=$c =~ /(   asm \@TEMPLATE_${side}_u1:;.*?)(?=   \/\/ $side pair 7)/s;
      defined$body or die 'adaptive normal body';$ranges{$side}=$layout->($body);
   }
   # Choose explicit anchors from the exact normal-row branch layout. The
   # sizing model is strict and final assembler contracts remain authoritative.
   my$choose=sub{
      my($cursor,$rs)=@_;
      for my$pad(0..255){my$ph=($cursor+$pad)%256;return$ph if grep{$ph>=$_->[0]&&$ph<=$_->[1]}@$rs;}
      die 'late phase packing';
   };
   my$cursor=$choose->(0x94,$ranges{A});
   for my$side(qw(A B)){
      my$normal=$side eq 'A'?$cursor:$choose->($cursor,$ranges{$side});my$hex=sprintf('%02x',$normal);
      $c =~ s/   asm \.align 256, \$[\da-f]+;\n(?=(?:   \/\/[^\n]*\n)?   asm \@TEMPLATE_${side}_u1:;)/   asm .align 256, \$$hex;\n/ or die 'late normal anchor';
      $cursor=$normal+687;
      $c =~ s/   asm \.align 256, \$[\da-f]+;\n(?=   asm \@TEMPLATE_fine_${side}_[0-7T]_u7_p1_zero:;)/
         my$ph=$choose->($cursor,$swap6{$side}?[[0,132],[149,195]]:[[0,131],[148,194]]);$cursor=$ph+($swap6{$side}?126:127);
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
