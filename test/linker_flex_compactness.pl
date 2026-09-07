#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# expectexit: 0
# expectstdout: linker keeps .flex placement compact before optimizing page crossings

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
sub write_file { my ($p,$d)=@_; open(my $f,'>:raw',$p) or die "write $p: $!\n"; print {$f} $d; close($f) or die "close $p: $!\n"; }
sub slurp { my ($p)=@_; open(my $f,'<:raw',$p) or die "read $p: $!\n"; local $/; my $d=<$f>; close($f); return defined($d)?$d:''; }
sub run_capture { my (@c)=@_; my $e=gensym; my $pid=open3(my $in,my $out,$e,@c); close($in); local $/; my $o=<$out>//''; my $x=<$e>//''; waitpid($pid,0); return ($?>>8,$?&127,$o,$x); }
sub require_ok { my ($n,@c)=@_; my ($x,$s,$o,$e)=run_capture(@c); $x==0&&!$s or die "$n failed\n@c\n$o$e"; without_cartridge_usage($o) eq '' or die "$n stdout: $o"; $e eq '' or die "$n stderr: $e"; }

my $repo=abs_path(shift @ARGV // die "usage: $0 REPO TMP\n");
my $tmp=shift @ARGV // die "usage: $0 REPO TMP\n"; @ARGV and die "usage: $0 REPO TMP\n";
make_path($tmp); $tmp=abs_path($tmp);
my $as=File::Spec->catfile($repo,'assembler','vcsc-as');
my $ld=File::Spec->catfile($repo,'linker','vcsc-ld');
my $cfg=File::Spec->catfile($tmp,'compact.cfg');
my $head_src=File::Spec->catfile($tmp,'head.s26');
my $tail_src=File::Spec->catfile($tmp,'tail.s26');
my $head_obj=File::Spec->catfile($tmp,'head.o26');
my $tail_obj=File::Spec->catfile($tmp,'tail.o26');
my $map=File::Spec->catfile($tmp,'compact.map');
my $bin=File::Spec->catfile($tmp,'compact.bin');

# The startup tables consume 12 bytes.  At the compact $2094 start, this
# 128-byte function has one flexible taken-page crossing.  Moving it to $20FE
# removes the crossing but burns 106 bytes before the function.  A later
# 101-byte layout then leaves the final two-byte startup table unplaceable,
# despite the image requiring exactly 241 bytes in a 241-byte ROM.
write_file($cfg, <<'CFG');
MEMORY {
 ZEROPAGE: start=$0000,size=$0100,type=rw;
 CPUSTACK: start=$0100,size=$0100,type=rw;
 RAM: start=$0200,size=$1E00,type=rw;
 ROM: start=$2094,size=$00F1,type=ro;
}
SEGMENTS {
 ZEROPAGE: load=ROM,run=ZEROPAGE,type=zp;
 CODE: load=ROM,type=ro;
 DATA: load=ROM,run=RAM,type=data;
 BSS: load=RAM,type=bss;
}
CFG

write_file($head_src, <<'ASM');
.segment "CODE"
.export main, __reset, __nmi, __irqbrk
.export __sbpmeta$F$main
__sbpmeta$F$main = 0
.import tail
main:
__reset:
__nmi:
__irqbrk:
  bne.flex @target
  .res 110
@target:
  rts
  .word tail
  .res 13
ASM

write_file($tail_src, <<'ASM');
.segment "CODE"
.export tail
tail:
  .res 101
ASM

require_ok('assemble head',$as,'-o',$head_obj,$head_src);
require_ok('assemble tail',$as,'-o',$tail_obj,$tail_src);
require_ok('link exact-fit compact image',$ld,'-T',$cfg,'-Map',$map,'-o',$bin,$head_obj,$tail_obj);

my $m=slurp($map);
$m =~ /ROM\s+used=241 bytes \(100\.00%\) free=0 bytes/
  or die "exact-fit ROM accounting changed\n$m";
$m =~ /head\.o26\n\s+CODE\s+load=\$2094\s+size=\$0080\s+page=crossing/s
  or die "flex-bearing layout was not kept at compact high-water placement\n$m";
$m =~ /^\s+\$2094 -> \$2104 BNE opcode=\$D0 taken-page=crossing policy=flex$/m
  or die "compact placement did not retain the permitted flexible crossing\n$m";
$m =~ /tail\.o26\n\s+CODE\s+load=\$2114\s+size=\$0065/s
  or die "later layout was not packed directly after the flex-bearing layout\n$m";
print "linker keeps .flex placement compact before optimizing page crossings\n";
