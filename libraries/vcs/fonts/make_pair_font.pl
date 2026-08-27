#!/usr/bin/env perl
# This file is covered under CC0-1.0. See libraries/LICENSE.txt.
use strict;
use warnings;

# Usage:
#   ./make_pair_font.pl half_ascii.c26 "HELLO WORLD"
#   ./make_pair_font.pl --score half_ascii.c26 "HELLO WORLD"
#   ./make_pair_font.pl --five half_ascii.c26 "HELLO WORLD"
#   ./make_pair_font.pl --five --wide-bracket-hash half_ascii.c26 "[#]"
#
# Reads a 4x6 ASCII font in VCS_FONT_GLYPH(...) format, splits the
# message into two-character chunks, and writes a paired glyph table to stdout.
# An odd final character is paired with a space.

my $score_mode = 0;
my $five_mode = 0;
my $wide_bracket_hash = 0;
while (@ARGV && $ARGV[0] =~ /^--/) {
    my $opt = shift @ARGV;
    if ($opt eq '--score') {
        $score_mode = 1;
    } elsif ($opt eq '--five') {
        $five_mode = 1;
    } elsif ($opt eq '--wide-bracket-hash') {
        $wide_bracket_hash = 1;
    } else {
        die "usage: $0 [--score|--five] [--wide-bracket-hash] FONTFILE \"MESSAGE\"\n";
    }
}

$score_mode && $five_mode
    and die "$0: --score and --five are mutually exclusive\n";
$wide_bracket_hash && !$five_mode
    and die "$0: --wide-bracket-hash requires --five\n";

@ARGV == 2
    or die "usage: $0 [--score|--five] [--wide-bracket-hash] FONTFILE \"MESSAGE\"\n";

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
my $rows_per_glyph = $score_mode ? 8 : $five_mode ? 5 : 6;
my @glyph_offsets;
my $byte_count = 0;
for my $glyph (0 .. $glyph_count - 1) {
    if ($five_mode && ($byte_count & 0xff) > 251) {
        $byte_count += 256 - ($byte_count & 0xff);
    }
    push @glyph_offsets, $byte_count;
    $byte_count += $rows_per_glyph;
}

print $score_mode ? "// 8x8 score-compatible paired-message glyphs\n" : $five_mode ? "// 8x5 compact paired-message glyphs\n" : "// 8x6 paired-message glyphs\n";
print "// Generated from: $font_file\n";
print "// Message: ", comment_string($message), "\n";
print "// Two source characters per 8-bit glyph; odd messages are space-padded.\n";
print "// --score adds one blank row above and below the original 4x6 pair.\n" if $score_mode;
print "// --five drops the source font's blank sixth row and page-pads only when\n" if $five_mode;
print "// needed so no five-byte glyph crosses a 256-byte page.\n" if $five_mode;
print "// --wide-bracket-hash lets [# borrow the unused fourth column of [.\n" if $wide_bracket_hash;
print "\n";

if ($score_mode) {
    print "alias VCS_FONT_GLYPH(a,b,c,d,e,f,g,h) h,g,f,e,d,c,b,a\n\n";
} elsif ($five_mode) {
    print "alias VCS_FONT_GLYPH(a,b,c,d,e) e,d,c,b,a\n\n";
} else {
    print "alias VCS_FONT_GLYPH(a,b,c,d,e,f) f,e,d,c,b,a\n\n";
}
print "align(256) const uint8_t message_font[$byte_count] := {\n";

my $emitted_bytes = 0;
for (my $i = 0; $i < @chars; $i += 2) {
    my ($left, $right) = @chars[$i, $i + 1];
    my $pair = chr($left) . chr($right);
    my $n = $i / 2;

    if ($five_mode && $emitted_bytes < $glyph_offsets[$n]) {
        my $pad = $glyph_offsets[$n] - $emitted_bytes;
        print "   // page-boundary padding before glyph $n\n";
        for (1 .. $pad) {
            print "   0,\n";
        }
        $emitted_bytes += $pad;
    }

    printf "   // %d: %s (0x%02X 0x%02X) offset=0x%03X\n",
        $n, comment_string($pair), $left, $right, $glyph_offsets[$n];
    print "   VCS_FONT_GLYPH(\n";

    my @bits = map { $font{$left}[$_] . $font{$right}[$_] } 0 .. ($five_mode ? 4 : 5);

    # The diagnostic keypad always displays # as [#].  In that composition
    # the '[' glyph leaves its fourth cell column unused, so let # borrow it
    # and render as a real five-column hash without changing the generic Half
    # font or widening any other paired character.
    if ($wide_bracket_hash && $left == ord('[') && $right == ord('#')) {
        my @hash5 = ('.X.X.', 'XXXXX', '.X.X.', 'XXXXX', '.X.X.');
        for my $row (0 .. 4) {
            my $left4 = $font{$left}[$row];
            substr($left4, 3, 1, '.');
            $bits[$row] = substr($left4, 0, 3) . $hash5[$row];
        }
    }

    @bits = ('........', @bits, '........') if $score_mode;
    for my $row (0 .. $#bits) {
        my $comma = $row == $#bits ? "" : ",";
        print "      0b$bits[$row]$comma\n";
    }

    my $comma = ($i + 2 < @chars) ? "," : "";
    print "   )$comma\n\n";
    $emitted_bytes += $rows_per_glyph;
}

print "};\n";

sub comment_string {
    my ($s) = @_;
    $s =~ s/\\/\\\\/g;
    $s =~ s/"/\\"/g;
    return qq{"$s"};
}
