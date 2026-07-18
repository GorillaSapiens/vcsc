#!/usr/bin/env perl
use strict;
use warnings;
use File::Spec;

my $repo = shift @ARGV;
die "usage: $0 REPO\n" unless defined $repo && -d $repo;

my %expected = ();

my $compiler = File::Spec->catdir($repo, 'compiler');
opendir(my $dh, $compiler) or die "cannot open $compiler: $!\n";
my @files = sort grep { /\.c\z/ } readdir($dh);
closedir($dh);

my ($total_push, $total_pop) = (0, 0);
my %seen;
for my $file (@files) {
    my $path = File::Spec->catfile($compiler, $file);
    open(my $fh, '<', $path) or die "cannot read $path: $!\n";
    local $/;
    my $text = <$fh>;
    close($fh);
    my $push = () = $text =~ /jsr _pushN/g;
    my $pop  = () = $text =~ /jsr _popN/g;
    next if $push == 0 && $pop == 0;
    die "unclassified software-stack emitter: compiler/$file ($push pushes, $pop pops)\n"
        unless exists $expected{$file};
    my ($want_push, $want_pop) = @{$expected{$file}};
    die "software-stack inventory drift in compiler/$file: got $push/$pop, expected $want_push/$want_pop\n"
        unless $push == $want_push && $pop == $want_pop;
    $seen{$file} = 1;
    $total_push += $push;
    $total_pop += $pop;
}

for my $file (sort keys %expected) {
    die "expected software-stack emitter disappeared without inventory update: compiler/$file\n"
        unless $seen{$file};
}

die "software-stack inventory total drift: got $total_push/$total_pop, expected 0/0\n"
    unless $total_push == 0 && $total_pop == 0;

my @runtime_files = (
    File::Spec->catfile($repo, 'libraries', 'nlib', 'nlib.inc'),
    File::Spec->catfile($repo, 'libraries', 'nlib', 'nlib_zeropage.s'),
    File::Spec->catfile($repo, 'libraries', 'nlib', 'nrt0.s'),
    glob(File::Spec->catfile($repo, 'libraries', 'nlib', 'asm', '*.asm')),
);
for my $path (@runtime_files) {
    open(my $fh, '<', $path) or die "cannot read $path: $!\n";
    local $/;
    my $text = <$fh>;
    close($fh);
    die "removed software-stack symbol remains in $path\n"
        if $text =~ /(?:\b_nl_sp\b|\b_pushN\b|\b_popN\b|\b_sp2ptr[0-9])/;
}

my $ar = File::Spec->catfile($repo, 'archiver', 'n65ar');
my $archive = File::Spec->catfile($repo, 'libraries', 'nlib', 'nlib.a65');
open(my $afh, '-|', $ar, 't', $archive) or die "cannot list $archive: $!\n";
local $/;
my $members = <$afh>;
close($afh) or die "archive listing failed for $archive\n";
die "removed software-stack archive member remains\n"
    if $members =~ /(?:_pushN|_popN|_sp2ptr)/;

print "software-stack inventory ok: compiler 0/0, runtime removed\n";
