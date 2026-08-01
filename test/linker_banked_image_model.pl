#!/usr/bin/env perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: banked image model enforced
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use Digest::SHA qw(sha256_hex);
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
my $stock_cfg = File::Spec->catfile($repo, 'libraries', 'vcs', 'vcs_4k.cfg');
my $src = File::Spec->catfile($tmp, 'banked.c26');
my $cfg = File::Spec->catfile($tmp, 'banked.cfg');
my $bin = File::Spec->catfile($tmp, 'banked.bin');
my $map = File::Spec->catfile($tmp, 'banked.map');

write_file($src, <<'SRC');
include "machine_6502.c26"
mem bank1 { $start:0xD000 $size:0x0FE0 $ro };

bank1 void placed(void) {
   asm nop;
}

void main(void) {
   asm nop;
}
SRC

my $extras = join('', map {
   sprintf("   EXTRA%02d: start=\$%04X, size=\$0001, type=rw;\n", $_, 0x0200 + $_)
} 0 .. 17);
my $dummy_segments = join('', map {
   sprintf("   UNUSED%02d: load=ROM, type=ro;\n", $_)
} 0 .. 17);

my $valid_cfg = <<"CFG";
CARTRIDGE {
   mapper = F8;
   fillval = \$A5;
   vectorbridge = \$0FE0;
}
BANKS {
   BANK0: start=\$F000, size=\$1000, hotspot=\$1FF9, startup=yes;
   BANK1: start=\$D000, size=\$1000, hotspot=\$1FF8, startup=no;
}
MEMORY {
   ZEROPAGE: start=\$0000, size=\$0080, type=rw;
   RAM: start=\$0080, size=\$0080, type=rw;
$extras   bank1: start=\$D000, size=\$0FE0, type=ro, bank=BANK1;
   BANK1_VECTOR_BRIDGE: start=\$DFE0, size=\$0012, bank=BANK1;
   BANK1_TAIL: start=\$DFF2, size=\$0008, bank=BANK1;
   BANK1_VECTORS: start=\$DFFA, size=\$0006, bank=BANK1;
   ROM: start=\$F000, size=\$0FE0, type=ro, bank=BANK0;
   BANK0_VECTOR_BRIDGE: start=\$FFE0, size=\$0012, bank=BANK0;
   BANK0_TAIL: start=\$FFF2, size=\$0008, bank=BANK0;
   BANK0_VECTORS: start=\$FFFA, size=\$0006, bank=BANK0;
}
SEGMENTS {
   ZEROPAGE: load=ROM, run=ZEROPAGE, type=zp;
   DATA: load=ROM, run=RAM, type=data;
   BSS: load=RAM, type=bss;
   STARTUP: load=ROM, type=ro;
   CODE: load=ROM, type=ro;
   CODE.bank1: load=bank1, type=ro;
   RODATA: load=ROM, type=ro;
   VECTORS: load=BANK0_VECTORS, type=ro, start=\$FFFA;
$dummy_segments}
CFG
write_file($cfg, $valid_cfg);

require_ok('banked F8 link', $vcsc, '-I', $include, '-T', $cfg,
           '-Map', $map, '--no-sym', '--no-list', '--no-cfg',
           '-o', $bin, $src);
my $image = slurp($bin);
length($image) == 8192
   or die "banked output length was " . length($image) . ", expected 8192\n";
substr($image, 0, 2) eq "\xEA\x60"
   or die "lowest logical bank was not emitted first with BANK1 function bytes\n";
substr($image, 0x0FF2, 8) eq ("\xA5" x 8)
   or die "BANK1 reserved tail was not retained as fill before per-bank vectors\n";
substr($image, 0x1000, 4) eq "\x78\xD8\xA2\xFF"
   or die "BANK0/runtime bytes were not emitted as the final physical bank\n";
my $bank1_bridge = substr($image, 0x0FE0, 18);
my $bank0_bridge = substr($image, 0x1FE0, 18);
$bank1_bridge eq $bank0_bridge && $bank1_bridge ne ("\xA5" x 18)
   or die "vector bridge bytes were not replicated identically in both banks\n";
my $bank1_vectors = substr($image, 0x0FFA, 6);
my $bank0_vectors = substr($image, 0x1FFA, 6);
$bank1_vectors eq $bank0_vectors
   or die "per-bank vectors were not byte-identical\n";
ord(substr($bank0_vectors, 1, 1)) == 0xFF &&
ord(substr($bank0_vectors, 3, 1)) == 0xFF &&
ord(substr($bank0_vectors, 5, 1)) == 0xFF
   or die "per-bank vectors do not use BANK0's F000 logical mirror\n";

my $map_text = slurp($map);
$map_text =~ /mapper=F8 output-size=\$00002000 fill=\$A5 vectorbridge=\$FE0 size=\$12/
   or die "map omitted F8 image/bridge metadata\n$map_text";
$map_text =~ /BANK1\s+start=\$D000.*hotspot=\$1FF8.*file=\$00000000/
   or die "map did not assign BANK1 physical file offset zero\n$map_text";
$map_text =~ /BANK0\s+start=\$F000.*hotspot=\$1FF9.*file=\$00001000 startup=yes/
   or die "map did not put BANK0 last with the conventional F8 selector\n$map_text";
$map_text =~ /^\s*\$D000\s+placed\b/m
   or die "placed function did not retain its D000 logical address\n$map_text";
$map_text =~ /^\s*\$F[0-9A-Fa-f]{3}\s+main\b/m
   or die "main did not remain in the BANK0 mirror\n$map_text";

my $unknown_cfg = File::Spec->catfile($tmp, 'unknown.cfg');
(my $unknown_text = $valid_cfg) =~ s/hotspot=\$1FF8/hotpsot=\$1FF8/;
write_file($unknown_cfg, $unknown_text);
require_fail('unknown bank property', "unknown BANKS property 'hotpsot'",
             $vcsc, '-I', $include, '-T', $unknown_cfg,
             '--no-map', '--no-sym', '--no-list', '--no-cfg',
             '-o', File::Spec->catfile($tmp, 'unknown.bin'), $src);

my $hotspot_cfg = File::Spec->catfile($tmp, 'hotspot-overlap.cfg');
my $hotspot_text = $valid_cfg;
$hotspot_text =~ s/   BANK1_TAIL: start=\$DFF2, size=\$0008, bank=BANK1;/   bank1_tail: start=\$DFF2, size=\$0008, type=ro, bank=BANK1;/;
$hotspot_text =~ s/   UNUSED00: load=ROM, type=ro;/   UNUSED00: load=bank1_tail, type=ro;/;
write_file($hotspot_cfg, $hotspot_text);
require_fail('ordinary code over bank hotspot', 'covers reserved bank hotspot $DFF9',
             $vcsc, '-I', $include, '-T', $hotspot_cfg,
             '--no-map', '--no-sym', '--no-list', '--no-cfg',
             '-o', File::Spec->catfile($tmp, 'hotspot.bin'), $src);

my $bridge_cfg = File::Spec->catfile($tmp, 'bridge-overlap.cfg');
my $bridge_text = $valid_cfg;
$bridge_text =~ s/   BANK1_VECTOR_BRIDGE: start=\$DFE0, size=\$0012, bank=BANK1;/   bank1_bridge: start=\$DFE0, size=\$0012, type=ro, bank=BANK1;/;
$bridge_text =~ s/   UNUSED00: load=ROM, type=ro;/   UNUSED00: load=bank1_bridge, type=ro;/;
write_file($bridge_cfg, $bridge_text);
require_fail('ordinary code over vector bridge', 'covers reserved vector bridge $DFE0-$DFF1',
             $vcsc, '-I', $include, '-T', $bridge_cfg,
             '--no-map', '--no-sym', '--no-list', '--no-cfg',
             '-o', File::Spec->catfile($tmp, 'bridge.bin'), $src);

my $unbanked_src = File::Spec->catfile($tmp, 'unbanked.c26');
my $unbanked_bin = File::Spec->catfile($tmp, 'unbanked.bin');
write_file($unbanked_src, <<'SRC');
include "machine_6502.c26"
void main(void) { asm nop; }
SRC
require_ok('unbanked compatibility link', $vcsc, '-I', $include,
           '-T', $stock_cfg, '--no-map', '--no-sym', '--no-list', '--no-cfg',
           '-o', $unbanked_bin, $unbanked_src);
my $unbanked = slurp($unbanked_bin);
length($unbanked) == 4096 or die "stock 4K output size changed\n";
sha256_hex($unbanked) eq '1545f4ba63204f67f96dbe741bd63f03ecc0e42f2e2a7c3e45775ab4f16f6ce7'
   or die "stock vcs_4k.cfg output changed byte-for-byte\n";

print "banked image model enforced\n";
