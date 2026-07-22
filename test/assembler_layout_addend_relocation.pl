#!/usr/bin/perl

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

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
   $out eq '' or die "$label wrote stdout:\n$out";
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
my $cfg=File::Spec->catfile($repo,'test','generic_6502.cfg');
my $runtime=File::Spec->catfile($repo,'libraries','runtime','libvcsc.l26');
my $src=File::Spec->catfile($tmp,'layout_addend.s');
my $obj=File::Spec->catfile($tmp,'layout_addend.o26');
my $bin=File::Spec->catfile($tmp,'layout_addend.bin');
my $mapfile=File::Spec->catfile($tmp,'layout_addend.map');

# target's packed address is $0197.  Subtracting $0100 yields $0097, which
# deliberately lies inside CODE.pad's packed interval.  The relocation must
# remain attached to CODE.target rather than being remapped by that value.
write_file($src,<<'ASM');
.segment "CODE.pad"
   .res $d8
.segment "CODE.target"
.export main
.export target
.export __sbpmeta$F$main
__sbpmeta$F$main = 0
.proc main
   lda target-$100,y
   rts
   .res $bb
target:
   .byte $42
.endproc
ASM

require_ok('assembly',$as,'-o',$obj,$src);
require_ok('link',$ld,'-T',$cfg,'-Map',$mapfile,'-o',$bin,$obj,$runtime);

my $map=slurp($mapfile);
my $main=map_symbol($map,'main');
my $target=map_symbol($map,'target');
my $image=slurp($bin);
my $rom_start=0x2000;
my $off=$main-$rom_start;
$off >= 0 && $off+4 <= length($image) or die "main lies outside output image\n";
my @got=unpack('C4',substr($image,$off,4));
my $base=($target-0x100)&0xffff;
my @want=(0xB9,$base&0xff,($base>>8)&0xff,0x60);
for my $i (0..$#want) {
   $got[$i] == $want[$i]
      or die sprintf("linked byte %d got %02X expected %02X (target=%04X base=%04X)\n",
                     $i,$got[$i],$want[$i],$target,$base);
}

print "local affine relocations retain their defining layout\n";
