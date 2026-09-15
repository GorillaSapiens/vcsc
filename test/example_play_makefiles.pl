#!/usr/bin/perl
# runner: perl @FILE@ @REPO@
# phase: e2e
# expectstdout: example play Makefiles ok
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Find;
use File::Spec;

my $repo=abs_path(shift @ARGV // die "usage: $0 REPO\n");
die "usage: $0 REPO\n" if @ARGV;
my $examples=File::Spec->catdir($repo,'examples');

sub slurp {
   my($path)=@_;
   open(my $fh,'<:raw',$path) or die "read $path: $!\n";
   local $/;
   my $text=<$fh> // '';
   close($fh);
   return $text;
}

my @multi;
find({no_chdir=>1,wanted=>sub {
   return unless -f $File::Find::name && $File::Find::name =~ m{(?:^|/)Makefile\z};
   my $path=$File::Find::name;
   my $text=slurp($path);
   my %bins;

   # Audit declarative Makefile text only. Recipe lines are excluded so clean
   # commands and shell loops do not manufacture extra apparent outputs.
   for my $line (split /\n/,$text) {
      next if $line =~ /^\t/ || $line =~ /^\s*#/;
      $line =~ s/#.*\z//;
      while ($line =~ /\b([A-Za-z0-9_+.-]+\.bin)\b/g) {
         $bins{$1}=1;
      }
   }
   return unless keys(%bins)>1;

   my $rel=File::Spec->abs2rel($path,$repo);
   $rel =~ s{\\}{/}g;
   push @multi,$rel;

   my($play_header,$play_body)=$text =~ /^(play:[^\n]*)\n((?:\t[^\n]*\n|\s*\n)*)/m;
   defined($play_header) or die "multi-bin example lacks play target: $rel\n";
   $play_body =~ /\bfor\s+\w+\s+in\s+.+;\s*do\b/s
      or die "multi-bin example play target is not a shell for loop: $rel\n";
   $play_body =~ /\bstella\b/
      or die "multi-bin example play loop does not invoke Stella: $rel\n";
}},$examples);

@multi or die "no multi-bin example Makefiles found; audit detector is stale\n";
print "example play Makefiles ok\n";
