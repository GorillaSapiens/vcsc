#!/usr/bin/env perl
# This file is covered under CC0-1.0. See libraries/LICENSE.txt.
use strict;
use warnings;

# Usage:
#   ./make_message_glyphs.pl FONTFILE "MESSAGE"
#
# Reads a C26 bitmap font in VCS_FONT_GLYPH(...) format and packs MESSAGE
# into exactly six 8-bit output glyphs (48 columns total).
#
# Source glyphs are horizontally cropped to their used pixels.  Neighboring
# non-space characters are separated by exactly one blank column, regardless
# of how many blank edge columns the source glyphs contained.  Each literal
# space adds one extra blank column to that normal inter-character gap.
#
# Leading/trailing spaces contribute one blank column each.  The finished
# message is padded with blank columns on the right to fill all six glyphs.

@ARGV == 2
    or die "usage: $0 FONTFILE \"MESSAGE\"\n";

my ($font_file, $message) = @ARGV;

open my $fh, '<', $font_file
    or die "$0: cannot open '$font_file': $!\n";

my %font;
my ($code, $font_width, $font_height);

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

        if ($row =~ /0b([.X]+)/) {
            push @rows, $1;
        }
    }

    @rows
        or die sprintf(
            "%s: glyph 0x%02X has no bitmap rows\n",
            $0, $code
        );

    my $w = length $rows[0];
    my $h = scalar @rows;

    for my $r (@rows) {
        length($r) == $w
            or die sprintf(
                "%s: glyph 0x%02X has inconsistent row widths\n",
                $0, $code
            );
    }

    if (!defined $font_width) {
        ($font_width, $font_height) = ($w, $h);
    } else {
        $w == $font_width
            or die sprintf(
                "%s: glyph 0x%02X width %d; expected %d\n",
                $0, $code, $w, $font_width
            );

        $h == $font_height
            or die sprintf(
                "%s: glyph 0x%02X height %d; expected %d\n",
                $0, $code, $h, $font_height
            );
    }

    $font{$code} = \@rows;
    undef $code;
}

close $fh;

defined $font_height
    or die "$0: no VCS_FONT_GLYPH data found in '$font_file'\n";

$font_height <= 26
    or die "$0: source font is $font_height rows high; maximum supported is 26\n";

my @chars = unpack('C*', $message);

for my $c (@chars) {
    next if $c == 0x20;

    exists $font{$c}
        or die sprintf(
            "%s: font is missing message glyph 0x%02X (%s)\n",
            $0, $c, printable($c)
        );
}

# Build the message as rows of variable width.  Cropping each non-space glyph
# removes every all-blank edge column, so the separator we insert is the only
# whitespace between adjacent characters.
my @message_rows = ('') x $font_height;

my $have_visible = 0;
my $pending_spaces = 0;

for my $c (@chars) {
    if ($c == 0x20) {
        ++$pending_spaces;
        next;
    }

    my @cropped = crop_glyph($font{$c});

    if ($have_visible) {
        # Exactly one normal inter-character blank column, plus one more
        # for every literal space in the message.
        append_blank_columns(\@message_rows, 1 + $pending_spaces);
    } elsif ($pending_spaces) {
        # Leading spaces do not have an adjacent-character separator.
        append_blank_columns(\@message_rows, $pending_spaces);
    }

    for my $row (0 .. $font_height - 1) {
        $message_rows[$row] .= $cropped[$row];
    }

    $have_visible = 1;
    $pending_spaces = 0;
}

# Trailing spaces contribute one blank column apiece.
append_blank_columns(\@message_rows, $pending_spaces)
    if $pending_spaces;

my $used_width = length $message_rows[0];
my $output_width = 6 * 8;

$used_width <= $output_width
    or die sprintf(
        "%s: message needs %d columns after packing; six glyphs provide only %d\n",
        $0, $used_width, $output_width
    );

append_blank_columns(\@message_rows, $output_width - $used_width);

my @args = map { chr(ord('a') + $_) } 0 .. $font_height - 1;
my $byte_count = 6 * $font_height;

print "// Six 8-bit message glyphs\n";
print "// Generated from: $font_file\n";
print "// Message: ", comment_string($message), "\n";
print "// Source cell: ${font_width}x${font_height}\n";
print "// Packed width: $used_width of $output_width columns\n";
print "// Adjacent characters share exactly one blank separator column;\n";
print "// each literal space adds one additional blank column.\n\n";

print "alias VCS_FONT_GLYPH(";
print join(',', @args);
print ") ";
print join(',', reverse @args);
print "\n\n";

print "page const uint8_t message_font[$byte_count] := {\n";

for my $glyph (0 .. 5) {
    printf "   // glyph %d, columns %d..%d\n",
        $glyph, $glyph * 8, $glyph * 8 + 7;

    print "   VCS_FONT_GLYPH(\n";

    for my $row (0 .. $font_height - 1) {
        my $bits = substr($message_rows[$row], $glyph * 8, 8);
        my $comma = $row == $font_height - 1 ? '' : ',';
        print "      0b$bits$comma\n";
    }

    my $comma = $glyph == 5 ? '' : ',';
    print "   )$comma\n\n";
}

print "};\n";

exit 0;


sub crop_glyph {
    my ($rows) = @_;

    my $width = length $rows->[0];
    my ($left, $right);

    for my $x (0 .. $width - 1) {
        for my $row (@$rows) {
            if (substr($row, $x, 1) eq 'X') {
                $left = $x if !defined($left);
                $right = $x;
                last;
            }
        }
    }

    # A completely blank non-space glyph has no useful width.  Keep it as
    # one blank column rather than silently removing the character entirely.
    return ('.') x scalar(@$rows)
        if !defined $left;

    my $cropped_width = $right - $left + 1;

    return map {
        substr($_, $left, $cropped_width)
    } @$rows;
}


sub append_blank_columns {
    my ($rows, $count) = @_;
    return if !$count;

    my $blank = '.' x $count;
    $_ .= $blank for @$rows;
}


sub printable {
    my ($c) = @_;
    return chr($c) if $c >= 0x21 && $c <= 0x7e;
    return sprintf("0x%02X", $c);
}


sub comment_string {
    my ($s) = @_;
    $s =~ s/\\/\\\\/g;
    $s =~ s/"/\\"/g;
    return qq{"$s"};
}
