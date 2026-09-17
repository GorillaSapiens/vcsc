#!/usr/bin/perl
# runner: perl @FILE@ @REPO@
# phase: e2e
# expectstdout: vcs_example_strobe_sources ok
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
# Direct-register strobe stores (`REG := $A`) lower directly to STA without
# materializing a meaningless RHS. All maintained examples must use the DRA
# spelling now that the renderer/diagnostic migration is complete.
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
      my $rel=File::Spec->abs2rel($path,$repo); $rel =~ s{\\}{/}g;
      next if $stmt =~ /:=\s*\$A\s*\z/s;
      my $flat=$stmt;
      $flat =~ s/\s+/ /g;
      $flat =~ s/^ //; $flat =~ s/ $//;
      push @bad,"$rel: $flat";
   }
}},$examples);

@bad and die "TIA strobe assignments must terminate in direct register `\$A`:\n".
             join("\n",map { "- $_" } @bad)."\n";
$checked or die "no example TIA strobe assignments were audited\n";
print "vcs_example_strobe_sources ok\n";
