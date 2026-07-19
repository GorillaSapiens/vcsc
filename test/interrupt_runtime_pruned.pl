#!/usr/bin/perl

use strict;
use warnings;
use File::Spec;
use Cwd qw(abs_path);

my $repo = abs_path($ARGV[0] // File::Spec->catdir(File::Spec->curdir(), '..'));
my $nint = File::Spec->catdir($repo, 'libraries', 'nint');
my $runtime = File::Spec->catdir($repo, 'libraries', 'runtime');
my $archive = File::Spec->catfile($runtime, 'libvcsc.a65');
my $ar = File::Spec->catfile($repo, 'archiver', 'vcsc-ar');

sub slurp {
   my ($path) = @_;
   open(my $fh, '<', $path) or die "could not open $path: $!\n";
   local $/;
   my $text = <$fh>;
   close($fh);
   return $text;
}

-d $nint and die "obsolete interrupt library remains: $nint\n";
-f File::Spec->catfile($runtime, 'asm', 'handler.asm')
   and die "obsolete default interrupt handlers remain\n";
-f File::Spec->catfile($runtime, 'vcsc-rt0-noint.s')
   and die "obsolete separate vector-stub source remains\n";

my $startup = slurp(File::Spec->catfile($runtime, 'vcsc-rt0.s'));
$startup =~ /^\.weak __nmi$/m or die "stock startup lacks weak __nmi vector filler\n";
$startup =~ /^\.weak __irqbrk$/m or die "stock startup lacks weak __irqbrk vector filler\n";
$startup =~ /__nmi:\s*\n__irqbrk:\s*\n\s*rti\b/s
   or die "stock startup lacks the shared RTI vector filler\n";

my $makefile = slurp(File::Spec->catfile($repo, 'Makefile'));
$makefile !~ m{libraries/nint} or die "top-level build still references libraries/nint\n";

open(my $members, '-|', $ar, 't', $archive)
   or die "could not list $archive: $!\n";
my $listing = do { local $/; <$members> };
close($members) or die "could not list $archive\n";
for my $obsolete ('_handle_irq.o65', '_handle_nmi.o65', 'vcsc-rt0-noint.o65') {
   index($listing, "$obsolete\n") < 0
      or die "obsolete archive member remains: $obsolete\n";
}
index($listing, "vcsc-rt0.o65\n") >= 0 or die "startup archive member is missing\n";

print "interrupt runtime pruned: required vector stubs only\n";
