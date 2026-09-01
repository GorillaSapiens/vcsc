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
   [qw(libraries vcs 2K/mapper.c26)],
   [qw(libraries vcs 4K/mapper.c26)],
   [qw(libraries vcs 4KSC/mapper.c26)],
   [qw(libraries vcs F8/mapper.c26)],
   [qw(libraries vcs E0/mapper.c26)],
   [qw(libraries vcs FA/mapper.c26)],
   [qw(libraries vcs FA2/mapper_24k.c26)],
   [qw(libraries vcs FA2/mapper_28k.c26)],
   [qw(libraries vcs FA/ram.c26)],
   [qw(libraries vcs F6/mapper.c26)],
   [qw(libraries vcs JANE/mapper.c26)],
   [qw(libraries vcs F4/mapper.c26)],
   [qw(libraries vcs F8SC/mapper.c26)],
   [qw(libraries vcs F6SC/mapper.c26)],
   [qw(libraries vcs F4SC/mapper.c26)],
   [qw(test vcs_direct_8k.c26)],
   [qw(libraries vcs OMNI/mapper.c26)],
   [qw(libraries vcs legacy-basic-renderers standard std_renderer.asm)],
   [qw(libraries vcs legacy-basic-renderers multisprite multisprite_renderer.asm)],
   [qw(test machine_6502.c26)],
) {
   my $path = File::Spec->catfile($repo, @$parts);
   -f $path or die "required VCS/conversion/test material is missing: $path\n";
}


my @vcs_linker_cfg;
require File::Find;
File::Find::find(sub {
   return unless -f $_ && /\.cfg\z/;
   push @vcs_linker_cfg, $File::Find::name;
}, File::Spec->catdir($repo, 'libraries', 'vcs'));
@vcs_linker_cfg and die "obsolete VCS linker cfg files remain: @vcs_linker_cfg
";

my $runtime_make = slurp(File::Spec->catfile($repo, 'libraries', 'runtime', 'Makefile'));
$runtime_make !~ /\bmachine_6502\.c26\b/ or die "runtime install still exports the generic machine target\n";
$runtime_make !~ /\bn\.cfg\b/ or die "runtime install still exports the generic linker layout\n";

my $top_readme = slurp(File::Spec->catfile($repo, 'README.md'));
$top_readme !~ /\bruntime\/n\.cfg\b/ or die "top-level install documentation still advertises runtime/n.cfg\n";

print "generic target bundle pruned; VCS and legacy renderer references retained\n";
