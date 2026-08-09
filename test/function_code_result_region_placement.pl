#!/usr/bin/env perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: function code and result regions placed independently
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub write_file {
   my ($path, $text) = @_;
   open(my $fh, '>:raw', $path) or die "could not write $path: $!\n";
   print {$fh} $text;
   close($fh);
}
sub slurp {
   my ($path) = @_;
   open(my $fh, '<:raw', $path) or die "could not read $path: $!\n";
   local $/;
   my $text = <$fh>;
   close($fh);
   return defined($text) ? $text : '';
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
sub require_ok {
   my ($label, @cmd) = @_;
   my ($exit, $sig, $out, $err) = run_capture(@cmd);
   $exit == 0 && !$sig
      or die "$label failed: exit=$exit signal=$sig\n@cmd\nstdout:\n$out\nstderr:\n$err";
   return ($out, $err);
}

my $repo = abs_path(shift @ARGV // die "usage: $0 REPO TMP\n");
my $tmp = shift @ARGV // die "usage: $0 REPO TMP\n";
@ARGV and die "usage: $0 REPO TMP\n";
make_path($tmp);
$tmp = abs_path($tmp) // die "could not resolve temp dir\n";

my $vcsc = File::Spec->catfile($repo, 'driver', 'vcsc');
my $src = File::Spec->catfile($tmp, 'regions.c26');
my $asm = File::Spec->catfile($tmp, 'regions.s26');
my $cfg = File::Spec->catfile($tmp, 'regions.cfg');
my $hex = File::Spec->catfile($tmp, 'regions.hex');
my $map = File::Spec->catfile($tmp, 'regions.map');
my $include = File::Spec->catfile($repo, 'test');

write_file($src, <<'SRC');
include "machine_6502.c26"
mem zeropage { $start:0x0000 $size:0x0080 $rw $priority:3 };
mem ram { $start:0x00A0 $size:0x0060 $rw $priority:2 };
mem rom { $start:0xF000 $size:0x1000 $ro $priority:1 };
mem orchard { $start:0xD100 $size:0x0E00 $ro };
mem basket { $start:0x0080 $size:0x0020 $rw };
mem mirror { $read_start:0x3003 $write_start:0x5007 $size:0x0004 $rw };

orchard basket uint8_t ordinary(void);
basket orchard uint8_t ordinary(void) { return 0x5a; }
mirror orchard uint16_t split(void) { return 0x1234; }
void main(void) {
   uint8_t a := ordinary();
   uint16_t b := split();
}
SRC

write_file($cfg, <<'CFG');
MEMORY {
   ZEROPAGE: start=$0000, size=$0080, type=rw;
   BASKET:   start=$0080, size=$0020, type=rw;
   RAM:      start=$00A0, size=$0060, type=rw;
   MIRROR:   read_start=$3003, write_start=$5007, size=$0004, type=rw;
   ORCHARD:  start=$D100, size=$0E00, type=ro;
   ROM:      start=$F000, size=$1000, type=ro;
}
SEGMENTS {
   ZEROPAGE:     load=ROM, run=ZEROPAGE, type=zp;
   CODE:         load=ROM, type=ro;
   CODE.orchard: load=ORCHARD, type=ro;
   RODATA:       load=ROM, type=ro;
   DATA:         load=ROM, run=RAM, type=data;
   BSS:          load=RAM, type=bss;
}
CFG

require_ok('function region assembly emission', $vcsc, '-S', '-I', $include, '-DMACHINE_6502_NO_DEFAULT_ZEROPAGE', '-DMACHINE_6502_NO_DEFAULT_CPUSTACK', '-DMACHINE_6502_NO_DEFAULT_RAM', '-DMACHINE_6502_NO_DEFAULT_ROM', 
           '-o', $asm, $src);
my $assembly = slurp($asm);
$assembly =~ /\.segment "ZEROPAGE\.basket\.__vcsc_activation\$ordinary"\s+ordinary\$__return:/s
   or die "ordinary writable result region was not used for hidden return storage\n";
$assembly =~ /\.segment "BSS\.mirror\.__vcsc_activation\$split"\s+split\$__return:/s
   or die "split writable result region was not used for hidden return storage\n";
$assembly =~ /\.segment "CODE\.orchard"\s+\.proc ordinary/s
   or die "ordinary function did not enter the read-only code region\n";
$assembly =~ /\.segment "CODE\.orchard"\s+\.proc split/s
   or die "split-return function did not independently enter the read-only code region\n";

require_ok('function region link', $vcsc, '-I', $include, '-DMACHINE_6502_NO_DEFAULT_ZEROPAGE', '-DMACHINE_6502_NO_DEFAULT_CPUSTACK', '-DMACHINE_6502_NO_DEFAULT_RAM', '-DMACHINE_6502_NO_DEFAULT_ROM', '-T', $cfg,
           '-Map', $map, '-o', $hex, $src);
my $map_text = slurp($map);
$map_text =~ /CODE\.orchard\.__vcsc_function\$ordinary\s+load=\$([0-9A-Fa-f]{4})\s+size=\$([0-9A-Fa-f]{4})/
   or die "map did not report ordinary code in ORCHARD\n$map_text";
my ($ordinary_start, $ordinary_size) = (hex($1), hex($2));
$map_text =~ /CODE\.orchard\.__vcsc_function\$split\s+load=\$([0-9A-Fa-f]{4})\s+size=\$([0-9A-Fa-f]{4})/
   or die "map did not report split code in ORCHARD\n$map_text";
my ($split_start, $split_size) = (hex($1), hex($2));
$ordinary_start == 0xD100 && $ordinary_size > 0 &&
   $split_start >= $ordinary_start + $ordinary_size && $split_size > 0 &&
   $split_start + $split_size <= 0xDF00
   or die "function code placements overlap or escape ORCHARD\n$map_text";
$map_text =~ /ZEROPAGE\.basket\.__vcsc_activation\$ordinary\s+run=\$0080\s+size=\$0001/
   or die "map did not report ordinary result storage in BASKET\n$map_text";
$map_text =~ /BSS\.mirror\.__vcsc_activation\$split\s+run=\$3003\s+write=\$5007\s+size=\$0002/
   or die "map did not report split result storage in MIRROR\n$map_text";

print "function code and result regions placed independently\n";
