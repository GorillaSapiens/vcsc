#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: compile
# timeout: 60
# expectstdout: Optimizer inline identity tests passed
# expectexit: 0

use strict;
use warnings;
use File::Spec;

sub write_file { my($p,$t)=@_; open my$f,'>:raw',$p or die "write $p: $!"; print {$f} $t; close $f; }
sub read_file { my($p)=@_; open my$f,'<:raw',$p or die "read $p: $!"; local$/; return <$f>//''; }

my($repo,$tmp)=@ARGV; die "usage: $0 REPO TMP\n" unless defined $repo && defined $tmp;
my$cc1=File::Spec->catfile($repo,qw(compiler vcsc-cc1));
my$inc=File::Spec->catdir($repo,'test');
my$src=File::Spec->catfile($tmp,'inline-identity.c26');
my$asm=File::Spec->catfile($tmp,'inline-identity.s26');
my$forced=File::Spec->catfile($tmp,'inline-identity-forced.s26');
my$manifest=File::Spec->catfile($tmp,'inline-identity.candidates');

write_file($src, <<'SRC');
include "machine_6502.c26"
static uint8_t safe(uint8_t x) { return x + 1; }
static uint8_t asm_body(uint8_t x) { asm nop; return x + 2; }
static uint8_t asm_named(uint8_t x) { return x + 3; }
static uint8_t abi_family(uint8_t x) { return x + 4; }
recommend static uint8_t contracted(uint8_t x);
static uint8_t contracted(uint8_t x) { return x + 5; }
uint8_t exported(uint8_t x) { return x + 6; }
inline uint8_t source_inline(uint8_t x) { return x + 7; }
static uint8_t dead(uint8_t x) { return x + 8; }
void registry(void) { asm .word asm_named; asm .word abi_family$x; }
void main(void) {
   uint8_t y;
   y := safe(1);
   y := asm_body(y);
   y := asm_named(y);
   y := abi_family(y);
   y := contracted(y);
   y := exported(y);
   y := source_inline(y);
}
SRC

system($cc1,'-quiet','-I',$inc,'-finline-candidates',$manifest,$src,'-o',$asm)==0
   or die "candidate compile failed\n";
my$candidates=read_file($manifest);
$candidates eq "safe\n" or die "unexpected candidate manifest:\n$candidates";

system($cc1,'-quiet','-I',$inc,'-X','inlineir',$src,'-o',$forced)==0
   or die "forced compile failed\n";
my$text=read_file($forced);
$text !~ /^\.proc safe\b/m or die "safe function was not optimizer-inlined\n";
for my$name(qw(asm_body asm_named abi_family contracted exported)) {
   $text =~ /^\.proc \Q$name\E\b/m or die "$name identity was not retained\n";
}
$text !~ /^\.proc source_inline\b/m or die "source inline unexpectedly emitted callable body\n";
$text =~ /^abi_family\$x:/m or die "asm ABI-family escape lost abi_family parameter slot\n";
$text =~ /^contracted\$x:/m or die "merged contract lost contracted parameter ABI slot\n";
$text =~ /\.word\s+abi_family\$x\b/m or die "ABI-family assembly reference missing\n";
$text =~ /__contractmeta\$[^\n]*\$contracted\$/m or die "merged contracted function metadata missing\n";

print "Optimizer inline identity tests passed\n";
