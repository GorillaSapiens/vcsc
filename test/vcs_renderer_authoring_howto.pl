#!/usr/bin/perl
# runner: perl @FILE@ @REPO@
# phase: e2e
# expectstdout: renderer authoring HOWTO ok
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Spec;

sub slurp {
   my ($path)=@_;
   open my $fh,'<',$path or die "open $path: $!\n";
   local $/;
   my $s=<$fh>;
   close $fh;
   return $s;
}

sub require_text {
   my ($body,$needle,$why)=@_;
   index($body,$needle)>=0 or die "$why\n";
}

my $repo=abs_path(shift @ARGV // '.') // die "resolve repository root\n";
die "usage: $0 REPO\n" if @ARGV;

my $path=File::Spec->catfile($repo,qw(libraries vcs renderers AUTHORING.md));
-f $path or die "renderer authoring HOWTO is missing\n";
my $doc=slurp($path);

require_text($doc,'# VCSC renderer-authoring HOWTO','HOWTO lost its primary heading');
require_text($doc,'## 1. Start with a new profile, not a mutation of an old one',
   'HOWTO lost profile-isolation rules');
require_text($doc,'## 2. Define the source contract before scheduling the raster',
   'HOWTO lost source-contract rules');
require_text($doc,'TEMPLATE_DRAW_ENTRY_CYCLE','HOWTO lost machine-readable handoff fields');
require_text($doc,'## 3. Separate application-visible state from private workspace',
   'HOWTO lost public/private state rules');
require_text($doc,'## 4. Respect frame-phase ownership','HOWTO lost frame-phase ownership');
require_text($doc,'must not write `VSYNC`, `VBLANK`, or a RIOT frame timer',
   'HOWTO lost scheduler-owned frame-register rule');
require_text($doc,'## 5. Publish hooks, clobbers, incoming assumptions, and exit state',
   'HOWTO lost hook/clobber rules');
require_text($doc,'With `VDELBL` enabled','HOWTO lost delayed-Ball latch warning');
require_text($doc,'## 6. Treat the hardware stack as owned memory',
   'HOWTO lost hidden hardware-stack accounting');
require_text($doc,'execute no push, pull, JSR, RTS','HOWTO lost borrowed-S safety rule');
require_text($doc,'## 7. Budget RAM and ROM from linked artifacts',
   'HOWTO lost linked RAM/ROM accounting');
require_text($doc,'## 8. Make object placement and page requirements explicit',
   'HOWTO lost linker/page-placement rules');
require_text($doc,'`page` means the complete object must fit within one 256-byte page',
   'HOWTO conflated page containment with alignment');
require_text($doc,'`align(256)` means the object starts on a 256-byte boundary',
   'HOWTO lost explicit alignment semantics');
require_text($doc,'Use `.same` when the branch','HOWTO lost branch-page timing annotations');
require_text($doc,'## 9. Normalize retained legacy source reproducibly',
   'HOWTO lost source-normalization procedure');
require_text($doc,'provide a `--check` mode','HOWTO lost normalization reproducibility gate');
require_text($doc,'## 10. Design the cycle schedule before optimizing it',
   'HOWTO lost cycle/TIA scheduling rules');
require_text($doc,'Preserve internal phases, not only total cycles',
   'HOWTO lost internal-phase warning');
require_text($doc,'Processor flags are live timing state',
   'HOWTO lost condition-flag timing warning');
require_text($doc,'## 11. Build layered oracles','HOWTO lost layered-oracle design');
require_text($doc,'Use Stella as the final authority for TIA-visible behavior',
   'HOWTO lost Stella physical-raster authority');
require_text($doc,'A static golden screenshot cannot prove smooth motion',
   'HOWTO lost physical-motion regression rule');
require_text($doc,'## 12. Regression design is part of the feature',
   'HOWTO lost regression integration rules');
require_text($doc,'## 13. Add a public example that exercises the new capability',
   'HOWTO lost public-example requirement');
require_text($doc,'## 14. Install the profile as part of the public library',
   'HOWTO lost install/installcheck requirement');
require_text($doc,'## 15. Completion checklist','HOWTO lost completion checklist');
require_text($doc,'If any item is still experimental, say so and leave the roadmap item open.',
   'HOWTO lost stop-ship rule for experimental renderers');

my $catalog=slurp(File::Spec->catfile($repo,qw(libraries vcs README.md)));
require_text($catalog,'`renderers/AUTHORING.md`',
   'public VCS catalog does not link the renderer-authoring HOWTO');

my $conversion=slurp(File::Spec->catfile($repo,qw(libraries vcs renderers COMPONENT_CONVERSION.md)));
require_text($conversion,'see `AUTHORING.md`',
   'component conversion baseline does not point renderer authors to the HOWTO');

print "renderer authoring HOWTO ok\n";
