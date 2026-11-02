# Private lowering proof: let final-link branch contracts place whole blocks.
use strict;
use warnings;
return sub {
   my($c)=@_;my@blocks;
   $c=~s{   asm \.align 256, \$[\da-f]+;\n(.*?)(?=   asm \.align 256, \$[\da-f]+;|\n\})}{
      my$id=@blocks;push@blocks,$1;"GLOBAL_BLOCK_$id\n"
   }sge;
   $c=~s{   asm \.align 256;\n(.*?)(?=GLOBAL_BLOCK_\d+\n)}{
      my$id=@blocks;push@blocks,"   asm .align 256;\n".$1;"GLOBAL_BLOCK_$id\n"
   }se or die 'global procedure route block';
   for my$id(0..$#blocks){next unless$blocks[$id]=~s/(   asm \@TEMPLATE_fine_close:;.*)\z//s;my$close=$1;
      $blocks[$id]=~s/asm ldx.z TEMPLATE_saved_s;/asm ldx.a TEMPLATE_saved_s;/ or die 'global procedure terminal restore';
      $blocks[$id]=~s/   asm nop;\n   asm nop;\n\s*\z/   asm jmp \@TEMPLATE_fine_close;\n/ or die 'global procedure terminal jump';
      $c=~s/(GLOBAL_BLOCK_$id\n)/$1$close/ or die 'global procedure close continuation';
   }
   my%owner;for my$id(-1..$#blocks){my$text=$id<0?$c:$blocks[$id];while($text=~/asm \@(TEMPLATE_\w+):;/g){exists$owner{$1} and die 'duplicate global procedure label';$owner{$1}=$id;}}
   my%external;
   for my$id(-1..$#blocks){my$text=$id<0?$c:$blocks[$id];while($text=~/\@(TEMPLATE_\w+)(?!\w)(?!:;)/g){my$name=$1;next unless exists$owner{$name};$external{$name}=1 if$owner{$name}!=$id;}}
   my@names=sort keys%external;my%entry;my$serial=0;$entry{$_}='TEMPLATE_link_entry_'.$serial++ for@names;
   for my$id(-1..$#blocks){my$text=$id<0?$c:$blocks[$id];
      for my$name(@names){my$target=$entry{$name};
         $text=~s/\@\Q$name\E(?!\w)(?!:;)/$target/g;
         $text=~s/(   asm \@\Q$name\E:;)/   asm .scope ${target}_scope;\n   asm $target:;\n   asm .endscope;\n$1/g;
      }
      if($id<0){$c=$text;}else{$blocks[$id]="   asm .proc TEMPLATE_schedule_block_$id;\n".$text."   asm .endproc;\n";}
   }
   $c=~s/GLOBAL_BLOCK_(\d+)\n/$blocks[$1]/ge;
   return$c;
};
