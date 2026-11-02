#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: relocation order ok
# expectexit: 0

use strict;
use warnings;
my($repo,$tmp)=@ARGV;
open(my$f,'>',"$tmp/order.c26")or die$!;
print$f <<'C26';
include "vcs.c26"
void main(void) {
   asm jmp @continuation;
   asm .proc inner;
   asm inner_entry:;
   asm .byte $31,$42,$53;
   asm jmp inner_entry;
   asm .endproc;
   asm @continuation:;
   asm .byte $64,$75,$86;
   asm .word inner_entry;
   while (true) {}
}
C26
close$f;
system("$repo/driver/vcsc",'-I',"$repo/libraries/vcs","$tmp/order.c26",'-o',"$tmp/order.bin")==0 or die 'resumed-layout link';
open($f,'<',"$tmp/order.bin")or die$!;binmode$f;local$/;my$bin=<$f>;close$f;
my$inner=index($bin,"\x31\x42\x53\x4c");my$outer=index($bin,"\x64\x75\x86");
$inner>=0&&$outer>=0 or die 'nested/resumed layout absent';
my$target=pack('v',0xf000+$inner);
substr($bin,$inner+4,2)eq$target&&substr($bin,$outer+3,2)eq$target or die 'nonmonotonic-source relocation corrupted';
print "relocation order ok\n";
