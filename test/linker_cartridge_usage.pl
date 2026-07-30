#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: linker reports occupied and free cartridge ROM and RAM bytes
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub write_file {
   my ($path, $data) = @_;
   open(my $fh, '>:raw', $path) or die "write $path: $!\n";
   print {$fh} $data;
   close($fh) or die "close $path: $!\n";
}

sub slurp {
   my ($path) = @_;
   open(my $fh, '<:raw', $path) or die "read $path: $!\n";
   local $/;
   my $data = <$fh>;
   close($fh);
   return defined($data) ? $data : '';
}

sub run_capture {
   my (@cmd) = @_;
   my $err = gensym;
   my $pid = open3(my $in, my $out, $err, @cmd);
   close($in);
   local $/;
   my $stdout = <$out> // '';
   my $stderr = <$err> // '';
   waitpid($pid, 0);
   return ($? >> 8, $? & 127, $stdout, $stderr);
}

sub require_assemble {
   my ($as, $src, $obj) = @_;
   my ($exit, $sig, $out, $err) = run_capture($as, '-o', $obj, $src);
   $exit == 0 && !$sig or die "assemble failed\n$out$err";
   $out eq '' or die "assembler wrote stdout:\n$out";
   $err eq '' or die "assembler wrote stderr:\n$err";
}

my $repo = abs_path(shift @ARGV // die "usage: $0 REPO TMP\n");
my $tmp = shift @ARGV // die "usage: $0 REPO TMP\n";
@ARGV and die "usage: $0 REPO TMP\n";
make_path($tmp);
$tmp = abs_path($tmp);

my $as = File::Spec->catfile($repo, 'assembler', 'vcsc-as');
my $ld = File::Spec->catfile($repo, 'linker', 'vcsc-ld');

my $sparse_src = File::Spec->catfile($tmp, 'sparse.s26');
my $sparse_obj = File::Spec->catfile($tmp, 'sparse.o26');
my $sparse_cfg = File::Spec->catfile($tmp, 'sparse.cfg');
my $sparse_map = File::Spec->catfile($tmp, 'sparse.map');
my $sparse_hex = File::Spec->catfile($tmp, 'sparse.hex');

write_file($sparse_src, <<'ASM');
.segment "CODE"
.export __reset, __nmi, __irqbrk
__reset:
__nmi:
__irqbrk:
 rts
.segment "ALIGNED"
.byte $A5
.segment "AUX"
.byte $5A
ASM

write_file($sparse_cfg, <<'CFG');
MEMORY {
 ZEROPAGE: start=$0000,size=$0100,type=rw;
 RAM: start=$0080,size=$0080,type=rw;
 AUXROM: start=$E000,size=$0010,type=ro;
 ROM: start=$F000,size=$1000,type=ro;
}
SEGMENTS {
 ZEROPAGE: load=ROM,run=ZEROPAGE,type=zp;
 CODE: load=ROM,type=ro;
 ALIGNED: load=ROM,type=ro,align=$0010;
 AUX: load=AUXROM,type=ro;
 DATA: load=ROM,run=RAM,type=data;
 BSS: load=RAM,type=bss;
}
CFG

require_assemble($as, $sparse_src, $sparse_obj);
my ($exit, $sig, $out, $err) = run_capture(
   $ld, '-T', $sparse_cfg, '-Map', $sparse_map, '-o', $sparse_hex, $sparse_obj);
$exit == 0 && !$sig or die "sparse link failed\n$out$err";
$err eq '' or die "sparse link wrote stderr:\n$err";
$out eq <<'EXPECTED' or die "wrong sparse usage report:\n$out";
MEMORY USAGE
  AUXROM     used=1 bytes (6.25%) free=15 bytes (93.75%)
  ROM        used=20 bytes (0.49%) free=4076 bytes (99.51%)
  ZEROPAGE   used=0 bytes (0.00%) free=256 bytes (100.00%) objects=0 bytes hardware-stack=0 bytes
  RAM        used=0 bytes (0.00%) free=128 bytes (100.00%) objects=0 bytes hardware-stack=0 bytes
EXPECTED

my $map = slurp($sparse_map);
$map =~ /ALIGNED\s+load=\$F010\s+size=\$0001/
   or die "sparse fixture did not retain its deliberate ROM hole\n$map";
$map =~ /MEMORY USAGE\n  AUXROM\s+used=1 bytes \(6\.25%\) free=15 bytes \(93\.75%\)\n  ROM\s+used=20 bytes \(0\.49%\) free=4076 bytes \(99\.51%\)\n  ZEROPAGE\s+used=0 bytes \(0\.00%\) free=256 bytes \(100\.00%\) objects=0 bytes hardware-stack=0 bytes\n  RAM\s+used=0 bytes \(0\.00%\) free=128 bytes \(100\.00%\) objects=0 bytes hardware-stack=0 bytes/
   or die "map memory usage section missing or wrong\n$map";

my $full_src = File::Spec->catfile($tmp, 'full.s26');
my $full_obj = File::Spec->catfile($tmp, 'full.o26');
my $full_cfg = File::Spec->catfile($tmp, 'full.cfg');
my $full_bin = File::Spec->catfile($tmp, 'full.bin');

write_file($full_src, <<'ASM');
.segment "CODE"
.export __reset, __nmi, __irqbrk
__reset:
__nmi:
__irqbrk:
 rts
.res 4077
ASM

write_file($full_cfg, <<'CFG');
MEMORY {
 ZEROPAGE: start=$0000,size=$0100,type=rw;
 RAM: start=$0080,size=$0080,type=rw;
 ROM: start=$F000,size=$1000,type=ro;
}
SEGMENTS {
 ZEROPAGE: load=ROM,run=ZEROPAGE,type=zp;
 CODE: load=ROM,type=ro;
 DATA: load=ROM,run=RAM,type=data;
 BSS: load=RAM,type=bss;
}
CFG

require_assemble($as, $full_src, $full_obj);
($exit, $sig, $out, $err) = run_capture(
   $ld, '-T', $full_cfg, '-o', $full_bin, $full_obj);
$exit == 0 && !$sig or die "full link failed\n$out$err";
$err eq '' or die "full link wrote stderr:\n$err";
$out eq <<'EXPECTED' or die "wrong full usage report:\n$out";
MEMORY USAGE
  ROM        used=4096 bytes (100.00%) free=0 bytes (0.00%)
  ZEROPAGE   used=0 bytes (0.00%) free=256 bytes (100.00%) objects=0 bytes hardware-stack=0 bytes
  RAM        used=0 bytes (0.00%) free=128 bytes (100.00%) objects=0 bytes hardware-stack=0 bytes
EXPECTED
-s $full_bin == 4096 or die "exact-full binary is not 4096 bytes\n";

my $overflow_src = File::Spec->catfile($tmp, 'overflow.s26');
my $overflow_obj = File::Spec->catfile($tmp, 'overflow.o26');
my $overflow_bin = File::Spec->catfile($tmp, 'overflow.bin');
write_file($overflow_src, <<'ASM');
.segment "CODE"
.export __reset, __nmi, __irqbrk
__reset:
__nmi:
__irqbrk:
 rts
.res 4078
ASM
require_assemble($as, $overflow_src, $overflow_obj);
($exit, $sig, $out, $err) = run_capture(
   $ld, '-T', $full_cfg, '-o', $overflow_bin, $overflow_obj);
$exit != 0 && !$sig or die "overflow fixture unexpectedly linked\n$out$err";
$out eq '' or die "failed link emitted a success usage report:\n$out";
$err =~ /ROM overflow/ or die "overflow diagnostic missing:\n$err";

print "linker reports occupied and free cartridge ROM and RAM bytes\n";
