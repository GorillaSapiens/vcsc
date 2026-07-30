#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: importzp modes and external relocation addends preserved
# expectexit: 0


use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub without_cartridge_usage {
   my ($out) = @_;
   $out =~ s/\AMEMORY USAGE\n(?:  [^\n]+\n)+//;
   return $out;
}

sub slurp {
   my ($path)=@_;
   open(my $fh,'<:raw',$path) or die "could not read $path: $!\n";
   local $/; my $d=<$fh>; close($fh);
   return defined($d)?$d:'';
}
sub write_file {
   my ($path,$text)=@_;
   open(my $fh,'>:raw',$path) or die "could not write $path: $!\n";
   print {$fh} $text; close($fh);
}
sub run_capture {
   my (@cmd)=@_;
   my $err=gensym;
   my $pid=open3(my $in,my $out,$err,@cmd);
   close($in);
   local $/;
   my $stdout=<$out> // '';
   my $stderr=<$err> // '';
   waitpid($pid,0);
   return ($? >> 8,$? & 127,$stdout,$stderr);
}
sub require_ok {
   my ($label,@cmd)=@_;
   my ($exit,$sig,$out,$err)=run_capture(@cmd);
   $exit == 0 && !$sig
      or die "$label failed: exit=$exit signal=$sig\n@cmd\nstdout:\n$out\nstderr:\n$err";
   without_cartridge_usage($out) eq '' or die "$label wrote stdout:\n$out";
   $err eq '' or die "$label wrote stderr:\n$err";
}
sub map_symbol {
   my ($map,$name)=@_;
   $map =~ /^\s*\$([0-9A-Fa-f]{4})\s+\Q$name\E\b/m
      or die "map is missing symbol $name\n";
   return hex($1);
}

my $repo=abs_path(shift @ARGV // die "usage: $0 REPO TMP\n");
my $tmp=shift @ARGV // die "usage: $0 REPO TMP\n";
@ARGV and die "usage: $0 REPO TMP\n";
make_path($tmp);
$tmp=abs_path($tmp) // die "could not resolve temp directory\n";

my $as=File::Spec->catfile($repo,'assembler','vcsc-as');
my $ld=File::Spec->catfile($repo,'linker','vcsc-ld');
my $runtime=File::Spec->catfile($repo,'libraries','runtime','libvcsc.l26');
my $cfg=File::Spec->catfile($repo,'test','generic_6502.cfg');
my $def=File::Spec->catfile($tmp,'importzp_def.s26');
my $use=File::Spec->catfile($tmp,'importzp_use.s26');
my $defobj=File::Spec->catfile($tmp,'importzp_def.o26');
my $useobj=File::Spec->catfile($tmp,'importzp_use.o26');
my $bin=File::Spec->catfile($tmp,'importzp.bin');
my $mapfile=File::Spec->catfile($tmp,'importzp.map');

write_file($def,<<'ASM');
.segment "ZEROPAGE"
.zpexport zpbase
zpbase:
   .res 16
.segment "CODE"
.export target
target:
   .byte $ea
ASM

write_file($use,<<'ASM');
.zpimport zpbase
.import target
.segment "CODE"
.export main
.export __sbpmeta$F$main
__sbpmeta$F$main = 0
.proc main
   lda zpbase+2
   lda zpbase+3,x
   ldx zpbase+4,y
   lda (zpbase+6),y
   lda #<{target+8}
   ldx #>{target+8}
   .word target+9
   rts
.endproc
ASM

require_ok('definition assembly',$as,'-o',$defobj,$def);
require_ok('use assembly',$as,'-o',$useobj,$use);
require_ok('link',$ld,'-T',$cfg,'-Map',$mapfile,'-o',$bin,$useobj,$defobj,$runtime);

my $map=slurp($mapfile);
my $main=map_symbol($map,'main');
my $target=map_symbol($map,'target');
my $zp=map_symbol($map,'zpbase');
my $image=slurp($bin);
my $rom_start=0x2000;
my $off=$main-$rom_start;
$off >= 0 && $off+15 <= length($image) or die "main lies outside output image\n";
my @got=unpack('C15',substr($image,$off,15));
my @want=(
   0xA5,($zp+2)&0xff,
   0xB5,($zp+3)&0xff,
   0xB6,($zp+4)&0xff,
   0xB1,($zp+6)&0xff,
   0xA9,($target+8)&0xff,
   0xA2,(($target+8)>>8)&0xff,
   ($target+9)&0xff,(($target+9)>>8)&0xff,
   0x60,
);
for my $i (0..$#want) {
   $got[$i] == $want[$i]
      or die sprintf("linked byte %d got %02X expected %02X\n",$i,$got[$i],$want[$i]);
}

my $bad=File::Spec->catfile($tmp,'importzp_nonaffine.s26');
write_file($bad,<<'ASM');
.zpimport zpbase
.segment "CODE"
.proc bad
   lda zpbase * 2
   rts
.endproc
ASM
my ($bad_exit,$bad_sig,undef,$bad_err)=run_capture($as,'-o',File::Spec->catfile($tmp,'bad.o26'),$bad);
$bad_exit != 0 && !$bad_sig or die "non-affine imported expression unexpectedly assembled\n";
$bad_err =~ /does not support this operator on relocatable expressions/
   or die "non-affine rejection was unclear:\n$bad_err";

print "importzp modes and external relocation addends preserved\n";
