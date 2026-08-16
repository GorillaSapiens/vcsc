#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectexit: 0
# expectstdout: renderer branch contracts ok
# expectstderrexact:

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Find qw(find);
use File::Spec;

my $repo = shift @ARGV // die "usage: $0 REPO TMP\n";
shift @ARGV; # generic runner TMP, not needed
$repo = abs_path($repo) // die "could not resolve repo root\n";
my $root = File::Spec->catdir($repo, qw(libraries vcs renderers));
-d $root or die "missing renderer library: $root\n";

# Hand-written renderer branches are timing contracts, not generic compiler
# control flow.  Every conditional branch must say whether its taken path is
# required to remain on the same 256-byte CPU page or cross exactly one page.
# A bare branch or .flex would let final link placement silently change a cycle.
my @errors;
my $count = 0;
find({
   no_chdir => 1,
   wanted => sub {
      return unless -f $_ && /\.(?:c26|s26)$/;
      my $path = $File::Find::name;
      open(my $fh, '<', $path) or die "read $path: $!\n";
      my $line_no = 0;
      while (my $line = <$fh>) {
         ++$line_no;
         next if $line =~ m{^\s*(?://|;)};
         my ($mnemonic, $policy);
         if ($path =~ /\.c26$/) {
            next unless $line =~ /^\s*asm\s+(b(?:cc|cs|eq|mi|ne|pl|vc|vs))(?:\.(same|cross|flex))?\b/i;
            ($mnemonic, $policy) = (lc($1), defined($2) ? lc($2) : '');
         } else {
            next unless $line =~ /^\s*(b(?:cc|cs|eq|mi|ne|pl|vc|vs))(?:\.(same|cross|flex))?\b/i;
            ($mnemonic, $policy) = (lc($1), defined($2) ? lc($2) : '');
         }
         ++$count;
         push @errors, "$path:$line_no: $mnemonic must use .same or .cross"
            unless $policy eq 'same' || $policy eq 'cross';
      }
      close($fh);
   },
}, $root);

$count > 0 or die "renderer branch audit found no conditional branches\n";
die join("\n", @errors) . "\n" if @errors;
print "renderer branch contracts ok\n";
