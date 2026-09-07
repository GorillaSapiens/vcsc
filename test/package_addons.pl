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

for my $rel (qw(addons/README.md addons/c26.vim addons/s26.vim)) {
   -f File::Spec->catfile($repo, split('/', $rel))
      or die "required packaged addon is missing: $rel\n";
}

print "package addons tests passed\n";
