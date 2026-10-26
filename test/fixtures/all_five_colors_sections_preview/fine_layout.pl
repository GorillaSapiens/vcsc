# Strict byte-layout model for PRIVATE generated row/tail blocks. This only
# chooses compact page anchors; actual assembler .same/.cross stays mandatory.
use strict;
use warnings;
return sub {
   my($body,$expected)=@_;$expected//=687;my$pc=0;my(%labels,@edges);
   for my$line(split /\n/,$body){
      $line =~ s/\/\/.*//;$line =~ s/^\s+|\s+$//g;next if$line eq '';
      if($line =~ /^asm (\@\w+):;$/){$labels{$1}=$pc;next;}
      next if$line =~ /^asm TEMPLATE_\w+ = \@\w+;$/;
      if($line =~ /^PF[12] := TEMPLATE_(?:even|odd)_pf[0-3];$/){$pc+=4;next;}
      if($line =~ /^COLU(?:PF|BK) := \d+;$/){$pc+=4;next;}
      $line =~ /^asm ([a-z]+)(?:\.([a-z]+))?(?: (.*?))?;$/ or die "unknown normal-row statement: $line\n";
      my($op,$mode,$arg)=($1,$2,$3);my$bytes;
      if($op =~ /^b(?:cc|cs|eq|ne|mi|pl|vc|vs)$/){
         defined$mode&&($mode eq 'same'||$mode eq 'cross')&&defined$arg or die 'uncontracted row branch';
         push@edges,[$pc+2,$arg,$mode];$bytes=2;
      }elsif($op eq 'jmp'||$op eq 'jsr'){$bytes=3;}
      elsif(defined$mode){
         $bytes=$mode =~ /^(?:z|zx|zy|ix|iy)$/?2:$mode =~ /^(?:a|ax|ay)$/?3:0;
         $bytes or die "unknown row addressing mode: $line\n";
      }elsif(!defined$arg){$bytes=1;}
      elsif($arg =~ /^#/){$bytes=2;}
      elsif($arg =~ /^(?:PF[012]|COLUP[01F]|COLUBK|GRP[01]|ENAM[01]|ENABL|WSYNC)$/){$bytes=2;}
      else{die "unmodelled normal-row operand: $line\n";}
      $pc+=$bytes;
   }
   $pc==$expected or die "row block changed byte size: $pc != $expected\n";
   my@phases;
   PHASE:for my$phase(0..255){
      for my$edge(@edges){my($from,$target,$kind)=@$edge;
         exists$labels{$target} or die "normal row has external branch: $target\n";
         my$to=$labels{$target};my$distance=$to-$from;
         $distance>=-128&&$distance<=127 or die 'normal row needs long branch';
         my$same=int(($phase+$from)/256)==int(($phase+$to)/256);
         next PHASE if$same!=($kind eq 'same');
      }
      push@phases,[$phase,$phase];
   }
   @phases or die 'normal row has no legal page phase';
   return\@phases;
};
