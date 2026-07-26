#!/usr/bin/perl
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
sub require_re {
   my($text,$re,$why)=@_;
   $text =~ $re or die "$why\n";
}

my $repo=shift @ARGV // usage();
usage() if @ARGV;
$repo=abs_path($repo) // die "resolve repository root\n";
my $root=File::Spec->catdir($repo,qw(libraries vcs kernels));
my $doc=read_file(File::Spec->catfile($root,'COMPONENT_CONVERSION.md'));

my @profiles=(
   {
      dir => 'standard_4k_ntsc', prefix => 'vcs_standard', macro => 'VCS_STANDARD',
      public => 23, private => 57, total => 80, floor => 19,
      score => 'vcs_standard_score', color => 'vcs_standard_score_color',
      table => 'vcs_standard_score_table',
   },
   {
      dir => 'standard_4k_ntsc_playercolors', prefix => 'vcs_standard_color',
      macro => 'VCS_STANDARD_COLOR', public => 17, private => 60, total => 77,
      floor => 13, score => 'vcs_standard_color_score',
      color => 'vcs_standard_color_score_color',
      table => 'vcs_standard_color_score_table',
   },
);

for my $p (@profiles) {
   my $dir=File::Spec->catdir($root,$p->{dir});
   my $contract=read_file(File::Spec->catfile($dir,"$p->{dir}.c26"));
   my $kernel=read_file(File::Spec->catfile($dir,"$p->{dir}_kernel.s26"));
   require_re($contract,qr/alias\s+\Q$p->{macro}\E_APPLICATION_DISPLAY_RAM_BYTES\s+$p->{public}\b/,
      "$p->{dir}: public RAM baseline changed");
   require_re($contract,qr/alias\s+\Q$p->{macro}\E_PRIVATE_RAM_BYTES\s+$p->{private}\b/,
      "$p->{dir}: private RAM baseline changed");
   require_re($contract,qr/alias\s+\Q$p->{macro}\E_MODULE_RAM_BYTES\s+$p->{total}\b/,
      "$p->{dir}: total RAM baseline changed");
   require_re($contract,qr/alias\s+\Q$p->{macro}\E_SCORE_FONT_BYTES\s+88\b/,
      "$p->{dir}: score-font baseline changed");
   require_re($contract,qr/alias\s+\Q$p->{macro}\E_PLAYFIELD_ROWS\s+12\b/,
      "$p->{dir}: playfield row count changed");
   require_re($contract,qr/alias\s+\Q$p->{macro}\E_DEFAULT_ROW_SCANLINES\s+16\b/,
      "$p->{dir}: default row height changed");
   require_re($contract,qr/\bbcd24_t\s+\Q$p->{score}\E\s*;/,
      "$p->{dir}: predecessor packed score is no longer explicit");
   require_re($contract,qr/\buint8_t\s+\Q$p->{color}\E\s*;/,
      "$p->{dir}: predecessor score color is no longer explicit");
   require_re($kernel,qr/^\.importzp\s+\Q$p->{score}\E\s*$/m,
      "$p->{dir}: kernel no longer imports predecessor score");
   require_re($kernel,qr/^\.importzp\s+\Q$p->{color}\E\s*$/m,
      "$p->{dir}: kernel no longer imports predecessor score color");
   require_re($kernel,qr/^\.export\s+\Q$p->{table}\E\s*$/m,
      "$p->{dir}: embedded score table export changed");
   for my $register (qw(VSYNC VBLANK WSYNC TIM64T)) {
      require_re($kernel,qr/^\Q$register\E\s*=\s*\$/m,
         "$p->{dir}: predecessor frame-register ownership changed for $register");
   }
   require_re($doc,qr/\b\Q$p->{floor}\E bytes\b/,
      "$p->{dir}: score-free public-state floor is undocumented");
   require_re($doc,qr/\b\Q$p->{table}\E\b/,
      "$p->{dir}: forbidden score-table symbol is undocumented");
}

require_re($doc,qr/181 gameplay scanlines \+ 11 six-glyph scanlines = 192 visible scanlines/,
   'component conversion document lost the exact score-composable line contract');
require_re($doc,qr/\| score-composable \| 181 \|/,
   'component conversion document lost the official 181-line profile');
require_re($doc,qr/\| full-height scoreless \| 192 \|/,
   'component conversion document lost the official 192-line scoreless profile');
require_re($doc,qr/\| score-composable unofficial twin \| 181 \|/,
   'component conversion document lost the matched unofficial profile');
require_re($doc,qr/a zero or\s+negative saving is a valid result/,
   'component conversion document presumes unofficial-opcode savings');
require_re($doc,qr/twelve 16-line rows, or 192 lines/,
   'component conversion document lost the predecessor 192-line constraint');
require_re($doc,qr/pointer_workspace.*mixed/is,
   'component conversion document incorrectly treats mixed pointer workspace as saved');
require_re($doc,qr/must not write `VSYNC`, `VBLANK`, or a RIOT timer/,
   'component frame-register ownership rule is missing');
require_re($doc,qr/Blanking\s+callbacks may use WSYNC for bounded internal scheduling/,
   'component conversion document lost bounded blank-phase WSYNC use');
require_re($doc,qr/callbacks may use WSYNC.*Only the scheduler.*phase-transition WSYNC/si,
   'component conversion document does not distinguish scheduler ownership from internal WSYNC use');

my $unofficial=read_file(File::Spec->catfile($root,'standard_4k_ntsc','UNOFFICIAL_OPCODES.md'));
require_re($unofficial,qr/separately named unofficial-opcode\s+\*\*181-line gameplay component\*\*/s,
   'unofficial-opcode document lost the distinct 181-line experiment');
require_re($unofficial,qr/same lifecycle API.*same RAM.*same 181 scanlines/s,
   'unofficial-opcode comparison is not constrained to an apples-to-apples profile');
require_re($unofficial,qr/zero-byte result.*successful and\s+publishable outcome/si,
   'unofficial-opcode comparison incorrectly assumes a saving');
require_re($doc,qr/official linked ROM bytes:\s+1421.*unofficial linked ROM bytes:\s+1421.*signed saving:\s+0/s,
   'component conversion document lost the measured zero-byte result');
require_re($doc,qr/four `AXS #252` sites.*Three zero-page unofficial\s+NOPs/si,
   'component conversion document lost the repaired unofficial opcode set');
require_re($unofficial,qr/1421 linked ROM bytes for both components.*0 bytes saved/s,
   'unofficial-opcode history lost the measured result');

print "vcs_kernel_component_baseline ok\n";
