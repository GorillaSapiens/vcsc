#!/usr/bin/perl
use strict;
use warnings;
use File::Basename qw(basename);

my @sources = ('../compiler/compile.c', '../compiler/float.c');
my %want;
my %have_call;

for my $src (@sources) {
   open(my $fh, '<', $src) or die "could not open $src: $!\n";
   my $line = 0;
   while (my $text = <$fh>) {
      $line++;
      if ($text =~ /error_unimplemented\(/) {
         my $base = basename($src, '.c');
         my $name = "unimpl_${base}_${line}.n";
         $want{$name} = 1;
         $have_call{"${base}:${line}"} = 1;
      }
   }
   close($fh);
}

my @missing;
for my $name (sort keys %want) {
   push @missing, $name unless -f $name;
}

my @stale;
for my $path (glob('unimpl_*.n')) {
   my $name = basename($path);
   next if exists $want{$name};
   if ($name =~ /^unimpl_([A-Za-z0-9_]+)_(\d+)\.n$/) {
      my ($base, $line) = ($1, $2);
      push @stale, "$name (no error_unimplemented at ${base}:${line})"
         unless $have_call{"${base}:${line}"};
   }
}

if (@stale) {
   print STDERR "warning: stale unimplemented coverage tests:\n";
   print STDERR "$_\n" for @stale;
}

if (@missing) {
   print "missing unimplemented coverage tests:\n";
   print "$_\n" for @missing;
   exit 1;
}

print "unimplemented coverage audit OK\n";
