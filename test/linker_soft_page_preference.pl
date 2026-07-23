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
   $out =~ s/\ACARTRIDGE ROM USAGE\n(?:  [^\n]+\n)+//;
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
my $rt=File::Spec->catfile($repo,'libraries','runtime','libvcsc.l26');
my $cfg=File::Spec->catfile($tmp,'layout.cfg');
write_file($cfg,<<'CFG');
MEMORY {
 ZEROPAGE: start=$0000,size=$0100,type=rw;
 CPUSTACK: start=$0100,size=$0100,type=rw;
 RAM: start=$0200,size=$1E00,type=rw;
 ROM: start=$200E,size=$DFF2,type=ro;
}
SEGMENTS {
 ZEROPAGE: load=ROM,run=ZEROPAGE,type=zp;
 CODE: load=ROM,type=ro;
 HOT: load=ROM,type=ro,align=$0100;
 DATA: load=ROM,run=RAM,type=data;
 BSS: load=RAM,type=bss;
}
CFG
my @sources=(
 ['hard.s26', <<'ASM'],
.segment "HOT"
.pagecontain
.export main
.export __sbpmeta$F$main
__sbpmeta$F$main = 0
.import soft_hole
.import soft_cross
.proc main
 rts
.endproc
.word soft_hole
.word soft_cross
.res 9
ASM
 ['hole.s26', <<'ASM'],
.segment "CODE"
.export soft_hole
soft_hole:
.res 247
ASM
 ['cross.s26', <<'ASM'],
.segment "CODE"
.export soft_cross
soft_cross:
.res 247
ASM
);
my @objs;
for my $item (@sources) {
   my ($name,$body)=@$item;
   my $src=File::Spec->catfile($tmp,$name);
   my $obj=File::Spec->catfile($tmp,$name.'.o26');
   write_file($src,$body);
   require_ok("assemble $name",$as,'-o',$obj,$src);
   push @objs,$obj;
}
my $map=File::Spec->catfile($tmp,'soft.map');
require_ok('link',$ld,'-T',$cfg,'-Map',$map,'-o',File::Spec->catfile($tmp,'soft.bin'),@objs,$rt);
my $m=slurp($map);
$m =~ /^\s*\$([0-9A-Fa-f]{4})\s+soft_hole\b/m or die "map lacks soft_hole\n";
my $hole=hex($1);
$m =~ /^\s*\$([0-9A-Fa-f]{4})\s+soft_cross\b/m or die "map lacks soft_cross\n";
my $cross=hex($1);
$hole == 0x2101 or die sprintf("same-page hole was not reused: %04X\n",$hole);
$cross == 0x220E or die sprintf("compact crossing placement was padded: %04X\n",$cross);
$m =~ /hole\.s26\.o26.*?\n\s+CODE\s+load=\$2101\s+size=\$00F7\s+page=preferred/s
 or die "preferred placement not reported\n$m";
$m =~ /cross\.s26\.o26.*?\n\s+CODE\s+load=\$220E\s+size=\$00F7\s+page=crossing/s
 or die "unavoidable crossing not reported\n$m";
$m =~ /hard\.s26\.o26.*?\n\s+HOT\s+load=\$2200\s+size=\$000E\s+page=hard/s
 or die "hard placement not reported\n$m";
print "linker soft page preference reuses holes without image growth\n";
