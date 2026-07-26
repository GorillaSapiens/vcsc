#!/usr/bin/perl

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub without_cartridge_usage {
   my ($out) = @_;
   $out =~ s/\ACARTRIDGE ROM USAGE\n(?:  [^\n]+\n)+RAM USAGE\n(?:  [^\n]+\n)+//;
   return $out;
}

sub write_file {
   my ($path,$text)=@_;
   open(my $fh,'>:raw',$path) or die "could not write $path: $!\n";
   print {$fh} $text; close($fh);
}
sub slurp {
   my ($path)=@_;
   open(my $fh,'<:raw',$path) or die "could not read $path: $!\n";
   local $/; my $d=<$fh>; close($fh); return defined($d)?$d:'';
}
sub run_capture {
   my (@cmd)=@_;
   my $err=gensym;
   my $pid=open3(my $in,my $out,$err,@cmd);
   close($in); local $/;
   my $stdout=<$out> // ''; my $stderr=<$err> // '';
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

my $repo=abs_path(shift @ARGV // die "usage: $0 REPO TMP\n");
my $tmp=shift @ARGV // die "usage: $0 REPO TMP\n";
@ARGV and die "usage: $0 REPO TMP\n";
make_path($tmp); $tmp=abs_path($tmp) // die "could not resolve temp dir\n";
my $as=File::Spec->catfile($repo,'assembler','vcsc-as');
my $ld=File::Spec->catfile($repo,'linker','vcsc-ld');
my $runtime=File::Spec->catfile($repo,'libraries','runtime','libvcsc.l26');

my $cfg=File::Spec->catfile($tmp,'aligned.cfg');
write_file($cfg,<<'CFG');
MEMORY {
   ZEROPAGE: start=$0000, size=$0100, type=rw;
   CPUSTACK: start=$0100, size=$0100, type=rw;
   RAM:      start=$0200, size=$1E00, type=rw;
   ROM:      start=$2000, size=$E000, type=ro;
}
SEGMENTS {
   ZEROPAGE:   load=ROM, run=ZEROPAGE, type=zp;
   CODE:       load=ROM, type=ro;
   KERNEL_CODE:load=ROM, type=ro, align=$0100;
   RODATA:     load=ROM, type=ro;
   BSS:        load=RAM, type=bss;
   DATA:       load=ROM, run=RAM, type=data;
}
CFG

my $src=File::Spec->catfile($tmp,'aligned.s26');
write_file($src,<<'ASM');
.segment "KERNEL_CODE"
.export main
.export __sbpmeta$F$main
__sbpmeta$F$main = 0
.proc main
   rts
.endproc
ASM
my $obj=File::Spec->catfile($tmp,'aligned.o26');
require_ok('aligned assembly',$as,'-o',$obj,$src);
my $mapfile=File::Spec->catfile($tmp,'aligned.map');
my $bin=File::Spec->catfile($tmp,'aligned.bin');
require_ok('aligned link',$ld,'-T',$cfg,'-Map',$mapfile,'-o',$bin,$obj,$runtime);
my $map=slurp($mapfile);
$map =~ /^\s*\$([0-9A-Fa-f]{4})\s+main\b/m or die "aligned map lacks main\n";
my $main=hex($1);
($main & 0xff) == 0 or die sprintf("main was placed at %04X, not a page boundary\n",$main);
$map =~ /^\s*KERNEL_CODE\s+load=\$[0-9A-Fa-f]{4}\s+size=\$0001\b/m
   or die "aligned map lacks one-byte KERNEL_CODE layout\n";

my $badcfg=File::Spec->catfile($tmp,'bad_align.cfg');
my $badtext=slurp($cfg); $badtext =~ s/align=\$0100/align=3/;
write_file($badcfg,$badtext);
my ($bad_exit,$bad_sig,undef,$bad_err)=run_capture(
   $ld,'-T',$badcfg,'-o',File::Spec->catfile($tmp,'bad.bin'),$obj,$runtime);
$bad_exit != 0 && !$bad_sig or die "non-power-of-two segment alignment unexpectedly linked\n";
$bad_err =~ /bad segment alignment '3'/
   or die "bad alignment rejection was unclear:\n$bad_err";

my $mis_src=File::Spec->catfile($tmp,'misaligned.s26');
write_file($mis_src,<<'ASM');
.segment "CODE"
.byte $ea
.segment "KERNEL_CODE"
.export main
.export __sbpmeta$F$main
__sbpmeta$F$main = 0
.proc main
   rts
.endproc
ASM
my $mis_obj=File::Spec->catfile($tmp,'misaligned.o26');
require_ok('misaligned assembly',$as,'-o',$mis_obj,$mis_src);
my $mis_map=File::Spec->catfile($tmp,'misaligned.map');
require_ok('independent aligned layout link',$ld,'-T',$cfg,'-Map',$mis_map,
   '-o',File::Spec->catfile($tmp,'misaligned.bin'),$mis_obj,$runtime);
my $mis_text=slurp($mis_map);
$mis_text =~ /^\s*\$([0-9A-Fa-f]{4})\s+main\b/m
   or die "independent aligned map lacks main\n";
(hex($1) & 0xff) == 0
   or die sprintf("independent KERNEL_CODE layout was placed at %04X\n",hex($1));

print "linker segment alignment enforced\n";
