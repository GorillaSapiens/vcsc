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

require_re($doc,qr/12 playfield rows \* 16 scanlines per row = 192 scanlines/,
   'component conversion document lost the 192-line composition constraint');
require_re($doc,qr/pointer_workspace.*mixed/is,
   'component conversion document incorrectly treats mixed pointer workspace as saved');
require_re($doc,qr/must not write `VSYNC`, `VBLANK`, or a RIOT timer/,
   'component frame-register ownership rule is missing');

print "vcs_kernel_component_baseline ok\n";
