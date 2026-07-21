#!/usr/bin/perl

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Spec;

my $repo = abs_path($ARGV[0] // File::Spec->catdir(File::Spec->curdir(), '..'));
my $path = File::Spec->catfile($repo, qw(assembler illegals.cfg));
open(my $fh, '<', $path) or die "could not open $path: $!\n";
local $/;
my $cfg = <$fh>;
close($fh);

for my $active (
   'ASR  imm  $4B',
   'SBX  imm  $CB',
) {
   $cfg =~ /^\Q$active\E\s*$/m
      or die "required active unofficial-opcode alias is missing: $active\n";
}

my @commented = (
   'DOP  imm  $80', 'DOP  imm  $82', 'DOP  imm  $89',
   'DOP  imm  $C2', 'DOP  imm  $E2',
   'DOP  zp   $04', 'DOP  zp   $44', 'DOP  zp   $64',
   'DOP  zpx  $14', 'DOP  zpx  $34', 'DOP  zpx  $54',
   'DOP  zpx  $74', 'DOP  zpx  $D4', 'DOP  zpx  $F4',
   'TOP  abs  $0C', 'TOP  absx $1C', 'TOP  absx $3C',
   'TOP  absx $5C', 'TOP  absx $7C', 'TOP  absx $DC',
   'TOP  absx $FC',
   'LXA  imm  $AB', 'OAL  imm  $AB', 'ATX  imm  $AB',
   'XAS  absy $9E', 'XAS  absy $9B',
   'AXS  zp   $87', 'AXS  zpy  $97', 'AXS  abs  $8F',
   'AXS  indx $83',
);
for my $entry (@commented) {
   $cfg =~ /^#\s*\Q$entry\E(?:\s*(?:#.*)?)?$/m
      or die "disabled alias catalog entry is missing: $entry\n";
   $cfg !~ /^\s*\Q$entry\E(?:\s*(?:#.*)?)?$/m
      or die "dangerous alias catalog entry became active: $entry\n";
}

for my $phrase (
   'double NOP',
   'triple NOP',
   'silicon-dependent',
   'two incompatible historical meanings',
   'page crossing',
   'memory-addressed alias for SAX',
   'same mnemonic would describe unrelated operations',
) {
   index($cfg, $phrase) >= 0
      or die "alias catalog lacks required warning text: $phrase\n";
}

print "assembler illegal alias catalog ok\n";
