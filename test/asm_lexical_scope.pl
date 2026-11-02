#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: lexical scope ok
# expectexit: 0

use strict;
use warnings;
my($repo,$tmp)=@ARGV;
open(my$f,'>',"$tmp/scope.c26")or die$!;
print$f <<'C26';
include "vcs.c26"
void main(void) {
   asm jmp @start;
   asm @before:;
   asm .byte $11;
   asm .scope first;
   asm scope_anchor_a:;
   asm .byte $22;
   asm .scope nested;
   asm scope_anchor_b:;
   asm .byte $33;
   asm .endscope;
   asm .endscope;
   asm @start:;
   asm .byte $42,$43,$44;
   asm .word scope_anchor_a,scope_anchor_b,@before;
   while (true) {}
}
C26
close$f;
system("$repo/driver/vcsc",'-I',"$repo/libraries/vcs","$tmp/scope.c26",'-o',"$tmp/scope.bin")==0 or die 'scope link';
open($f,'<',"$tmp/scope.bin")or die$!;binmode$f;local$/;my$bin=<$f>;close$f;
my$pos=index($bin,"\x11\x22\x33\x42\x43\x44");$pos>=0 or die 'scope changed enclosing placement';
substr($bin,$pos+6,6)eq pack('v3',0xf000+$pos+1,0xf000+$pos+2,0xf000+$pos) or die 'scope relocation/local restoration';
print "lexical scope ok\n";
