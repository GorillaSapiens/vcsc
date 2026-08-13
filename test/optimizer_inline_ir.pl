#!/usr/bin/perl
# runner: perl @FILE@ @VCSC_CC1@ @TEST_ROOT@
# phase: compile
# timeout: 45
# expectexit: 0
# expectstdout: optimizer inline IR tests passed

use strict;
use warnings;
use File::Temp qw(tempdir);
use File::Spec;

my ($cc1,$test_root)=@ARGV;
die "usage: $0 vcsc-cc1 test_root\n" unless defined $cc1 && defined $test_root;
my $tmp=tempdir('VCSC_optimizer_inline_XXXX',TMPDIR=>1,CLEANUP=>1);
my $src=File::Spec->catfile($tmp,'optimizer_inline.c26');
my $forced=File::Spec->catfile($tmp,'forced.s26');
my $normal=File::Spec->catfile($tmp,'normal.s26');
open my $fh,'>',$src or die "write $src: $!";
print {$fh} <<'C26';
include "machine_6502.c26"

static void touch(void) {
   uint8_t local := 3;
   local++;
}
static uint8_t choose(uint8_t x) {
   uint8_t y := x + 1;
   if (x) { return y; }
   return 7;
}
/* Defined in reverse chain order on purpose. */
static uint8_t leaf(uint8_t x) {
   return x + 2;
}
static uint8_t middle(uint8_t x) {
   return leaf(x) + 1;
}
/* Inline asm is a temporary section-3 veto. */
static void asm_veto(void) {
   asm nop;
}

void main(void) {
   uint8_t value := 1;
   touch();
   value := choose(value);
   value := middle(value);
   asm_veto();
}
C26
close $fh;

system($cc1,'-quiet','-I',$test_root,'-X','inlineir',$src,'-o',$forced)==0
   or die "forced optimizer-inline compile failed\n";
system($cc1,'-quiet','-I',$test_root,$src,'-o',$normal)==0
   or die "normal compile failed\n";

sub slurp { my($p)=@_; open my$f,'<',$p or die "read $p: $!"; local$/; my$t=<$f>//''; close$f; return$t; }
my $f=slurp($forced); my $n=slurp($normal);
sub req { my($name,$text,$re)=@_; $text =~ $re or die "$name missing\n--- asm ---\n$text"; }
sub forbid { my($name,$text,$re)=@_; $text !~ $re or die "$name unexpectedly present\n--- asm ---\n$text"; }

for my $name (qw(touch choose leaf middle)) {
   forbid("forced standalone $name",$f,qr/^\.proc\s+\Q$name\E\b/m);
   forbid("forced jsr $name",$f,qr/\bjsr\s+\Q$name\E\b/);
   req("normal standalone $name",$n,qr/^\.proc\s+\Q$name\E\b/m);
}
req('void optimizer expansion',$f,qr/begin optimizer inline expansion touch\b/);
req('value optimizer expansion',$f,qr/begin optimizer inline expansion choose\b/);
req('nested middle expansion',$f,qr/begin optimizer inline expansion middle\b.*?begin optimizer inline expansion leaf\b/s);
req('optimizer local renamed',$f,qr/^touch\$local:\s*$/m);
req('multi-return expansion return label',$f,qr/begin optimizer inline expansion choose\b.*?jmp\s+\@optinline_\d+_return\b.*?\@optinline_\d+_return:/s);
req('asm veto remains standalone',$f,qr/^\.proc\s+asm_veto\b/m);
req('asm veto remains call',$f,qr/\bjsr\s+asm_veto\b/);
req('source remains ordinary without force',$n,qr/\bjsr\s+touch\b.*?\bjsr\s+choose\b.*?\bjsr\s+middle\b/s);

print "optimizer inline IR tests passed\n";
