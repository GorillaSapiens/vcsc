# runner: perl package_addons.pl
# phase: e2e
#!/usr/bin/env perl
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;

my $repo = shift @ARGV // File::Spec->catdir($Bin, '..');
my $makefile = File::Spec->catfile($repo, 'Makefile');
my $manifest = File::Spec->catfile($repo, qw(packaging install.manifest));

sub read_file {
   my ($path) = @_;
   open(my $fh, '<', $path) or die "could not open $path: $!\n";
   local $/;
   my $data = <$fh> // '';
   close($fh);
   return $data;
}

my $make = read_file($makefile);
my $manifest_data = read_file($manifest);

$manifest_data =~ /^package-common\ttree\t-\taddons\taddons$/m
   or die "package-common manifest does not include addons tree\n";
$make =~ /stage-release-payload:.*?--scope package-common --scope package-\$\(RELEASE_PLATFORM\)/s
   or die "shared release staging does not consume package-common manifest scope\n";
for my $platform (qw(windows linux)) {
   $make =~ /^\Q$platform\E:.*?\$\(MAKE\).*?stage-release-payload.*?RELEASE_PLATFORM=\Q$platform\E\b/sm
      or die "$platform packaging does not use shared manifest release staging\n";
}
$make =~ /stage-release-payload:.*?--scope libraries.*?--dest-root "\$\(RELEASE_STAGING\)\/\$\(RELEASE_PACKAGE_DIR\)"/s
   or die "shared release staging does not verify the package-root libraries tree\n";
for my $pair (
   ['windows', 'WINDOWS_PACKAGE_DIR'],
   ['linux', 'LINUX_PACKAGE_DIR'],
) {
   my ($platform, $var) = @$pair;
   my ($recipe) = $make =~ /^\Q$platform\E:\n(.*?)(?=^[A-Za-z0-9_.-]+:|\z)/ms;
   defined $recipe or die "could not isolate $platform package recipe\n";
   index($recipe, qq{PREFIX="/\$($var)"}) >= 0
      or die "$platform packaging does not install under its package root\n";
   index($recipe, qq{CFGDIR="/\$($var)/cfg"}) >= 0
      or die "$platform packaging does not use top-level cfg\n";
   $recipe !~ /(?:LIBDIR|INCLUDEDIR|DATADIR)=/
      or die "$platform packaging still manufactures lib/include/share install roots\n";
}
$make =~ /^package:.*?rm -rf \$\(PACKAGE_STAGING\).*?tar .*?\n\trm -rf \$\(PACKAGE_STAGING\)/sm
   or die "generic package target does not clean its staging tree\n";

for my $rel (qw(addons/README.md addons/c26.vim addons/s26.vim)) {
   -f File::Spec->catfile($repo, split('/', $rel))
      or die "required packaged addon is missing: $rel\n";
}

print "package addons tests passed\n";
