#!/usr/bin/perl
# runner: perl @FILE@ @REPO@
# phase: e2e
# expectstdout: context history format ok
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Spec;

my $repo = abs_path($ARGV[0] // File::Spec->catdir(File::Spec->curdir(), '..'));
my $history = File::Spec->catdir($repo, '...', 'context-history');

# History entries may contain any number of continuation/detail lines.  Only the
# first line of each entry is constrained.  An entry header is any line that
# begins YYYY-MM-DD, and the first nonblank line in each history file must be an
# entry header.  The exact header form is:
#
#   YYYY-MM-DD HH:MM:SS PDT, short description
#
# Header lines must be strictly ASCII, the description must be 1..50 characters,
# and the entire header line must not exceed 72 characters.  Continuation/detail
# lines are deliberately unrestricted.  A missing context-history directory is
# valid because developer history is optional in stripped/source-release trees.

if (!-d $history) {
   print "context history format ok\n";
   exit 0;
}

opendir(my $dh, $history) or die "cannot open $history: $!\n";
my @files = sort grep {
   $_ ne '.' && $_ ne '..' && -f File::Spec->catfile($history, $_)
} readdir($dh);
closedir($dh);

for my $name (@files) {
   my $path = File::Spec->catfile($history, $name);
   open(my $fh, '<:raw', $path) or die "cannot open $path: $!\n";
   my @lines = <$fh>;
   close($fh);

   my $first_nonblank;
   for my $i (0 .. $#lines) {
      my $line = $lines[$i];
      $line =~ s/\r?\n\z//;
      if (!defined($first_nonblank) && $line !~ /^\s*\z/) {
         $first_nonblank = $i;
      }
   }
   next if !defined($first_nonblank);  # Empty history file has no malformed entry.

   my $first = $lines[$first_nonblank];
   $first =~ s/\r?\n\z//;
   $first =~ /^\d{4}-\d{2}-\d{2}/
      or die "$name:" . ($first_nonblank + 1) . ": first nonblank line is not an entry header\n";

   for my $i (0 .. $#lines) {
      my $line = $lines[$i];
      $line =~ s/\r?\n\z//;
      next if $line !~ /^\d{4}-\d{2}-\d{2}/;

      $line !~ /[^\x00-\x7f]/
         or die "$name:" . ($i + 1) . ": entry header is not ASCII\n";
      length($line) <= 72
         or die "$name:" . ($i + 1) . ": entry header exceeds 72 characters\n";
      my ($desc) = $line =~ /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} PDT, (.+)\z/
         or die "$name:" . ($i + 1) . ": malformed entry header\n";
      length($desc) <= 50
         or die "$name:" . ($i + 1) . ": description exceeds 50 characters\n";
   }
}

print "context history format ok\n";
