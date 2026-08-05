#!/usr/bin/env perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: authoritative C26 memory validated
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
sub require_fail_all {
   my ($label, $fragments, @cmd) = @_;
   my ($exit, $sig, $out, $err) = run_capture(@cmd);
   ($exit != 0 || $sig) or die "$label unexpectedly succeeded\n@cmd\n";
   for my $fragment (@$fragments) {
      index($err, $fragment) >= 0
         or die "$label stderr missing '$fragment'\nstdout:\n$out\nstderr:\n$err";
   }
}

my $repo = abs_path(shift @ARGV // die "usage: $0 REPO TMP\n");
my $tmp = shift @ARGV // die "usage: $0 REPO TMP\n";
@ARGV and die "usage: $0 REPO TMP\n";
make_path($tmp);
$tmp = abs_path($tmp) // die "could not resolve temp dir\n";

my $vcsc = File::Spec->catfile($repo, 'driver', 'vcsc');
my $vcs = File::Spec->catdir($repo, 'libraries', 'vcs');
my $empty_cfg = File::Spec->catfile($tmp, 'empty.cfg');
write_file($empty_cfg, "");

# No MEMORY or SEGMENTS block is needed. The mem declarations create the
# allocator regions and ordinary segment routes. Bank names intentionally do
# not match mem names; containment, not spelling, owns the regions.
my $direct_src = File::Spec->catfile($tmp, 'direct.c26');
my $direct_bin = File::Spec->catfile($tmp, 'direct.bin');
my $direct_map = File::Spec->catfile($tmp, 'direct.map');
write_file($direct_src, <<'SRC');
include "vcs.c26"
mem bank1 { $start:0x3000 $size:0x1000 $ro };
mem spare { $start:0x5000 $size:0x0100 $ro };
cartridge { $fill:0xaa $vectors_offset:0x0ffa $vectors_size:0x0006 };
bank fred {
   $image_size:0x1000 $file_index:0 $image_offset:0
   $link_start:0x3000 $cpu_start:0x3000 $map_size:0x1000
};
bank wilma {
   $image_size:0x1000 $file_index:1 $image_offset:0
   $link_start:0xf000 $cpu_start:0xf000 $map_size:0x1000
};
bank1 const uint8_t marker[4] := {0x11,0x22,0x33,0x44};
bank1 uint8_t helper(void) { return marker[2]; }
void main(void) { uint8_t x := helper(); while (x) { x := 0; } }
SRC
require_ok('direct authoritative mem link', $vcsc, '-I', $vcs,
           '-T', $empty_cfg, '-Map', $direct_map,
           '--no-sym', '--no-list', '--no-cfg',
           '-o', $direct_bin, $direct_src);
my $direct_image = slurp($direct_bin);
length($direct_image) == 8192
   or die "direct image length was " . length($direct_image) . "\n";
substr($direct_image, 0, 4) eq "\x11\x22\x33\x44"
   or die "C26 file order/region synthesis did not emit bank1 first\n";
my $direct_text = slurp($direct_map);
$direct_text =~ /^\s*bank1\s+start=\$3000.*output-bank=fred mode=direct/m
   or die "mem bank1 was not inferred into differently named direct bank fred\n$direct_text";
$direct_text =~ /^\s*rom\s+start=\$F000.*output-bank=wilma mode=direct/m
   or die "default mem rom was not inferred into differently named direct bank wilma\n$direct_text";
$direct_text =~ /^\s*spare\s+start=\$5000.*output-bank=<none> mode=shared/m
   or die "unused complete mem declaration was not retained as shared metadata\n$direct_text";
$direct_text !~ /^TRAMPOLINES$/m
   or die "direct-only topology generated trampolines\n$direct_text";
$direct_text =~ /^\s*\$(3[0-9A-Fa-f]{3})\s+helper\b/m
   or die "direct helper symbol missing\n$direct_text";
my $helper = hex($1);
my $direct_jsr = "\x20" . chr($helper & 0xff) . chr(($helper >> 8) & 0xff);
index(substr($direct_image, 0x1000), $direct_jsr) >= 0
   or die "cross-direct-bank call was not an ordinary absolute JSR\n";

# Minimal transitional cfg: it supplies only the legacy mapper mechanics.
# C26 supplies every allocator region and every ordinary segment route.
my $minimal_f8sc_cfg = File::Spec->catfile($tmp, 'minimal_f8sc.cfg');
write_file($minimal_f8sc_cfg, <<'CFG');
CARTRIDGE {
 mapper=F8SC;
 fillval=$FF;
 trampoline=$0F00;
 trampolinesize=$00E0;
 vectorbridge=$0FE0;
}
BANKS {
 CFG_HOME: start=$F000,size=$1000,hotspot=$1FF9,startup=yes;
 CFG_OTHER:start=$D000,size=$1000,hotspot=$1FF8,startup=no;
}
CFG

my $f8sc_src = File::Spec->catfile($tmp, 'f8sc.c26');
my $minimal_bin = File::Spec->catfile($tmp, 'minimal_f8sc.bin');
my $minimal_map = File::Spec->catfile($tmp, 'minimal_f8sc.map');
write_file($f8sc_src, <<'SRC');
include "vcs.c26"
include "superchip.c26"
mem bank0 { $start:0xf100 $size:0x0e00 $ro $priority:2 };
mem bank1 { $start:0xd100 $size:0x0e00 $ro };
cartridge {
   $fill:0xff
   $trampoline_offset:0x0f00 $trampoline_size:0x00e0
   $vector_bridge_offset:0x0fe0 $vector_bridge_size:0x0012
   $vectors_offset:0x0ffa $vectors_size:0x0006
};
bank alpha {
   $image_size:0x1000 $file_index:1 $image_offset:0x0100
   $link_start:0xf100 $cpu_start:0xf100 $map_size:0x0f00
   $select_access:0x1ff9 $startup
};
bank omega {
   $image_size:0x1000 $file_index:0 $image_offset:0x0100
   $link_start:0xd100 $cpu_start:0xf100 $map_size:0x0f00
   $select_access:0x1ff8
};
superchip uint8_t state;
bank0 void touch(void) {
   state := 0x5a;
   uint8_t x := state;
   if (x) { state := x; }
}
bank1 uint8_t remote(void) { return 7; }
void main(void) { touch(); uint8_t x := remote(); while (x) { x := 0; } }
SRC
require_ok('minimal F8SC authoritative mem link', $vcsc, '-I', $vcs,
           '-DVCS_NO_DEFAULT_ROM', '-T', $minimal_f8sc_cfg,
           '-Map', $minimal_map, '--no-sym', '--no-list', '--no-cfg',
           '-o', $minimal_bin, $f8sc_src);
my $minimal_image = slurp($minimal_bin);
length($minimal_image) == 8192 or die "minimal F8SC image is not 8K\n";
my $minimal_text = slurp($minimal_map);
$minimal_text =~ /^\s*bank0\s+start=\$F100.*output-bank=alpha mode=switched/m
   or die "mem bank0 was not inferred into selector bank alpha\n$minimal_text";
$minimal_text =~ /^\s*bank1\s+start=\$D100.*output-bank=omega mode=switched/m
   or die "mem bank1 was not inferred into selector bank omega\n$minimal_text";
$minimal_text =~ /^\s*superchip\s+read_start=\$F080 write_start=\$F000.*output-bank=<none> mode=shared/m
   or die "Superchip aliases were not classified as shared\n$minimal_text";
$minimal_text =~ /^TRAMPOLINES$/m && $minimal_text =~ /target=\$D100.*remote/s
   or die "switched ROM call did not retain an F8 trampoline\n$minimal_text";
index($minimal_image, "\xA9\x5A\x8D\x00\xF0\xAD\x80\xF0") >= 0
   or die "Superchip access did not use direct write/read aliases\n";

# The current full cfg may repeat stale allocator facts, but C26 overrides
# them. Synthesized routing must produce the same cartridge bytes.
my $full_cfg = File::Spec->catfile($vcs, 'vcs_8k_f8sc.cfg');
my $full_bin = File::Spec->catfile($tmp, 'full_f8sc.bin');
require_ok('full cfg differential F8SC link', $vcsc, '-I', $vcs,
           '-DVCS_NO_DEFAULT_ROM', '-T', $full_cfg,
           '--no-map', '--no-sym', '--no-list', '--no-cfg',
           '-o', $full_bin, $f8sc_src);
slurp($full_bin) eq $minimal_image
   or die "full cfg and C26-synthesized allocator routes emitted different ROM bytes\n";

# Separate objects must agree on a complete mem declaration, and diagnostics
# must identify both original C26 locations rather than temporary objects.
my $common_topology = <<'TOPO';
cartridge { $fill:0xff $vectors_offset:0x0ffa $vectors_size:0x0006 };
bank low { $image_size:0x1000 $file_index:0 $image_offset:0 $link_start:0x3000 $cpu_start:0x3000 $map_size:0x1000 };
bank high { $image_size:0x1000 $file_index:1 $image_offset:0 $link_start:0xf000 $cpu_start:0xf000 $map_size:0x1000 };
TOPO
my $part_a = File::Spec->catfile($tmp, 'part_a.c26');
my $part_b = File::Spec->catfile($tmp, 'part_b.c26');
write_file($part_a, qq{include "vcs.c26"\nmem extra { \$start:0x3000 \$size:0x1000 \$ro };\n$common_topology\nextra uint8_t helper(void) { return 3; }\n});
write_file($part_b, qq{include "vcs.c26"\nmem extra { \$start:0x3100 \$size:0x0f00 \$ro };\n$common_topology\nextra extern uint8_t helper(void);\nvoid main(void) { uint8_t x := helper(); while (x) { x := 0; } }\n});
require_fail_all('conflicting separate mem declarations',
   ["conflicting mem declaration 'extra'", "$part_a:", "$part_b:"],
   $vcsc, '-I', $vcs, '-T', $empty_cfg,
   '--no-map', '--no-sym', '--no-list', '--no-cfg',
   '-o', File::Spec->catfile($tmp, 'conflict.bin'), $part_a, $part_b);

# Containment must be unique. Names cannot rescue an ambiguous topology.
my $ambiguous = File::Spec->catfile($tmp, 'ambiguous.c26');
write_file($ambiguous, <<'SRC');
include "vcs.c26"
mem payload { $start:0x3800 $size:0x0100 $ro };
cartridge { $fill:0xff $vectors_offset:0x0ffa $vectors_size:0x0006 };
bank first { $image_size:0x1000 $file_index:0 $image_offset:0 $link_start:0x3000 $cpu_start:0x3000 $map_size:0x1000 };
bank second { $image_size:0x1000 $file_index:1 $image_offset:0 $link_start:0x3800 $cpu_start:0x3800 $map_size:0x1000 };
bank startup { $image_size:0x1000 $file_index:2 $image_offset:0 $link_start:0xf000 $cpu_start:0xf000 $map_size:0x1000 };
payload const uint8_t byte := 1;
void main(void) { while (byte) {} }
SRC
require_fail_all('ambiguous output-bank ownership',
   ["mem region 'payload'", 'multiple output banks', 'first', 'second'],
   $vcsc, '-I', $vcs, '-T', $empty_cfg,
   '--no-map', '--no-sym', '--no-list', '--no-cfg',
   '-o', File::Spec->catfile($tmp, 'ambiguous.bin'), $ambiguous);

print "authoritative C26 memory validated\n";
