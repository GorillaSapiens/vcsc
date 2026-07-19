#!/usr/bin/perl

use strict;
use warnings;
use File::Spec;
use Cwd qw(abs_path);

my $repo = abs_path($ARGV[0] // File::Spec->catdir(File::Spec->curdir(), '..'));

sub slurp {
   my ($path) = @_;
   open(my $fh, '<', $path) or die "could not open $path: $!\n";
   local $/;
   my $text = <$fh>;
   close($fh);
   return $text;
}

my @removed = (
   [qw(libraries runtime machine_6502.vcsc)],
   [qw(libraries runtime n.cfg)],
   [qw(linker default.cfg)],
);
for my $parts (@removed) {
   my $path = File::Spec->catfile($repo, @$parts);
   -e $path and die "obsolete generic target artifact remains: $path\n";
}

for my $parts (
   [qw(libraries vcs vcs.vcsc)],
   [qw(libraries vcs vcs_4k.cfg)],
   [qw(libraries vcs batari-basic standard std_kernel.asm)],
   [qw(libraries vcs batari-basic multisprite multisprite_kernel.asm)],
   [qw(test machine_6502.vcsc)],
) {
   my $path = File::Spec->catfile($repo, @$parts);
   -f $path or die "required VCS/conversion/test material is missing: $path\n";
}

my $runtime_make = slurp(File::Spec->catfile($repo, 'libraries', 'runtime', 'Makefile'));
$runtime_make !~ /\bmachine_6502\.vcsc\b/ or die "runtime install still exports the generic machine target\n";
$runtime_make !~ /\bn\.cfg\b/ or die "runtime install still exports the generic linker layout\n";

my $top_readme = slurp(File::Spec->catfile($repo, 'README.md'));
$top_readme !~ /\bruntime\/n\.cfg\b/ or die "top-level install documentation still advertises runtime/n.cfg\n";

print "generic target bundle pruned; VCS and batari references retained\n";
