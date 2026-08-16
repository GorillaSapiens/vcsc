#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcsc-disas all-opcode round trip ok
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path remove_tree);
use File::Spec;

my $repo = abs_path($ARGV[0] // die "missing repo\n");
my $tmp = $ARGV[1] // die "missing temp directory\n";
my $roundtrip = File::Spec->catfile($repo, 'disassembler', 'roundtrip.pl');
my $in = File::Spec->catdir($tmp, 'opcode-in');
my $out = File::Spec->catdir($tmp, 'opcode-out');
remove_tree($in, $out);
make_path($in, $out);

sub put16 {
   my ($sref, $off, $v) = @_;
   substr($$sref, $off, 2, pack('v', $v));
}

# One ROM reaches all 256 opcode bytes independently.  The main routine contains
# a JSR to every four-byte leaf.  The analyzer follows JSR fallthrough even when
# a leaf itself stops/branches/jumps, so every leaf opcode is a reachable
# instruction start.  Branch operand $02 lands exactly on the next leaf.
my $rom = chr(0xEA) x 4096;
my $main = 0x0100;
my $leaf_base = 0x0500;
my $cursor = $main;
for my $opcode (0 .. 255) {
   my $leaf = $leaf_base + $opcode * 4;
   substr($rom, $cursor, 3, pack('C v', 0x20, 0xF000 + $leaf));
   $cursor += 3;
   substr($rom, $leaf, 4, pack('C4', $opcode, 0x02, 0x60, 0x60));
}
substr($rom, $cursor, 1, "\x60");
put16(\$rom, 0xFFA, 0xF000 + $main);
put16(\$rom, 0xFFC, 0xF000 + $main);
put16(\$rom, 0xFFE, 0xF000 + $main);

my $bin = File::Spec->catfile($in, 'all_opcodes.bin');
open(my $fh, '>:raw', $bin) or die "could not create $bin: $!\n";
print {$fh} $rom;
close($fh) or die "could not close $bin: $!\n";

system($^X, $roundtrip, $in, $out) == 0
   or die "all-opcode round trip failed\n";

my $s26 = File::Spec->catfile($out, 'all_opcodes.s26');
open(my $sfh, '<', $s26) or die "could not read $s26: $!\n";
local $/;
my $text = <$sfh>;
close($sfh);

for my $opcode (0 .. 255) {
   my $addr = 0xF000 + $leaf_base + $opcode * 4;
   my $label = sprintf('L_%04X', $addr);
   $text =~ /^\Q$label\E:\n\s+(?!\.byte\b)\S+/m
      or die sprintf("opcode %02X was not emitted as an instruction at %s\n",
                     $opcode, $label);
}

print "vcsc-disas all-opcode round trip ok\n";
