#!/usr/bin/env perl
# This file is covered under CC0-1.0. See libraries/LICENSE.txt.
use strict;
use warnings;

# Usage:
#   ./make_pair_font.pl half_ascii.c26 "HELLO WORLD"
#
# Reads a 4x6 ASCII font in VCS_FONT_GLYPH(...) format, splits the
# message into two-character chunks, and writes an 8x6 glyph table
# to stdout.  An odd final character is paired with a space.

@ARGV == 2
    or die "usage: $0 FONTFILE \"MESSAGE\"\n";

my ($font_file, $message) = @ARGV;

open my $fh, '<', $font_file
    or die "$0: cannot open '$font_file': $!\n";

my %font;
my $code;

while (my $line = <$fh>) {
    if ($line =~ m{//\s*0x([0-9A-Fa-f]{2})\b}) {
        $code = hex($1);
        next;
    }

    next unless defined $code;
    next unless $line =~ /\bVCS_FONT_GLYPH\s*\(/;

    my @rows;
    while (my $row = <$fh>) {
        last if $row =~ /^\s*\)/;

        if ($row =~ /0b([.X]{4})/) {
            push @rows, $1;
        }
    }

    @rows == 6
        or die sprintf(
            "%s: glyph 0x%02X has %d rows; expected 6\n",
            $0, $code, scalar @rows
        );

    $font{$code} = \@rows;
    undef $code;
}

close $fh;

for my $required (0x20 .. 0x7E) {
    exists $font{$required}
        or die sprintf(
            "%s: font is missing printable ASCII glyph 0x%02X\n",
            $0, $required
        );
}

# This font is printable ASCII only.  Treat the message as bytes.
my @chars = unpack('C*', $message);

for my $c (@chars) {
    ($c >= 0x20 && $c <= 0x7E)
        or die sprintf(
            "%s: message contains unsupported byte 0x%02X; "
          . "font supports printable ASCII 0x20..0x7E\n",
            $0, $c
        );
}

push @chars, 0x20 if @chars & 1;

my $glyph_count = @chars / 2;
my $byte_count  = $glyph_count * 6;

print "// 8x6 paired-message glyphs\n";
print "// Generated from: $font_file\n";
print "// Message: ", comment_string($message), "\n";
print "// Two source characters per 8-bit glyph; odd messages are space-padded.\n\n";

print "alias VCS_FONT_GLYPH(a,b,c,d,e,f) f,e,d,c,b,a\n\n";
print "align(256) const uint8_t message_font[$byte_count] := {\n";

for (my $i = 0; $i < @chars; $i += 2) {
    my ($left, $right) = @chars[$i, $i + 1];
    my $pair = chr($left) . chr($right);
    my $n = $i / 2;

    printf "   // %d: %s (0x%02X 0x%02X)\n",
        $n, comment_string($pair), $left, $right;
    print "   VCS_FONT_GLYPH(\n";

    for my $row (0 .. 5) {
        my $bits = $font{$left}[$row] . $font{$right}[$row];
        my $comma = $row == 5 ? "" : ",";
        print "      0b$bits$comma\n";
    }

    my $comma = ($i + 2 < @chars) ? "," : "";
    print "   )$comma\n\n";
}

print "};\n";

sub comment_string {
    my ($s) = @_;
    $s =~ s/\\/\\\\/g;
    $s =~ s/"/\\"/g;
    return qq{"$s"};
}
