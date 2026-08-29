#!/usr/bin/perl
# runner: perl @FILE@ @REPO@
# phase: e2e
# expectstdout: vcs_example_discard_strobes ok
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Find;
use File::Spec;

my $repo=abs_path(shift @ARGV // die "usage: $0 REPO\n");
die "usage: $0 REPO\n" if @ARGV;
my $examples=File::Spec->catdir($repo,'examples');

# These TIA write registers are strobes: the bus value is ignored.  C26's
# discard store (`REG := _`) lowers directly to STA and avoids materializing a
# meaningless RHS.  If a future beam-critical use truly needs padding, express
# that timing explicitly rather than depending on a dummy value load.
my @strobe=qw(WSYNC RSYNC RESP0 RESP1 RESM0 RESM1 RESBL HMOVE HMCLR CXCLR);
my $names=join('|',@strobe);
my @bad;
my $checked=0;

find({no_chdir=>1,wanted=>sub {
   return unless -f $_ && /\.c26\z/;
   my $path=$File::Find::name;
   open(my $fh,'<',$path) or die "read $path: $!\n";
   local $/; my $text=<$fh> // ''; close($fh);
   $text =~ s{/\*.*?\*/}{}gs;
   $text =~ s{//[^\n]*}{}g;
   for my $stmt (split /;/,$text) {
      next unless $stmt =~ /\b(?:$names)\s*:=/;
      ++$checked;
      next if $stmt =~ /:=\s*_\s*\z/s;
      my $flat=$stmt;
      $flat =~ s/\s+/ /g;
      $flat =~ s/^ //; $flat =~ s/ $//;
      my $rel=File::Spec->abs2rel($path,$repo); $rel =~ s{\\}{/}g;
      push @bad,"$rel: $flat";
   }
}},$examples);

@bad and die "TIA strobe assignments must terminate in discard `_`:\n".
             join("\n",map { "- $_" } @bad)."\n";
$checked or die "no example TIA strobe assignments were audited\n";
print "vcs_example_discard_strobes ok\n";
