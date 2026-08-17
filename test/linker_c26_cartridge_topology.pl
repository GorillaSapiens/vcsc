#!/usr/bin/env perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: C26 cartridge topology validated
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
sub require_fail {
   my ($label, $fragment, @cmd) = @_;
   my ($exit, $sig, $out, $err) = run_capture(@cmd);
   ($exit != 0 || $sig) or die "$label unexpectedly succeeded\n@cmd\n";
   index($err, $fragment) >= 0
      or die "$label stderr missing '$fragment'\nstdout:\n$out\nstderr:\n$err";
}

my $repo = abs_path(shift @ARGV // die "usage: $0 REPO TMP\n");
my $tmp = shift @ARGV // die "usage: $0 REPO TMP\n";
@ARGV and die "usage: $0 REPO TMP\n";
make_path($tmp);
$tmp = abs_path($tmp) // die "could not resolve temp dir\n";

my $vcsc = File::Spec->catfile($repo, 'driver', 'vcsc');
my $include = File::Spec->catfile($repo, 'test');
my $f8_cfg = File::Spec->catfile($repo, 'libraries', 'vcs', 'vcs_8k_f8.cfg');

my $direct_cfg = File::Spec->catfile($tmp, 'direct.cfg');
write_file($direct_cfg, <<'CFG');
MEMORY {
   RAM:     start=$0080, size=$0080, type=rw, define=yes, callstack=callgraph;
   bank1:   start=$3000, size=$1000, type=ro, define=yes;
   ROM:     start=$F000, size=$0FFA, type=ro, define=yes;
   VECTORS: start=$FFFA, size=$0006, type=ro, define=yes;
}
SEGMENTS {
   ZEROPAGE: load=RAM, type=zp, define=yes;
   DATA: load=ROM, run=RAM, type=data, define=yes;
   BSS: load=RAM, type=bss, define=yes;
   STARTUP: load=ROM, type=ro, define=yes;
   CODE: load=ROM, type=ro, define=yes;
   RODATA: load=ROM, type=ro, define=yes;
   CODE.bank1: load=bank1, type=ro, define=yes;
   RODATA.bank1: load=bank1, type=ro, define=yes;
   VECTORS: load=VECTORS, type=ro, start=$FFFA;
}
CFG

my $direct_topology = <<'TOPO';
cartridge { $fill:0xaa $signature:TST };
bank bank1 {
   $image_size:0x1000 $file_index:0 $image_offset:0
   $link_start:0x3000 $cpu_start:0x3000 $map_size:0x1000
};
bank rom {
   $image_size:0x1000 $file_index:1 $image_offset:0
   $link_start:0xf000 $cpu_start:0xf000 $map_size:0x1000 $startup
};
TOPO

my $direct_src = File::Spec->catfile($tmp, 'direct.c26');
my $direct_bin = File::Spec->catfile($tmp, 'direct.bin');
my $direct_map = File::Spec->catfile($tmp, 'direct.map');
write_file($direct_src, qq{include "machine_6502.c26"\nmem rom { \$start:0xf000 \$size:0x0ff8 \$ro \$priority:1 };\nmem bank1 { \$start:0x3000 \$size:0x1000 \$ro };\n$direct_topology\nbank1 const uint8_t marker[4] := {0x11,0x22,0x33,0x44};\nbank1 uint8_t helper(void) { return marker[2]; }\nvoid main(void) { uint8_t x := helper(); while (x) { x := 0; } }\n});
require_ok('direct topology link', $vcsc, '-I', $include, '-DMACHINE_6502_NO_DEFAULT_ROM', '-T', $direct_cfg,
           '-Map', $direct_map, '--no-sym', '--no-list', '--no-cfg',
           '-o', $direct_bin, $direct_src);
my $direct_image = slurp($direct_bin);
length($direct_image) == 8192
   or die "direct topology output length was " . length($direct_image) . "\n";
substr($direct_image, 0, 4) eq "\x11\x22\x33\x44"
   or die "explicit file index did not emit bank1 first\n";
substr($direct_image, 0x0ff0, 16) eq ("\xaa" x 16)
   or die "direct bank fill did not cover unused physical bytes\n";
substr($direct_image, 0x1ff8, 4) eq "TST\0"
   or die "signature was not NUL-padded into the final physical bank\n";
substr($direct_image, 0x0ff8, 4) eq ("\xaa" x 4)
   or die "signature was emitted in a non-final physical bank\n";
index(substr($direct_image, 0x1000, 0x1000), "\x78\xd8\xa2\xff") >= 0
   or die "startup/runtime bytes were not emitted in the second bank\n";
my $direct_text = slurp($direct_map);
($direct_text =~ /C26 CARTRIDGE TOPOLOGY/s
 && $direct_text =~ /^\s*bank1\s+file-index=0.*?mode=direct/m
 && $direct_text =~ /^\s*rom\s+file-index=1.*?mode=direct/m)
   or die "direct topology map output is incomplete\n$direct_text";
$direct_text !~ /^TRAMPOLINES$/m && $direct_text !~ /BANK TRAMPOLINES/
   or die "direct topology unexpectedly generated bank trampolines\n";
index($direct_text, "declaration=$direct_src:") >= 0
   or die "direct topology map lost C26 declaration locations\n$direct_text";
$direct_text =~ /^\s*\$(3[0-9A-Fa-f]{3})\s+helper\b/m
   or die "helper was not linked in the direct low bank\n$direct_text";
my $helper = hex($1);
my $call = "\x20" . chr($helper & 0xff) . chr(($helper >> 8) & 0xff);
index(substr($direct_image, 0x1000), $call) >= 0
   or die "cross-direct-bank call was not an ordinary absolute JSR\n";

my $f8_src = File::Spec->catfile($tmp, 'f8.c26');
my $f8_bin = File::Spec->catfile($tmp, 'f8.bin');
my $f8_map = File::Spec->catfile($tmp, 'f8.map');
write_file($f8_src, <<'SRC');
include "machine_6502.c26"
mem bank0 { $start:0xf000 $size:0x0f00 $ro $priority:2 };
mem bank1 { $start:0xd000 $size:0x0f00 $ro };
cartridge {
   $fill:0xff
   $trampoline_offset:0x0f00 $trampoline_size:0x00e0
   $vector_bridge_offset:0x0fe0 $vector_bridge_size:0x0012
   $vectors_offset:0x0ffa $vectors_size:0x0006
};
bank bank0 {
   $image_size:0x1000 $file_index:1 $image_offset:0
   $link_start:0xf000 $cpu_start:0xf000 $map_size:0x1000
   $select_access:0x1ff9 $startup
};
bank bank1 {
   $image_size:0x1000 $file_index:0 $image_offset:0
   $link_start:0xd000 $cpu_start:0xf000 $map_size:0x1000
   $select_access:0x1ff8
};
bank1 uint8_t helper(void) { return 7; }
void main(void) { uint8_t x := helper(); while (x) { x := 0; } }
SRC
require_ok('selector topology link', $vcsc, '-I', $include, '-T', $f8_cfg,
           '-Map', $f8_map, '--no-sym', '--no-list', '--no-cfg',
           '-o', $f8_bin, $f8_src);
length(slurp($f8_bin)) == 8192 or die "F8 topology output is not 8K\n";
my $f8_text = slurp($f8_map);
$f8_text =~ /bank1.*file-index=0.*mode=selector.*select-access=\$1FF8/s &&
$f8_text =~ /bank0.*file-index=1.*mode=selector.*select-access=\$1FF9.*startup=yes/s &&
$f8_text =~ /^TRAMPOLINES$/m
   or die "selector topology did not retain F8 switch machinery\n$f8_text";

# Byte-identical declarations from separate translation units coalesce.
my $part_a = File::Spec->catfile($tmp, 'part_a.c26');
my $part_b = File::Spec->catfile($tmp, 'part_b.c26');
write_file($part_a, qq{include "machine_6502.c26"\nmem bank1 { \$start:0x3000 \$size:0x1000 \$ro };\n$direct_topology\nbank1 uint8_t helper(void) { return 3; }\n});
write_file($part_b, qq{include "machine_6502.c26"\nmem bank1 { \$start:0x3000 \$size:0x1000 \$ro };\n$direct_topology\nbank1 extern uint8_t helper(void);\nvoid main(void) { uint8_t x := helper(); while (x) { x := 0; } }\n});
require_ok('separate identical topology declarations', $vcsc, '-I', $include,
           '-T', $direct_cfg, '--no-map', '--no-sym', '--no-list', '--no-cfg',
           '-o', File::Spec->catfile($tmp, 'separate.bin'), $part_a, $part_b);

(my $conflict_text = $direct_topology) =~ s/\$file_index:1/\$file_index:0/;
my $conflict = File::Spec->catfile($tmp, 'conflict.c26');
write_file($conflict, qq{include "machine_6502.c26"\nmem bank1 { \$start:0x3000 \$size:0x1000 \$ro };\n$conflict_text\nbank1 extern uint8_t helper(void);\nvoid main(void) { uint8_t x := helper(); while (x) { x := 0; } }\n});
{
   my ($exit, $sig, $out, $err) = run_capture(
      $vcsc, '-I', $include, '-T', $direct_cfg,
      '--no-map', '--no-sym', '--no-list', '--no-cfg',
      '-o', File::Spec->catfile($tmp, 'conflict.bin'), $part_a, $conflict);
   ($exit != 0 || $sig)
      or die "conflicting separate bank declaration unexpectedly succeeded\n";
   index($err, "conflicting bank declaration 'rom'") >= 0 &&
   index($err, "$part_a:") >= 0 && index($err, "$conflict:") >= 0
      or die "conflicting bank declaration lost source locations\nstdout:\n$out\nstderr:\n$err";
}

my $duplicate = File::Spec->catfile($tmp, 'duplicate.c26');
write_file($duplicate, <<'SRC');
include "machine_6502.c26"
cartridge { $fill:0xff };
bank one { $image_size:0x1000 $file_index:0 $image_offset:0 $link_start:0x3000 $cpu_start:0x3000 $map_size:0x1000 };
bank two { $image_size:0x1000 $file_index:0 $image_offset:0 $link_start:0xf000 $cpu_start:0xf000 $map_size:0x1000 };
void main(void) {}
SRC
require_fail('duplicate file index', 'duplicate file index 0',
             $vcsc, '-I', $include, '-T', $direct_cfg,
             '--no-map', '--no-sym', '--no-list', '--no-cfg',
             '-o', File::Spec->catfile($tmp, 'duplicate.bin'), $duplicate);

my $missing_startup = File::Spec->catfile($tmp, 'missing_startup.c26');
my $missing_text = slurp($f8_src);
$missing_text =~ s/ \$startup\n/\n/;
write_file($missing_startup, $missing_text);
require_fail('missing selector startup', 'requires exactly one startup bank',
             $vcsc, '-I', $include, '-T', $f8_cfg,
             '--no-map', '--no-sym', '--no-list', '--no-cfg',
             '-o', File::Spec->catfile($tmp, 'missing-startup.bin'), $missing_startup);

print "C26 cartridge topology validated\n";
