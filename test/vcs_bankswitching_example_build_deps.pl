#!/usr/bin/env perl
# runner: perl @FILE@ @REPO@
# phase: compile
# expectstdout: bankswitching example build dependencies passed
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Spec;

my $repo=abs_path(shift @ARGV // die "usage: $0 REPO\n");
die "usage: $0 REPO\n" if @ARGV;

sub slurp {
   my($path)=@_;
   open(my $fh,'<:raw',$path) or die "read $path: $!\n";
   local $/;
   my $text=<$fh> // '';
   close($fh);
   return $text;
}

my %mapper_for=(
   '3e'     => '3E',
   '3e_max' => '3E',
   'e0'     => 'E0',
   'f0'     => 'F0',
   'fe'     => 'FE',
   '3f'     => '3F',
   '3f_max' => '3F',
);

for my $dir (sort keys %mapper_for) {
   my $mapper=$mapper_for{$dir};
   my $path=File::Spec->catfile($repo,qw(examples 07_diagnostics bankswitching),$dir,'Makefile');
   my $mk=slurp($path);
   $mk =~ /^VCSC_BUILD_DEPS\s*:=.*?libraries\/runtime\/libvcsc\.l26.*?wildcard \$\(VCS_DIR\)\/\Q$mapper\E\/\*\.c26 \$\(VCS_DIR\)\/\Q$mapper\E\/\*\.s26\)/ms
      or die "$dir Makefile does not track runtime and $mapper mapper inputs\n";
   $mk =~ /^\$\(TARGET\):[^\n]*\$\(VCSC_BUILD_DEPS\)/m
      or die "$dir target does not depend on VCSC_BUILD_DEPS\n";
   $mk =~ /^play:\s*\$\(TARGET\)\s*$/m
      or die "$dir play target no longer rebuilds TARGET before launch\n";
}


for my $dir (qw(3e_max 3f_max)) {
   my $path=File::Spec->catfile($repo,qw(examples 07_diagnostics bankswitching),$dir,'Makefile');
   my $mk=slurp($path);
   $mk =~ /^STELLA_SPEED\s*\?=\s*1000\s*$/m
      or die "$dir make play no longer defaults to 10x Stella speed\n";
   $mk =~ /^\t\$\(STELLA\) -dev\.tv\.jitter 0 -basedir "\$\(CURDIR\)" -speed \$\(STELLA_SPEED\).*?\$\(CURDIR\)\/\$\(TARGET\)/m
      or die "$dir make play no longer passes the configured Stella speed\n";
}

my $xdir='3ex_max';
my $xpath=File::Spec->catfile($repo,qw(examples 07_diagnostics bankswitching),$xdir,'Makefile');
my $x=slurp($xpath);
$x =~ /^VCSC_COMPILE_DEPS\s*:=.*?wildcard \$\(VCS_DIR\)\/3EX\/\*\.c26 \$\(VCS_DIR\)\/3EX\/\*\.s26\)/ms
   or die "3ex_max compile dependencies do not track 3EX mapper inputs\n";
$x =~ /^VCSC_LINK_DEPS\s*:=.*?linker\/vcsc-ld.*?libraries\/runtime\/libvcsc\.l26/m
   or die "3ex_max link dependencies do not track linker/runtime inputs\n";
$x =~ /^\$\(TARGET\):[^\n]*\$\(VCSC_LINK_DEPS\)/m
   or die "3ex_max target does not depend on VCSC_LINK_DEPS\n";
$x =~ /^\$\(BUILD_DIR\)\/%\.o26:\s*%\.c26\s+\$\(VCSC_COMPILE_DEPS\)/m
   or die "3ex_max C objects do not depend on VCSC_COMPILE_DEPS\n";
$x =~ /^\$\(BUILD_DIR\)\/%\.o26:\s*%\.s26\s+\$\(VCSC_COMPILE_DEPS\)/m
   or die "3ex_max assembly objects do not depend on VCSC_COMPILE_DEPS\n";
$x =~ /^play:\s*\$\(TARGET\)\s*$/m
   or die "3ex_max play target no longer rebuilds TARGET before launch\n";
$x =~ /^STELLA_SPEED\s*\?=\s*1000\s*$/m
   or die "3ex_max make play no longer defaults to 10x Stella speed\n";
$x =~ /^\t\$\(STELLA\) -dev\.tv\.jitter 0 -basedir "\$\(CURDIR\)" -speed \$\(STELLA_SPEED\).*?\$\(CURDIR\)\/\$\(TARGET\)/m
   or die "3ex_max make play no longer passes the configured Stella speed\n";

print "bankswitching example build dependencies passed\n";
