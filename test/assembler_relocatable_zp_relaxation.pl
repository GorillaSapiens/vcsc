#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: relocatable ROM operands do not relax to zero page
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub without_cartridge_usage {
   my($out)=@_;
   $out =~ s/\AMEMORY USAGE\n(?:  [^\n]+\n)+//;
   return $out;
}
sub slurp {
   my($path)=@_;
   open(my $fh,'<:raw',$path) or die "read $path: $!\n";
   local $/; my $data=<$fh>; close($fh);
   return defined($data) ? $data : '';
}
sub write_file {
   my($path,$text)=@_;
   open(my $fh,'>:raw',$path) or die "write $path: $!\n";
   print {$fh} $text or die "write $path: $!\n";
   close($fh) or die "close $path: $!\n";
}
sub run_capture {
   my(@cmd)=@_;
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
   my($label,@cmd)=@_;
   my($rc,$sig,$out,$err)=run_capture(@cmd);
   $rc==0 && !$sig or die "$label failed rc=$rc sig=$sig\n@cmd\nstdout:\n$out\nstderr:\n$err";
   without_cartridge_usage($out) eq '' or die "$label wrote stdout:\n$out";
   $err eq '' or die "$label wrote stderr:\n$err";
}
sub map_symbol {
   my($map,$name)=@_;
   $map =~ /^\s*\$([0-9A-Fa-f]{4})\s+\Q$name\E\b/m
      or die "map is missing $name\n";
   return hex($1);
}

my $repo=abs_path(shift @ARGV // die "usage: $0 REPO TMP\n");
my $tmp=shift @ARGV // die "usage: $0 REPO TMP\n";
@ARGV and die "usage: $0 REPO TMP\n";
make_path($tmp);
$tmp=abs_path($tmp) // die "resolve temp directory\n";

my $as=File::Spec->catfile($repo,'assembler','vcsc-as');
my $ld=File::Spec->catfile($repo,'linker','vcsc-ld');
my $cfg=File::Spec->catfile($repo,'libraries','vcs','vcs_4k.cfg');
my $runtime=File::Spec->catfile($repo,'libraries','runtime','libvcsc.l26');
my $src=File::Spec->catfile($tmp,'relax.s26');
my $obj=File::Spec->catfile($tmp,'relax.o26');
my $bin=File::Spec->catfile($tmp,'relax.bin');
my $mapfile=File::Spec->catfile($tmp,'relax.map');

write_file($src,<<'ASM');
ABS_BYTE = $44
.segmentaddrsize "BSS", zp
.segmentaddrsize "BSS.__vcsc_object$widebyte", absolute

.segment "ZEROPAGE"
.export zpbyte
zpbyte:
   .res 2

.segment "BSS.__vcsc_object$fastbyte"
.export fastbyte
fastbyte:
   .res 1

.segment "BSS.__vcsc_object$widebyte"
.export widebyte
widebyte:
   .res 1

.segment "CODE.main"
.export main
.export __sbpmeta$F$main
__sbpmeta$F$main = 0
.proc main
   lda glyph,x
   lda glyph+1
   lda zpbyte,x
   lda fastbyte,x
   lda widebyte,x
   lda ABS_BYTE,x
   rts
.endproc

.segment "RODATA.glyph"
.export glyph
glyph:
   .byte $11,$22,$33,$44
ASM

require_ok('assembly',$as,'-o',$obj,$src);
require_ok('link',$ld,'-T',$cfg,'-Map',$mapfile,'-o',$bin,$obj,$runtime);

my $map=slurp($mapfile);
my $main=map_symbol($map,'main');
my $glyph=map_symbol($map,'glyph');
my $zp=map_symbol($map,'zpbyte');
my $fast=map_symbol($map,'fastbyte');
my $wide=map_symbol($map,'widebyte');
my $image=slurp($bin);
my $off=$main-0xF000;
$off>=0 && $off+16<=length($image) or die "main lies outside image\n";
my @got=unpack('C16',substr($image,$off,16));
my @want=(
   0xBD,$glyph&0xff,($glyph>>8)&0xff,
   0xAD,($glyph+1)&0xff,(($glyph+1)>>8)&0xff,
   0xB5,$zp&0xff,
   0xB5,$fast&0xff,
   0xBD,$wide&0xff,($wide>>8)&0xff,
   0xB5,0x44,
   0x60,
);
for my $i (0..$#want) {
   $got[$i]==$want[$i]
      or die sprintf("byte %d got %02X expected %02X (glyph=%04X zp=%04X fast=%04X wide=%04X)\n",
                     $i,$got[$i],$want[$i],$glyph,$zp,$fast,$wide);
}

print "relocatable ROM operands do not relax to zero page\n";
