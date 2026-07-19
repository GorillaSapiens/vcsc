#!/usr/bin/env perl
use strict;
use warnings;
use File::Spec;

my ($repo, $tmp) = @ARGV;
die "usage: $0 REPO TMP\n" unless defined $repo && defined $tmp;

sub write_file {
    my ($path, $text) = @_;
    open(my $fh, '>', $path) or die "cannot write $path: $!\n";
    print {$fh} $text;
    close($fh) or die "cannot close $path: $!\n";
}
sub read_file {
    my ($path) = @_;
    open(my $fh, '<', $path) or die "cannot read $path: $!\n";
    local $/; my $text = <$fh>;
    close($fh);
    return $text;
}
sub build_case {
    my ($name, $op) = @_;
    my $src = File::Spec->catfile($tmp, "$name.vcsc");
    my $out = File::Spec->catfile($tmp, "$name.hex");
    my $map = File::Spec->catfile($tmp, "$name.map");
    write_file($src, qq{include "machine_6502.vcsc"\nuint16_t dividend := 1000;\nuint16_t divisor := 37;\nuint16_t result;\nvoid main(void) { result := dividend $op divisor; }\n});
    my $driver = File::Spec->catfile($repo, 'driver', 'vcsc');
    my $inc = File::Spec->catdir($repo, 'libraries', 'runtime');
    system($driver, '-I', $inc, '-Map', $map, $src, '-o', $out) == 0
        or die "$name build failed\n";
    return read_file($map);
}

my $plain = build_case('no_division', '+');
my $div = build_case('with_division', '/');
$plain !~ /libvcsc\.a65\(_divNle\.o65\)/
    or die "division member linked into a program without division\n";
$div =~ /libvcsc\.a65\(_divNle\.o65\).*?BSS\s+run=\$[0-9A-F]+\s+size=\$0004/s
    or die "division member does not own exactly four BSS workspace bytes\n";
$div !~ /(?:_vcsc_sp|_pushN|_popN|_sp2ptr)/
    or die "division map still exposes removed software-stack machinery\n";
print "division private workspace ok\n";
