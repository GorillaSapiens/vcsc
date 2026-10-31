#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectexit: 0
# expectstdout: instruction location counter passed
# expectstderrexact:

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use IPC::Open3;
use Symbol qw(gensym);

my($repo,$tmp)=@ARGV;
$repo=abs_path($repo);
make_path($tmp);
$tmp=abs_path($tmp);
sub save {
   my($path,$text)=@_;
   open(my$f,'>:raw',$path) or die "$path: $!";
   print {$f} $text;
   close($f) or die $!;
}
sub read_file {
   open(my$f,'<:raw',$_[0]) or die "$_[0]: $!";
   local $/; return <$f>;
}
sub run {
   my$err=gensym;
   my$pid=open3(my$in,my$out,$err,@_);
   close($in);
   local $/;
   my$o=<$out>//'';my$e=<$err>//'';
   waitpid($pid,0);
   die "@_ failed ($?):\n$o$e" if $? || length($e);
}
sub hex_bytes {
   my($path,$base,$size)=@_;my%mem;
   for(split /\n/,read_file($path)){
      next unless /^:([0-9A-F]{2})([0-9A-F]{4})00([0-9A-F]*)/i;
      my($len,$addr,$data)=(hex($1),hex($2),$3);
      $mem{$addr+$_}=hex(substr($data,2*$_,2)) for 0..$len-1;
   }
   return pack('C*',map{defined($mem{$_})?$mem{$_}:die "missing hex address $_"}$base..$base+$size-1);
}
sub expected {
   my($base)=@_;
   # JMP next; LDA #<self; LDX #>self; BNE self; expanded BNE far.
   return pack('CvCCCCCCCCCvCC',0x4c,$base+3,0xa9,($base+3)&255,
      0xa2,(($base+5)>>8)&255,0xd0,0xfe,0xf0,3,0x4c,$base+9+132,
      0xd0,0x7f);
}
my$body=<<'ASM';
jmp *+3
lda #<*
ldx #>*
bne *
bne *+132
bne *+129
.res 132
ASM
# Explicit-label equivalents independently anchor '*' to the opcode address.
my$labels=<<'ASM';
jmp next
next: lda #<next
high: ldx #>high
loop: bne loop
far: bne far+132
forward: bne forward+129
.res 132
ASM
my$size=16;
for my$base(0x2000,0xf0fd){
   my$want=expected($base);
   for my$case(['pc',$body],['labels',$labels]){
      my($name,$code)=@$case;
      my$stem="$tmp/flat_${base}_$name";
      save("$stem.s26",sprintf(".segmentdef \"CODE\", \$%04x, \$1000\n.segment \"CODE\"\n",$base).$code);
      run("$repo/assembler/vcsc-as","--hex=$stem.hex","$stem.s26");
      die "flat $name at $base differs from exact bytes\n" unless hex_bytes("$stem.hex",$base,$size) eq $want;
      # An unrelated text layout precedes the tested layout in the object.
      # Moving the linked ROM origin must also move every '*' target.
      $stem="$tmp/object_${base}_$name";
      save("$stem.s26",".segment \"CODE.prefix\"\n.export __reset, __nmi, __irqbrk\n__reset:\n__nmi:\n__irqbrk:\n.byte \$ea\n.segment \"CODE.test\"\n".$code);
      save("$stem.cfg",sprintf(<<'CFG',$base-1));
MEMORY {
 ROM: start = $%04x, size = $0800, type = ro;
 ZP: start = $00, size = $100, type = rw;
 RAM: start = $0200, size = $1000, type = rw;
}
SEGMENTS {
 CODE.prefix: load = ROM, type = ro;
 CODE.test: load = ROM, type = ro;
 CODE: load = ROM, type = ro;
 DATA: load = ROM, run = RAM, type = data;
 BSS: load = RAM, type = bss;
 ZEROPAGE: load = ROM, run = ZP, type = zp;
}
CFG
      run("$repo/assembler/vcsc-as","-o","$stem.o26","$stem.s26");
      run("$repo/linker/vcsc-ld",'-T',"$stem.cfg",'-o',"$stem.bin","$stem.o26");
      die "relocated $name at $base differs from exact bytes\n" unless substr(read_file("$stem.bin"),0,1+$size) eq "\xea".$want;
   }
}
# A logical .rorg PC, not the physical output address, supplies '*'.
my$stem="$tmp/rorg";
save("$stem.s26",".segmentdef \"CODE\", \$8000, \$1000\n.segment \"CODE\"\n.rorg \$f0fd\n".$body.".rend\n");
run("$repo/assembler/vcsc-as","--hex=$stem.hex","$stem.s26");
die "rorg instruction PC differs\n" unless hex_bytes("$stem.hex",0x8000,$size) eq expected(0xf0fd);
save("$stem.s26",".segment \"CODE\"\n.rorg \$f0fd\n.export __reset, __nmi, __irqbrk\n__reset:\n__nmi:\n__irqbrk:\n".$body.".rend\n");
run("$repo/assembler/vcsc-as",'-o',"$stem.o26","$stem.s26");
run("$repo/linker/vcsc-ld",'-T',"$tmp/object_8192_pc.cfg",'-o',"$stem.bin","$stem.o26");
die "rorg object instruction PC differs\n" unless substr(read_file("$stem.bin"),0,$size) eq expected(0xf0fd);
print "instruction location counter passed\n";
