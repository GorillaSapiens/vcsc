#!/usr/bin/env perl
use strict;
use warnings;
use File::Spec;

my $repo = shift @ARGV;
die "usage: $0 REPO\n" unless defined $repo && -d $repo;

my %expected = (
    'compile_call.c'      => [1, 2],
    'compile_expr_flow.c' => [10, 31],
    'compile_expr_ops.c'  => [7, 23],
    'compile_expr_slot.c' => [3, 6],
    'compile_init.c'      => [1, 1],
    'compile_lvalue.c'    => [3, 5],
    'compile_stmt.c'      => [3, 7],
);

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

die "software-stack inventory total drift: got $total_push/$total_pop, expected 28/75\n"
    unless $total_push == 28 && $total_pop == 75;

print "software-stack inventory ok: 28 push sites, 75 pop emissions\n";
