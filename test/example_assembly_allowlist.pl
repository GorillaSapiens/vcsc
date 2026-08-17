#!/usr/bin/perl
# runner: perl @FILE@ @REPO@
# phase: e2e
# expectstdout: example assembly allowlist ok: 27 sources pinned, no compiler-limitation debt, and every asm use classified
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use Digest::SHA qw(sha256_hex);
use File::Find;
use File::Spec;

my $repo=abs_path(shift @ARGV // die "usage: $0 REPO\n");
die "usage: $0 REPO\n" if @ARGV;
my $fixture=File::Spec->catfile($repo,qw(test fixtures example_assembly_allowlist.tsv));
my $roadmap=File::Spec->catfile($repo,'...','ram_optimization.txt');

sub slurp {
   my($path)=@_;
   open(my $fh,'<:raw',$path) or die "read $path: $!\n";
   local $/; my $text=<$fh>; close($fh); return $text // '';
}

my %allowed_policy=map { $_=>1 } qw(beam-critical hardware-idiom compiler-limitation);
my $compiler_limitation_count=0;
my %expected;
for my $line (split /\n/,slurp($fixture)) {
   next if $line eq '' || $line =~ /^#/;
   my($path,$count,$digest,$policies,$regressions,$reason)=split /\t/,$line,6;
   defined($reason) or die "malformed assembly allowlist line: $line\n";
   $path =~ m{^examples/(?:common/|\d\d_[^/]+/)} or die "non-example allowlist path: $path\n";
   $count =~ /^\d+$/ && $count>0 or die "invalid asm count for $path\n";
   $digest =~ /^[0-9a-f]{64}$/ or die "invalid asm digest for $path\n";
   length($reason)>=20 && $reason =~ /[.!?]\z/ or die "assembly reason for $path is not standalone prose\n";
   my @policies=split /,/,$policies;
   @policies or die "missing assembly policy for $path\n";
   for my $policy (@policies) {
      $allowed_policy{$policy} or die "unknown assembly policy '$policy' for $path\n";
   }
   if (grep { $_ eq 'compiler-limitation' } @policies) {
      ++$compiler_limitation_count;
      $regressions ne '-' or die "compiler-limitation asm lacks a focused regression: $path\n";
      for my $regression (split /,/,$regressions) {
         -f File::Spec->catfile($repo,split m{/},$regression)
            or die "missing focused regression $regression for $path\n";
      }
   }
   else {
      $regressions eq '-' or die "non-debt asm unexpectedly names a debt regression: $path\n";
   }
   exists $expected{$path} and die "duplicate assembly allowlist path: $path\n";
   $expected{$path}={count=>0+$count,digest=>$digest};
}

my $roadmap_text=slurp($roadmap);
$roadmap_text =~ /Remove remaining ordinary application assembly recorded by the example allowlist\./
   or die "compiler-limitation example assembly has no named roadmap follow-up\n";

my %actual;
my $examples=File::Spec->catdir($repo,'examples');
find({no_chdir=>1,wanted=>sub {
   return unless -f $_ && /\.c26\z/;
   my $full=$File::Find::name;
   my $rel=File::Spec->abs2rel($full,$repo); $rel =~ s{\\}{/}g;
   my @asm;
   for my $line (split /\n/,slurp($full)) {
      $line =~ s/^\s+//; $line =~ s/\s+\z//;
      push @asm,$line if $line =~ /^asm\s+/;
   }
   return unless @asm;
   $actual{$rel}={count=>scalar(@asm),digest=>sha256_hex(join("\n",@asm)."\n")};
}},$examples);

for my $path (sort keys %actual) {
   exists $expected{$path} or die "unreviewed example assembly appeared in $path\n";
   $actual{$path}{count}==$expected{$path}{count}
      or die "example assembly statement count changed in $path: $actual{$path}{count} != $expected{$path}{count}\n";
   $actual{$path}{digest} eq $expected{$path}{digest}
      or die "example assembly changed in $path; review the block and update the allowlist deliberately\n";
}
for my $path (sort keys %expected) {
   exists $actual{$path} or die "stale assembly allowlist entry for $path\n";
}
$compiler_limitation_count==0
   or die "ordinary application assembly debt remains in $compiler_limitation_count allowlist entries\n";

print "example assembly allowlist ok: ".scalar(keys %actual)." sources pinned, no compiler-limitation debt, and every asm use classified\n";
