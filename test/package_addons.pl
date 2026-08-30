# runner: perl package_addons.pl
# phase: e2e
#!/usr/bin/env perl
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;

my $repo = shift @ARGV // File::Spec->catdir($Bin, '..');
my $makefile = File::Spec->catfile($repo, 'Makefile');
open(my $fh, '<', $makefile) or die "could not open $makefile: $!\n";
local $/;
my $data = <$fh>;
close($fh);

for my $line (
   'cp -a addons $(WINDOWS_STAGING)/$(WINDOWS_PACKAGE_DIR)/addons',
   'cp -a addons $(LINUX_STAGING)/$(LINUX_PACKAGE_DIR)/addons',
) {
   index($data, $line) >= 0 or die "binary packaging does not include addons: $line\n";
}

for my $rel (qw(addons/README.md addons/c26.vim addons/s26.vim)) {
   -f File::Spec->catfile($repo, split('/', $rel))
      or die "required packaged addon is missing: $rel\n";
}

print "package addons tests passed\n";
