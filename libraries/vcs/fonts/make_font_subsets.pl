#!/usr/bin/env perl
# This file is covered under CC0-1.0. See libraries/LICENSE.txt.
use strict;
use warnings;
use File::Basename qw(basename dirname);
use File::Spec;

@ARGV == 1 or die "usage: $0 foo_ascii.c26\n";

my $in   = $ARGV[0];
my $file = basename($in);
my $dir  = dirname($in);

$file =~ /^(.*)_ascii\.c26$/
    or die "$0: input must be named foo_ascii.c26\n";
my $stem = $1;

open my $fh, '<', $in or die "$0: $in: $!\n";
local $/;
my $text = <$fh>;
close $fh;

$text =~ m{\A(.*?)(?=^[ \t]*//[ \t]*0x[0-9A-Fa-f]{2}\b)}ms
    or die "$0: could not find first glyph\n";
my $preamble = $1;

my %glyph;
while ($text =~ m{
    ^([ \t]*//[ \t]*0x([0-9A-Fa-f]{2})[^\n]*\n
      .*?
      ^[ \t]*\)[ \t]*,?[ \t]*$)
}gmsx) {
    $glyph{hex($2)} = $1;
}

my %set = (
    decimal => [ '0' .. '9' ],
    hex     => [ '0' .. '9', 'A' .. 'F' ],
    lhex    => [ '0' .. '9', 'a' .. 'f' ],
);

my %desc = (
    decimal => '0-9',
    hex     => '0-9 and A-F',
    lhex    => '0-9 and a-f',
);

for my $kind (qw(decimal hex lhex)) {
    my @codes = map { ord } @{ $set{$kind} };

    for my $code (@codes) {
        exists $glyph{$code}
            or die sprintf("%s: missing glyph 0x%02X\n", $0, $code);
    }

    my $head = $preamble;

    # Change only the title and Characters lines; retain license/comments.
    $head =~ s{^([ \t]*//[ \t]*)([^\n]*?)\s*$}{$1$2 (subset)}m;
    $head =~ s{^[ \t]*//[ \t]*Characters:.*$}{// Characters: $desc{$kind}}m;

    # Keep provenance compact.
    $head =~ s{(^[ \t]*//[ \t]*This font is covered under[^\n]*$)}
              {$1\n// Generated from $file.}m
        unless $head =~ /^[ \t]*\/\/[ \t]*Generated from \Q$file\E\./m;

    # Subsets use page.
    $head =~ s/\balign\s*\(\s*256\s*\)/page/g;

    # Fix an explicit array size, if present.
    my $rows  = () = $glyph{$codes[0]} =~ /0b[.X01]+/g;
    my $bytes = @codes * $rows;
    $head =~ s/(\bconst\s+uint8_t\s+\w+\s*)\[\s*\d+\s*\]/$1\[$bytes\]/;

    my $out = File::Spec->catfile($dir, "${stem}_${kind}.c26");
    open my $ofh, '>', $out or die "$0: $out: $!\n";

    print {$ofh} $head;

    for my $i (0 .. $#codes) {
        my $block = $glyph{$codes[$i]};
        $block =~ s/[ \t]*,?[ \t]*\z//;
        print {$ofh} $block;
        print {$ofh} "," if $i < $#codes;
        print {$ofh} "\n";
    }

    print {$ofh} "};\n";
    close $ofh;
    print "$out\n";
}
