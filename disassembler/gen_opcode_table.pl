#!/usr/bin/env perl
use strict;
use warnings;

my ($cfg) = @ARGV;
die "usage: $0 default.cfg\n" if !defined($cfg) || @ARGV != 1;
open(my $fh, '<', $cfg) or die "could not open $cfg: $!\n";

my @name;
my @mode;
while (my $line = <$fh>) {
    $line =~ s/#.*//;
    next if $line =~ /^\s*$/;
    my ($mnemonic, $mode, $opcode) = $line =~ /^\s*(\S+)\s+(\S+)\s+\$([0-9A-Fa-f]{2})\s*$/;
    die "malformed opcode line in $cfg: $line" if !defined $opcode;
    my $n = hex($opcode);
    die sprintf("duplicate opcode %02X in %s\n", $n, $cfg) if defined $name[$n];
    $name[$n] = $mnemonic;
    $mode[$n] = $mode;
}
close($fh);

my %m = (
    imp=>'AM_IMPLIED', acc=>'AM_ACCUMULATOR', imm=>'AM_IMMEDIATE',
    zp=>'AM_ZERO_PAGE', zpx=>'AM_ZERO_PAGE_X', zpy=>'AM_ZERO_PAGE_Y',
    rel=>'AM_RELATIVE', abs=>'AM_ABSOLUTE', absx=>'AM_ABSOLUTE_X',
    absy=>'AM_ABSOLUTE_Y', ind=>'AM_INDIRECT', indx=>'AM_INDEXED_INDIRECT',
    indy=>'AM_INDIRECT_INDEXED',
);
for my $i (0..255) {
    die sprintf("default opcode table does not describe byte %02X\n", $i)
        if !defined $name[$i];
    die "unknown mode '$mode[$i]'\n" if !exists $m{$mode[$i]};
}

print "/* generated from assembler/default.cfg; do not edit */\n";
print "static const char *const opcode_mnemonics[256] = {\n";
for my $row (0..15) {
    print "   ";
    my @v;
    for my $col (0..15) {
        my $i = $row * 16 + $col;
        push @v, sprintf('"%s"', $name[$i]);
    }
    print join(', ', @v), $row == 15 ? "\n" : ",\n";
}
print "};\n\n";
print "static const uint8_t opcode_modes[256] = {\n";
for my $row (0..15) {
    print "   ";
    my @v;
    for my $col (0..15) {
        my $i = $row * 16 + $col;
        push @v, $m{$mode[$i]};
    }
    print join(', ', @v), $row == 15 ? "\n" : ",\n";
}
print "};\n";
