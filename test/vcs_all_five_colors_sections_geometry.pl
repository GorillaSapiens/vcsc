#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 180
# expectstdout: combined-colour row geometry ok
# expectexit: 0
use strict;
use warnings;
use IPC::Open3;
use Symbol qw(gensym);
my($repo,$tmp)=@ARGV;
sub slurp { open(my$f,'<:raw',$_[0])or die$!;local$/;return<$f>; }
sub save { open(my$f,'>',$_[0])or die$!;print{$f}$_[1];close$f or die$!; }
sub compile {
   my($name,$source,$error)=@_;
   save("$tmp/$name.c26",$source);
   my$err=gensym;my$p=open3(my$i,my$o,$err,"$repo/driver/vcsc",'-I',"$repo/libraries/vcs","$tmp/$name.c26",'-o',"$tmp/$name.bin");close$i;
   local$/;my$out=<$o>//'';my$e=<$err>//'';waitpid($p,0);
   if(defined$error){$?!=0&&index($out.$e,$error)>=0 or die"$name did not reject geometry: $out$e";}
   else{$?==0 or die"$name failed: $out$e";}
}
my$fixture="$repo/test/fixtures/all_five_colors_sections_preview";
my$source=slurp("$fixture/interactive.c26");
$source =~ s#"(component|sprites).c26"#"$fixture/$1.c26"#g;
my@pf=(0x2e,0x46,0x8e,0xae,0xce,0x6a,0x1a,0x5e);
my@bk=(0x84,0xc2,0x26,0x64,0x42,0x12,0xa2,0xe2);
for my$n(1..8){
   $source =~ s/(section${n}_colupf:=)0x[0-9a-f]+/$1$pf[$n-1]/ or die'PF parameter';
   $source =~ s/(section${n}_colubk:=)0x[0-9a-f]+/$1$bk[$n-1]/ or die'BK parameter';
}
sub configured {
   my$heights=shift;my$s=$source;
   for my$n(1..8){$s =~ s/(section${n}_lines:=)\d+/$1$heights->[$n-1]/ or die'height parameter';}
   return$s;
}
my@layouts=(
   [16,16,16,16,32,32,32,32], [32,16,48,16,16,16,32,16],
   [16,0,32,0,48,0,80,16], [192,0,0,0,0,0,0,0],
   [16,176,0,0,0,0,0,0], [176,0,0,0,0,0,0,16]);
# Move the four extra rows to each slot: all eight feeds must be independent.
for my$n(0..7){my@h=(16)x8;$h[$n]+=64;push@layouts,\@h;}
for my$i(0..$#layouts){
   my$h=$layouts[$i];my$name="layout$i";compile($name,configured($h));
   my$rom=slurp("$tmp/$name.bin");length($rom)==8192 or die'geometry changed mapper';
   my$sym=slurp("$tmp/$name.sym");
   for my$which(0,1){
      my$label='game_sections_'.($which?'bk':'pf');
      $sym =~ /^\Q$label\E\s+([0-9a-fA-F]{4})\s*$/m or die"missing $label";
      my$a=hex$1;($a&255)+48<=256 or die'palette escaped page';
      my@col=$which?@bk:@pf;my@expected;
      for my$n(0..7){push@expected,($col[$n])x($h->[$n]/4);}
      substr($rom,4096+($a&4095),48)eq pack('C*',@expected) or die"$name $label selection mismatch";
   }
}
my@bad=(
   [[16,16,16,16,32,32,32,16],'must total 192'],
   [[0,32,16,16,32,32,32,32],'must be nonempty'],
   [[16,16,16,16,32,32,80,-16],'requires an integer literal'],
   [[2,4,8,16,32,48,64,18],'must be multiples of 16']);
for my$i(0..$#bad){compile("bad$i",configured($bad[$i][0]),$bad[$i][1]);}
print "combined-colour row geometry ok\n";
