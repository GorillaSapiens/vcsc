#!/usr/bin/env perl
# runner: perl @FILE@ @REPO@ @TMP@

use strict;
use warnings;
use File::Spec;
use File::Path qw(make_path);
use IPC::Open3;
use Symbol qw(gensym);

my ($repo,$tmp)=@ARGV;
die "usage: $0 REPO TMP\n" unless defined $tmp;
make_path($tmp);
my $as=File::Spec->catfile($repo,'assembler','vcsc-as');
my $ld=File::Spec->catfile($repo,'linker','vcsc-ld');
my $rt=File::Spec->catfile($repo,'libraries','runtime','libvcsc.l26');
sub wr { my($p,$s)=@_; open my $f,'>',$p or die $!; print $f $s; close $f; }
sub run { my(@c)=@_; my $e=gensym; my $p=open3(undef,my $o,$e,@c); local $/; my $x=(<$o>//'').(<$e>//''); waitpid($p,0); return ($?>>8,$x); }
my $src=File::Spec->catfile($tmp,'f.s26'); my $obj=File::Spec->catfile($tmp,'f.o26');
my $cfg=File::Spec->catfile($tmp,'f.cfg'); my $bin=File::Spec->catfile($tmp,'f.bin'); my $map="$bin.map";
wr($src, <<'ASM');
.segment "CODE"
.export main, soft_fn, hard_fn
.export __sbpmeta$F$main
__sbpmeta$F$main = 0
.proc main
  jsr soft_fn
  jsr hard_fn
  rts
.endproc
.proc soft_fn
  .res 240
  rts
.endproc
.proc hard_fn
  .pagecontain
  .res 32
  rts
.endproc
ASM
wr($cfg, <<'CFG');
MEMORY {
 ZEROPAGE: start=$0000,size=$0100,type=rw;
 CPUSTACK: start=$0100,size=$0100,type=rw;
 RAM: start=$0200,size=$1E00,type=rw;
 ROM: start=$2000,size=$E000,type=ro;
}
SEGMENTS {
 ZEROPAGE: load=ROM,run=ZEROPAGE,type=zp;
 CODE: load=ROM,type=ro;
 DATA: load=ROM,run=RAM,type=data;
 BSS: load=RAM,type=bss;
}
CFG
my($r,$x)=run($as,'-o',$obj,$src); die "assemble failed: $x" if $r;
($r,$x)=run($ld,'-T',$cfg,'-Map',$map,'-o',$bin,$obj,$rt); die "link failed: $x" if $r;
open my $m,'<',$map or die $!; local $/; my $t=<$m>; close $m;
$t =~ /CODE\.__vcsc_function\$main.*page=preferred/s or die "missing main function layout\n";
$t =~ /CODE\.__vcsc_function\$soft_fn.*size=\$00F1.*page=(?:preferred|crossing)/s or die "missing soft function layout\n";
$t =~ /CODE\.__vcsc_function\$hard_fn.*size=\$0021.*page=hard/s or die "missing hard function layout\n";

my $badsrc=File::Spec->catfile($tmp,'bad.s26');
my $badobj=File::Spec->catfile($tmp,'bad.o26');
my $badbin=File::Spec->catfile($tmp,'bad.bin');
wr($badsrc, <<'ASM');
.segment "CODE"
.export main
.export __sbpmeta$F$main
__sbpmeta$F$main = 0
.proc main
  .pagecontain
  .res 257
  rts
.endproc
ASM
($r,$x)=run($as,'-o',$badobj,$badsrc); die "assemble oversized failed: $x" if $r;
($r,$x)=run($ld,'-T',$cfg,'-o',$badbin,$badobj,$rt);
$r != 0 or die "oversized hard function unexpectedly linked\n";
$x =~ /hard page containment impossible for CODE\.__vcsc_function\$main .* size \$0102 exceeds 256 bytes/
  or die "oversized function diagnostic was unclear: $x";
print "ok linker function page placement\n";
