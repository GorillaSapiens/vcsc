#!/usr/bin/perl
# runner: perl @FILE@ @REPO@
# phase: e2e
# expectstdout: vcs_renderer_component_baseline ok
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Spec;

sub usage { die "usage: $0 REPO_ROOT\n"; }
sub read_file {
   my($path)=@_;
   open(my $fh,'<:raw',$path) or die "read $path: $!\n";
   local $/; my $text=<$fh>;
   close($fh) or die "close $path: $!\n";
   return defined($text) ? $text : '';
}
sub require_re { my($text,$re,$why)=@_; $text =~ $re or die "$why\n"; }

my $repo=shift @ARGV // usage();
usage() if @ARGV;
$repo=abs_path($repo) // die "resolve repository root\n";
my $root=File::Spec->catdir($repo,qw(libraries vcs renderers));
my $doc=read_file(File::Spec->catfile($root,'COMPONENT_CONVERSION.md'));
my $all_five=read_file(File::Spec->catfile($root,qw(all_five all_five.c26)));

# S10 keeps the measured predecessor facts as migration history, not executable
# compatibility profiles.
require_re($doc,qr/Retired predecessor baseline/, 'component conversion document lost the retired baseline heading');
require_re($doc,qr/`standard_4k_ntsc`.*23 bytes.*57 bytes.*80 bytes.*88 bytes/s,
   'component conversion document lost the historical all-five predecessor measurements');
require_re($doc,qr/`standard_4k_ntsc_playercolors`.*17 bytes.*60 bytes.*77 bytes.*88 bytes/s,
   'component conversion document lost the historical player-color predecessor measurements');
require_re($doc,qr/neither profile\s+is installed or maintained after S10/s,
   'component conversion document does not close the S10 retirement gate');
for my $dir (qw(standard_4k_ntsc standard_4k_ntsc_playercolors)) {
   !-e File::Spec->catdir($root,$dir) or die "retired renderer directory still exists: $dir\n";
}

# The durable lifecycle/geometry law remains documented after deleting the old
# source trees.
require_re($doc,qr/181 gameplay scanlines \+ 11 score scanlines = 192 visible scanlines/,
   'component conversion document lost the exact score-composable line contract');
require_re($doc,qr/\| score-composable \| 181 \|/,
   'component conversion document lost the official 181-line profile');
require_re($doc,qr/\| full-height scoreless \| 192 \|/,
   'component conversion document lost the official 192-line scoreless profile');
require_re($doc,qr/twelve-byte `\*_pointer_workspace` was mixed/is,
   'component conversion document lost the historical mixed-workspace warning');
require_re($doc,qr/must not write `VSYNC`, `VBLANK`, or a RIOT timer/,
   'component frame-register ownership rule is missing');
require_re($doc,qr/Blanking\s+callbacks may use WSYNC for bounded internal scheduling/,
   'component conversion document lost bounded blank-phase WSYNC use');
require_re($doc,qr/callbacks may use WSYNC.*Only the scheduler.*phase-transition WSYNC/si,
   'component conversion document does not distinguish scheduler ownership from internal WSYNC use');
require_re($doc,qr/historical unofficial-opcode experiment.*retired.*S9/si,
   'component conversion document lost the retired unofficial-profile history');
require_re($doc,qr/official linked ROM bytes:\s+1794.*unofficial linked ROM bytes:\s+1794.*signed byte difference:\s+0/s,
   'component conversion document lost the historical matched-profile measurement');
require_re($doc,qr/retired profile used one reviewed.*zero-page unofficial NOP.*no AXS/si,
   'component conversion document lost the historical unofficial opcode set');
require_re($doc,qr/360 asynchronous motion frames.*X=0.*X=159.*RESP\/HMP/s,
   'component conversion document lost the S10 positioning-coverage closeout');
require_re($doc,qr/banked composition proving.*VBLANK.*startup bank/si,
   'component conversion document lost the S10 banked-composition closeout');

# The replacement is the parameterized all-five source, not another duplicate.
require_re($all_five,qr/parameter lines;/, 'all-five selector lost the lines parameter');
require_re($all_five,qr/parameter missiles := 1;/, 'all-five selector lost the missiles parameter');
require_re($all_five,qr/parameter player_colors := 0;/, 'all-five selector lost the player-colors parameter');
require_re($all_five,qr/#if TEMPLATE_lines == 228.*?#elif TEMPLATE_lines == 192.*?#elif TEMPLATE_lines == 181.*?#elif TEMPLATE_lines == 170/s,
   'all-five selector lost a maintained visible-line selection');
require_re($all_five,qr/TEMPLATE_VISIBLE_SCANLINES\s*:=\s*TEMPLATE_lines/,
   'all-five selector no longer publishes selected visible-line geometry');

print "vcs_renderer_component_baseline ok\n";
