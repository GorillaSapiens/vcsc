#!/usr/bin/perl
# This file is covered under CC0-1.0. See libraries/LICENSE.txt.

use strict;
use warnings;
use Getopt::Long;

my $first = 0x20;
my $last  = 0x7e;
my $name  = 'score_font';
my $strict = 0;

GetOptions(
    'first=s' => sub { $first = parse_number($_[1]); },
    'last=s'  => sub { $last  = parse_number($_[1]); },
    'name=s'  => \$name,
    'strict!' => \$strict,
) or usage();

@ARGV == 1 or usage();

my $filename = shift @ARGV;
open my $fh, '<', $filename
    or die "$filename: $!\n";

my ($font_name, @comments);
my ($font_w, $font_h, $font_x, $font_y);
my %glyphs;

my $glyph;

while (my $line = <$fh>) {
    chomp $line;
    $line =~ s/\r$//;

    if ($line =~ /^FONT\s+(.+)/) {
        $font_name = $1;
        next;
    }

    if ($line =~ /^COMMENT(?:\s+(.*))?/) {
        push @comments, defined($1) ? $1 : '';
        next;
    }

    if ($line =~ /^FONTBOUNDINGBOX\s+(-?\d+)\s+(-?\d+)\s+(-?\d+)\s+(-?\d+)/) {
        ($font_w, $font_h, $font_x, $font_y) = ($1, $2, $3, $4);
        next;
    }

    if ($line =~ /^STARTCHAR(?:\s+(.*))?/) {
        $glyph = {
            name   => defined($1) ? $1 : '',
            bitmap => [],
        };
        next;
    }

    next unless $glyph;

    if ($line =~ /^ENCODING\s+(-?\d+)/) {
        $glyph->{encoding} = $1;
        next;
    }

    if ($line =~ /^BBX\s+(-?\d+)\s+(-?\d+)\s+(-?\d+)\s+(-?\d+)/) {
        @{$glyph}{qw(w h x y)} = ($1, $2, $3, $4);
        next;
    }

    if ($line eq 'BITMAP') {
        $glyph->{in_bitmap} = 1;
        next;
    }

    if ($line eq 'ENDCHAR') {
        if (defined $glyph->{encoding} && $glyph->{encoding} >= 0) {
            $glyphs{$glyph->{encoding}} = $glyph;
        }
        undef $glyph;
        next;
    }

    if ($glyph->{in_bitmap}) {
        if ($line =~ /^[0-9A-Fa-f]+$/) {
            push @{$glyph->{bitmap}}, $line;
        }
    }
}

close $fh;

defined $font_w
    or die "$filename: no FONTBOUNDINGBOX\n";

$font_w > 0 && $font_h > 0
    or die "$filename: invalid FONTBOUNDINGBOX\n";

$font_w <= 8
    or die "$filename: font is $font_w pixels wide; VCSC uint8_t fonts support at most 8\n";

$font_h <= 26
    or die "$filename: font is $font_h pixels high; this script supports at most 26 rows\n";

$first <= $last
    or die "--first must be <= --last\n";

my @args = map { chr(ord('a') + $_) } 0 .. $font_h - 1;

print "// Generated from $filename\n";
print "// BDF font: $font_name\n" if defined $font_name;

for my $comment (@comments) {
    print "// $comment\n";
}

printf "// Cell size: %dx%d\n", $font_w, $font_h;
printf "// Characters: 0x%02X through 0x%02X\n", $first, $last;
print "// Glyph rows are written top-to-bottom for visual readability; the\n";
print "// VCS_FONT_GLYPH alias reverses each glyph for the score kernel.\n";
print "\n";

print "alias VCS_FONT_GLYPH(";
print join(',', @args);
print ") ";
print join(',', reverse @args);
print "\n\n";

my $count = $last - $first + 1;
my $size  = $count * $font_h;

print "page const uint8_t $name\[$size\] := {\n";

for my $code ($first .. $last) {
    my @rows;

    if (exists $glyphs{$code}) {
        @rows = render_glyph(
            $glyphs{$code},
            $font_w, $font_h, $font_x, $font_y
        );
    }
    else {
        if ($strict) {
            die sprintf(
                "%s: missing glyph 0x%02X\n",
                $filename, $code
            );
        }

        warn sprintf(
            "%s: warning: missing glyph 0x%02X; using blank\n",
            $filename, $code
        );

        @rows = ('.' x $font_w) x $font_h;
    }

    my $description = char_description($code);

    printf "   // 0x%02X %s\n", $code, $description;
    print "   VCS_FONT_GLYPH(\n";

    for my $i (0 .. $#rows) {
        my $comma = $i == $#rows ? '' : ',';
        print "      0b$rows[$i]$comma\n";
    }

    print "   )";

    print "," if $code != $last;
    print "\n\n";
}

print "};\n";

exit 0;


sub render_glyph {
    my ($g, $fw, $fh, $fx, $fy) = @_;

    for my $required (qw(w h x y)) {
        defined $g->{$required}
            or die sprintf(
                "glyph %s (encoding %d): missing BBX\n",
                $g->{name} || '?',
                $g->{encoding}
            );
    }

    @{$g->{bitmap}} == $g->{h}
        or die sprintf(
            "glyph %s (encoding %d): expected %d bitmap rows, got %d\n",
            $g->{name} || '?',
            $g->{encoding},
            $g->{h},
            scalar @{$g->{bitmap}}
        );

    my @cell = map { [ (0) x $fw ] } 1 .. $fh;

    #
    # BDF coordinates are relative to the baseline.
    #
    # FONTBOUNDINGBOX describes the common cell:
    #
    #     x = fx .. fx + fw - 1
    #     y = fy .. fy + fh - 1
    #
    # BITMAP rows are stored top-to-bottom.
    #

    my $dest_x = $g->{x} - $fx;

    my $font_top  = $fy + $fh;
    my $glyph_top = $g->{y} + $g->{h};

    my $dest_y = $font_top - $glyph_top;

    for my $src_y (0 .. $g->{h} - 1) {
        my $hex = $g->{bitmap}[$src_y];

        my $bits = join '',
            map { sprintf '%04b', hex($_) }
            split //, $hex;

        length($bits) >= $g->{w}
            or die sprintf(
                "glyph %s: bitmap row too short: %s\n",
                $g->{name} || '?',
                $hex
            );

        #
        # BDF stores the leftmost glyph pixel in the MSB.
        #
        $bits = substr($bits, 0, $g->{w});

        for my $src_x (0 .. $g->{w} - 1) {
            next unless substr($bits, $src_x, 1) eq '1';

            my $x = $dest_x + $src_x;
            my $y = $dest_y + $src_y;

            #
            # FONTBOUNDINGBOX should contain every glyph, but clipping
            # here makes the converter tolerant of eccentric BDF files.
            #
            next if $x < 0 || $x >= $fw;
            next if $y < 0 || $y >= $fh;

            $cell[$y][$x] = 1;
        }
    }

    return map {
        join '', map { $_ ? 'X' : '.' } @$_
    } @cell;
}


sub char_description {
    my ($c) = @_;

    return 'space'        if $c == 0x20;
    return 'double quote' if $c == 0x22;
    return 'apostrophe'   if $c == 0x27;
    return 'backslash'    if $c == 0x5c;
    return 'grave accent' if $c == 0x60;

    return chr($c) if $c >= 0x21 && $c <= 0x7e;

    return sprintf('U+%04X', $c);
}


sub parse_number {
    my ($s) = @_;

    return hex($1) if $s =~ /^0x([0-9a-f]+)$/i;
    return int($s) if $s =~ /^\d+$/;

    die "invalid number: $s\n";
}


sub usage {
    die <<"EOF";
usage: bdf2c26.pl [options] font.bdf > font_ascii.c26

options:
  --first N       first character code (default 0x20)
  --last N        last character code  (default 0x7e)
  --name NAME     C26 array name        (default score_font)
  --strict        fail rather than blank-fill missing glyphs

examples:
  bdf2c26.pl spleen-5x8.bdf > spleen_ascii.c26
  bdf2c26.pl --first 0x30 --last 0x39 foo.bdf > foo_decimal.c26
EOF
}
