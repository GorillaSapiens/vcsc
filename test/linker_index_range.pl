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

sub write_file { my ($p,$d)=@_; open(my $f,'>:raw',$p) or die "write $p: $!\n"; print {$f} $d; close($f) or die "close $p: $!\n"; }
sub slurp { my ($p)=@_; open(my $f,'<:raw',$p) or die "read $p: $!\n"; local $/; my $d=<$f>; close($f); return defined($d)?$d:''; }
sub run_capture { my (@c)=@_; my $e=gensym; my $pid=open3(my $in,my $out,$e,@c); close($in); local $/; my $o=<$out>//''; my $x=<$e>//''; waitpid($pid,0); return ($?>>8,$?&127,$o,$x); }
sub require_ok { my ($n,@c)=@_; my ($x,$s,$o,$e)=run_capture(@c); $x==0&&!$s or die "$n failed\n@c\n$o$e"; without_cartridge_usage($o) eq '' or die "$n stdout: $o"; $e eq '' or die "$n stderr: $e"; }

my $repo=abs_path(shift @ARGV // die "usage: $0 REPO TMP\n");
my $tmp=shift @ARGV // die "usage: $0 REPO TMP\n"; @ARGV and die "usage: $0 REPO TMP\n";
make_path($tmp); $tmp=abs_path($tmp);
my $as=File::Spec->catfile($repo,'assembler','vcsc-as');
my $ld=File::Spec->catfile($repo,'linker','vcsc-ld');
my $src=File::Spec->catfile($tmp,'range.s26');
my $obj=File::Spec->catfile($tmp,'range.o26');
my $cfg=File::Spec->catfile($tmp,'range.cfg');
my $map=File::Spec->catfile($tmp,'range.map');
my $bin=File::Spec->catfile($tmp,'range.bin');

write_file($src, <<'ASM');
.segment "PREFIX"
.res 240
.segment "TABLE"
.indexrange 8, 15
.export timing_table
timing_table:
.res 300
.segment "CODE"
.export __reset, __nmi, __irqbrk
__reset:
__nmi:
__irqbrk:
 rts
ASM
write_file($cfg, <<'CFG');
MEMORY {
 ZEROPAGE: start=$0000,size=$0100,type=rw;
 CPUSTACK: start=$0100,size=$0100,type=rw;
 RAM: start=$0200,size=$1E00,type=rw;
 ROM: start=$2000,size=$E000,type=ro;
}
SEGMENTS {
 ZEROPAGE: load=ROM,run=ZEROPAGE,type=zp;
 CODE: load=ROM,type=ro;
 PREFIX: load=ROM,type=ro;
 TABLE: load=ROM,type=ro;
 DATA: load=ROM,run=RAM,type=data;
 BSS: load=RAM,type=bss;
}
CFG
require_ok('assemble indexed range',$as,'-o',$obj,$src);
require_ok('link indexed range',$ld,'-T',$cfg,'-Map',$map,'-o',$bin,$obj);
my $m=slurp($map);
$m =~ /TABLE\s+load=\$20F8\s+size=\$012C\s+page=crossing/
  or die "partial indexed range did not select the earliest legal base\n$m";
$m =~ /TABLE\s+base=\$20F8\s+offset=\$0008\s+max=\$0F\s+effective=\$2100-\$210F\s+page=same/
  or die "indexed-range map diagnostic missing or wrong\n$m";

my $bad=File::Spec->catfile($tmp,'bad.s26');
write_file($bad, <<'ASM');
.segment "TABLE"
.indexrange 290, 15
.res 300
ASM
my ($exit,$sig,undef,$err)=run_capture($as,'-o',File::Spec->catfile($tmp,'bad.o26'),$bad);
$exit!=0&&!$sig or die "out-of-layout indexed range unexpectedly assembled\n";
$err =~ /indexed range for segment 'TABLE' is outside its \$012C-byte layout/
  or die "indexed-range diagnostic was unclear:\n$err";

print "linker enforces explicit indexed-access page windows\n";
