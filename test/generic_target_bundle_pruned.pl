#!/usr/bin/perl
# runner: perl @FILE@ @REPO@
# expectstdout: generic target bundle pruned; VCS and legacy renderer references retained
# expectexit: 0
# phase: e2e


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
   [qw(libraries runtime machine_6502.c26)],
   [qw(libraries runtime n.cfg)],
   [qw(linker default.cfg)],
);
for my $parts (@removed) {
   my $path = File::Spec->catfile($repo, @$parts);
   -e $path and die "obsolete generic target artifact remains: $path\n";
}

for my $parts (
   [qw(libraries vcs vcs.c26)],
   [qw(libraries vcs vcs.cfg)],
   [qw(libraries vcs vcs_2k.c26)],
   [qw(libraries vcs vcs_4k.c26)],
   [qw(libraries vcs vcs_4k_sc.c26)],
   [qw(libraries vcs vcs_4k_sc.cfg)],
   [qw(libraries vcs vcs_8k_f8.c26)],
   [qw(libraries vcs vcs_12k_fa.c26)],
   [qw(libraries vcs fa_ram_plus.c26)],
   [qw(libraries vcs vcs_16k_f6.c26)],
   [qw(libraries vcs vcs_32k_f4.c26)],
   [qw(libraries vcs vcs_8k_f8sc.c26)],
   [qw(libraries vcs vcs_16k_f6sc.c26)],
   [qw(libraries vcs vcs_32k_f4sc.c26)],
   [qw(libraries vcs vcs_direct_8k.c26)],
   [qw(libraries vcs vcs_4k.cfg)],
   [qw(libraries vcs vcs_8k_f8.cfg)],
   [qw(libraries vcs vcs_12k_fa.cfg)],
   [qw(libraries vcs vcs_16k_f6.cfg)],
   [qw(libraries vcs vcs_32k_f4.cfg)],
   [qw(libraries vcs legacy-basic-renderers standard std_renderer.asm)],
   [qw(libraries vcs legacy-basic-renderers multisprite multisprite_renderer.asm)],
   [qw(test machine_6502.c26)],
) {
   my $path = File::Spec->catfile($repo, @$parts);
   -f $path or die "required VCS/conversion/test material is missing: $path\n";
}

my $runtime_make = slurp(File::Spec->catfile($repo, 'libraries', 'runtime', 'Makefile'));
$runtime_make !~ /\bmachine_6502\.c26\b/ or die "runtime install still exports the generic machine target\n";
$runtime_make !~ /\bn\.cfg\b/ or die "runtime install still exports the generic linker layout\n";

my $top_readme = slurp(File::Spec->catfile($repo, 'README.md'));
$top_readme !~ /\bruntime\/n\.cfg\b/ or die "top-level install documentation still advertises runtime/n.cfg\n";

print "generic target bundle pruned; VCS and legacy renderer references retained\n";
