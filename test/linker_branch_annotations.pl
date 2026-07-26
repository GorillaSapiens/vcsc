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
sub require_fail { my ($n,$want,@c)=@_; my ($x,$s,$o,$e)=run_capture(@c); $x!=0&&!$s or die "$n unexpectedly succeeded\n@c\n$o$e"; $e =~ $want or die "$n diagnostic mismatch\n@c\n$o$e"; }

my $repo=abs_path(shift @ARGV // die "usage: $0 REPO TMP\n");
my $tmp=shift @ARGV // die "usage: $0 REPO TMP\n"; @ARGV and die "usage: $0 REPO TMP\n";
make_path($tmp); $tmp=abs_path($tmp);
my $as=File::Spec->catfile($repo,'assembler','vcsc-as');
my $ld=File::Spec->catfile($repo,'linker','vcsc-ld');
my $cfg=File::Spec->catfile($tmp,'branches.cfg');
write_file($cfg, <<'CFG');
MEMORY {
 ZEROPAGE: start=$0000,size=$0100,type=rw;
 CPUSTACK: start=$0100,size=$0100,type=rw;
 RAM: start=$0200,size=$1E00,type=rw;
 ROM: start=$20F8,size=$DF02,type=ro;
}
SEGMENTS {
 ZEROPAGE: load=ROM,run=ZEROPAGE,type=zp;
 CODE: load=ROM,type=ro;
 DATA: load=ROM,run=RAM,type=data;
 BSS: load=RAM,type=bss;
}
CFG

my $src=File::Spec->catfile($tmp,'ok.s26');
my $obj=File::Spec->catfile($tmp,'ok.o26');
my $bin=File::Spec->catfile($tmp,'ok.bin');
my $map=File::Spec->catfile($tmp,'ok.map');
write_file($src, <<'ASM');
.segment "CODE"
.export main, __reset, __nmi, __irqbrk
.export __sbpmeta$F$main
__sbpmeta$F$main = 0
main:
__reset:
__nmi:
__irqbrk:
  .res 5
  bne.cross @cross_target
  .res 3
@cross_target:
  bne.same @same_target
  .res 2
@same_target:
  bne.flex @flex_target
  .res 2
@flex_target:
  bne @bare_target
  .res 2
@bare_target:
  opD0.flex @raw_target
  .res 2
@raw_target:
  rts
ASM
require_ok('assemble annotations',$as,'-o',$obj,$src);
require_ok('link annotations',$ld,'-T',$cfg,'-Map',$map,'-o',$bin,$obj);
my $m=slurp($map);
$m =~ /\Q$obj\E\n\s+\$20FD -> \$2102 BNE opcode=\$D0 taken-page=crossing policy=cross\n\s+\$2102 -> \$2106 BNE opcode=\$D0 taken-page=same policy=same\n\s+\$2106 -> \$210A BNE opcode=\$D0 taken-page=same policy=flex\n\s+\$210A -> \$210E BNE opcode=\$D0 taken-page=same policy=flex/s
  or die "map did not preserve or enforce branch annotations\n$m";
$m =~ /^\s+\$210E -> \$2112 BNE opcode=\$D0 taken-page=same policy=flex$/m
  or die "raw relative opcode lost its explicit .flex annotation\n$m";

my $badop=File::Spec->catfile($tmp,'badop.s26');
write_file($badop, ".segment \"CODE\"\nlda.same #0\n");
require_fail('nonbranch annotation',qr/\.same is valid only on a relative conditional branch/,
             $as,'-o',File::Spec->catfile($tmp,'badop.o26'),$badop);

my $long=File::Spec->catfile($tmp,'long.s26');
write_file($long, ".segment \"CODE\"\nbne.cross far\n.res 200\nfar:\nrts\n");
require_fail('long annotated branch',qr/\.cross requires a short relative branch/,
             $as,'-o',File::Spec->catfile($tmp,'long.o26'),$long);

my $impossible=File::Spec->catfile($tmp,'impossible.s26');
my $impossible_obj=File::Spec->catfile($tmp,'impossible.o26');
write_file($impossible, <<'ASM');
.segment "CODE"
.export main, __reset, __nmi, __irqbrk
.export __sbpmeta$F$main
__sbpmeta$F$main = 0
main:
__reset:
__nmi:
__irqbrk:
  bne.cross @next
@next:
  rts
ASM
require_ok('assemble impossible',$as,'-o',$impossible_obj,$impossible);
require_fail('unsatisfiable cross',qr/\.same\/\.cross branch-page requirements are mutually unsatisfiable/,
             $ld,'-T',$cfg,'-o',File::Spec->catfile($tmp,'impossible.bin'),$impossible_obj);

my $split=File::Spec->catfile($tmp,'split.s26');
my $split_obj=File::Spec->catfile($tmp,'split.o26');
write_file($split, <<'ASM');
.segment "CODE"
.export main, __reset, __nmi, __irqbrk
.export __sbpmeta$F$main
__sbpmeta$F$main = 0
.proc main
__reset:
__nmi:
__irqbrk:
  bne.same other
  rts
.endproc
.proc other
  rts
.endproc
ASM
require_ok('assemble split layout',$as,'-o',$split_obj,$split);
require_fail('split layout contract',qr/hard branch-page annotation .* targets outside movable layout/,
             $ld,'-T',$cfg,'-o',File::Spec->catfile($tmp,'split.bin'),$split_obj);

print "assembler and linker enforce .cross, .same, and .flex branch annotations\n";
