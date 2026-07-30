#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub write_file { my ($p,$d)=@_; open(my $f,'>:raw',$p) or die "write $p: $!\n"; print {$f} $d; close($f) or die "close $p: $!\n"; }
sub slurp { my ($p)=@_; open(my $f,'<:raw',$p) or die "read $p: $!\n"; local $/; my $d=<$f>; close($f); return defined($d)?$d:''; }
sub run_capture { my (@c)=@_; my $e=gensym; my $pid=open3(my $in,my $out,$e,@c); close($in); local $/; my $o=<$out>//''; my $x=<$e>//''; waitpid($pid,0); return ($?>>8,$?&127,$o,$x); }
sub require_ok { my ($n,@c)=@_; my ($x,$s,$o,$e)=run_capture(@c); $x==0&&!$s or die "$n failed\n@c\n$o$e"; $e eq '' or die "$n stderr: $e"; }
sub require_missing { my ($p)=@_; !-e $p or die "unexpected file $p\n"; }
sub require_exists { my ($p)=@_; -f $p && -s $p or die "missing/empty file $p\n"; }

my $repo=abs_path(shift @ARGV // die "usage: $0 REPO TMP\n");
my $tmp=shift @ARGV // die "usage: $0 REPO TMP\n"; @ARGV and die "usage: $0 REPO TMP\n";
make_path($tmp); $tmp=abs_path($tmp);
my $as=File::Spec->catfile($repo,'assembler','vcsc-as');
my $ld=File::Spec->catfile($repo,'linker','vcsc-ld');
my $driver=File::Spec->catfile($repo,'driver','vcsc');
my $src=File::Spec->catfile($tmp,'sidecars.s26');
my $obj=File::Spec->catfile($tmp,'sidecars.o26');
my $linkcfg=File::Spec->catfile($tmp,'layout.cfg');

write_file($src, <<'ASM');
.segment "CODE"
.export __reset, __nmi, __irqbrk, main
__reset:
main:
  lda #$42
  sta state
  rts
__nmi:
  rti
__irqbrk:
  rti
.segment "RODATA"
.export table
table:
  .byte $11, $22, $33
.segment "ZEROPAGE"
.export state
state:
  .res 1
ASM

write_file($linkcfg, <<'CFG');
MEMORY {
 RAM: start=$0080,size=$0080,type=rw;
 ROM: start=$F000,size=$0FFA,type=ro;
 VECTORS: start=$FFFA,size=$0006,type=ro;
}
SEGMENTS {
 ZEROPAGE: load=RAM,type=zp;
 DATA: load=ROM,run=RAM,type=data;
 BSS: load=RAM,type=bss;
 CODE: load=ROM,type=ro;
 RODATA: load=ROM,type=ro;
 VECTORS: load=VECTORS,type=ro;
}
CFG

require_ok('assemble',$as,'-o',$obj,$src);

my $bin=File::Spec->catfile($tmp,'game.bin');
require_ok('default sidecars',$ld,'-T',$linkcfg,'-o',$bin,$obj);
for my $ext (qw(map sym lst cfg)) { require_exists(File::Spec->catfile($tmp,"game.$ext")); }

my $sym=slurp(File::Spec->catfile($tmp,'game.sym'));
$sym =~ /^main\s+f[0-9a-f]{3}$/mi or die "symbol file lacks main ROM label\n$sym";
$sym =~ /^state\s+0080$/mi or die "symbol file lacks RAM label\n$sym";
my $lst=slurp(File::Spec->catfile($tmp,'game.lst'));
$lst =~ /VCSC linked image listing/ or die "list header missing\n";
$lst =~ /^\s*\d+\s+0080\s+\s*00\s+80\s+state\s+=/mi or die "DASM RAM constant row missing\n$lst";
$lst =~ /^\s*\d+\s+f000\s+[0-9a-f]{2}/mi or die "linked ROM bytes missing\n$lst";
my $dcfg=slurp(File::Spec->catfile($tmp,'game.cfg'));
$dcfg =~ /^CODE\s+f000\s+f006$/mi or die "CODE range missing/wrong\n$dcfg";
$dcfg =~ /^DATA\s+f007\s+f0[0-9a-f]{2}$/mi or die "RODATA/generated-data range missing/wrong\n$dcfg";
$dcfg =~ /^DATA\s+fffa\s+ffff$/mi or die "vector range missing\n$dcfg";
slurp(File::Spec->catfile($tmp,'game.map')) =~ /\nSYMBOLS\n/ or die "map symbols missing\n";

my %named=(
 map=>File::Spec->catfile($tmp,'renamed.debug-map'),
 sym=>File::Spec->catfile($tmp,'renamed.symbols'),
 lst=>File::Spec->catfile($tmp,'renamed.listing'),
 cfg=>File::Spec->catfile($tmp,'renamed.distella'),
);
my $namedbin=File::Spec->catfile($tmp,'renamed.bin');
require_ok('renamed sidecars',$ld,'-T',$linkcfg,'-o',$namedbin,
           '--map='.$named{map},'-Sym',$named{sym},'--list='.$named{lst},'-Cfg='.$named{cfg},$obj);
require_exists($_) for values %named;
for my $ext (qw(map sym lst cfg)) { require_missing(File::Spec->catfile($tmp,"renamed.$ext")); }

my $quietbin=File::Spec->catfile($tmp,'quiet.bin');
require_ok('disabled sidecars',$ld,'-T',$linkcfg,'-o',$quietbin,
           '--no-map','--no-sym','--no-list','--no-cfg',$obj);
for my $ext (qw(map sym lst cfg)) { require_missing(File::Spec->catfile($tmp,"quiet.$ext")); }

my $collision_cfg=File::Spec->catfile($tmp,'collision.cfg');
write_file($collision_cfg,slurp($linkcfg));
my $collision_before=slurp($collision_cfg);
my $collision_bin=File::Spec->catfile($tmp,'collision.bin');
require_ok('same-stem linker config collision',$ld,'-T',$collision_cfg,'-o',$collision_bin,$obj);
slurp($collision_cfg) eq $collision_before or die "default Stella cfg overwrote linker config\n";
require_exists(File::Spec->catfile($tmp,"collision.$_")) for qw(map sym lst);
my ($rc,$sig,$out,$err)=run_capture($ld,'-T',$collision_cfg,'-o',File::Spec->catfile($tmp,'explicit.bin'),
                                    '-Cfg',$collision_cfg,$obj);
$rc != 0 && !$sig or die "explicit cfg collision unexpectedly succeeded\n";
$err =~ /would overwrite linker script\/config/ or die "wrong explicit collision diagnostic: $err";

my $driver_bin=File::Spec->catfile($tmp,'driver.bin');
my $driver_sym=File::Spec->catfile($tmp,'driver.named.sym');
require_ok('driver sidecar options',$driver,'-nostdlib','-T',$linkcfg,'-o',$driver_bin,
           '--no-map','-Sym',$driver_sym,'--no-list','--no-cfg',$obj);
require_exists($driver_sym);
require_missing(File::Spec->catfile($tmp,'driver.map'));
require_missing(File::Spec->catfile($tmp,'driver.lst'));
require_missing(File::Spec->catfile($tmp,'driver.cfg'));

print "linker Stella sidecars ok\n";
