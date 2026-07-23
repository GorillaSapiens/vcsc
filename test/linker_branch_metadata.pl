#!/usr/bin/perl
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
sub require_ok { my ($n,@c)=@_; my ($x,$s,$o,$e)=run_capture(@c); $x==0&&!$s or die "$n failed\n@c\n$o$e"; $o eq '' or die "$n stdout: $o"; $e eq '' or die "$n stderr: $e"; }

my $repo=abs_path(shift @ARGV // die "usage: $0 REPO TMP\n");
my $tmp=shift @ARGV // die "usage: $0 REPO TMP\n"; @ARGV and die "usage: $0 REPO TMP\n";
make_path($tmp); $tmp=abs_path($tmp);
my $as=File::Spec->catfile($repo,'assembler','vcsc-as');
my $ld=File::Spec->catfile($repo,'linker','vcsc-ld');
my $src=File::Spec->catfile($tmp,'branches.s26');
my $obj=File::Spec->catfile($tmp,'branches.o26');
my $cfg=File::Spec->catfile($tmp,'branches.cfg');
my $bin=File::Spec->catfile($tmp,'branches.bin');
my $map=File::Spec->catfile($tmp,'branches.map');

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
  bne @cross_target
  .res 3
@cross_target:
  .res 6
  bne @same_target
  .res 2
@same_target:
  rts
  .res 240
ASM

write_file($cfg, <<'CFG');
MEMORY {
 ZEROPAGE: start=$0000,size=$0100,type=rw;
 CPUSTACK: start=$0100,size=$0100,type=rw;
 RAM: start=$0200,size=$1E00,type=rw;
 ROM: start=$20F8,size=$DF08,type=ro;
}
SEGMENTS {
 ZEROPAGE: load=ROM,run=ZEROPAGE,type=zp;
 CODE: load=ROM,type=ro;
 DATA: load=ROM,run=RAM,type=data;
 BSS: load=RAM,type=bss;
}
CFG

require_ok('assemble',$as,'-o',$obj,$src);
require_ok('link',$ld,'-T',$cfg,'-Map',$map,'-o',$bin,$obj);
my $m=slurp($map);
$m =~ /\Q$obj\E\n\s+\$20FE -> \$2103 BNE opcode=\$D0 taken-page=same\n\s+\$2109 -> \$210D BNE opcode=\$D0 taken-page=same/s
  or die "map did not preserve local branch metadata or branch-aware placement\n$m";

# Task 20l searches one bounded low-byte cycle. Moving this 261-byte unit by
# one byte eliminates the only taken page crossing; farther equivalent phases
# would grow the image unnecessarily.
$m =~ /CODE\s+load=\$20F9\s+size=\$0105\s+page=crossing/
  or die "branch-aware placement did not choose the smallest zero-crossing move\n$m";
my $bytes=slurp($bin);
length($bytes)>0x12 or die "linked image was unexpectedly short\n";
ord(substr($bytes,5,1))==0xD0 && ord(substr($bytes,6,1))==0x03
  or die "first branch bytes changed\n";
ord(substr($bytes,16,1))==0xD0 && ord(substr($bytes,17,1))==0x02
  or die "same-page branch bytes changed\n";

print "linker uses local branch metadata for bounded page-aware code placement\n";
