#!/usr/bin/perl

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Find;
use File::Spec;

my $repo = abs_path($ARGV[0] // File::Spec->catdir(File::Spec->curdir(), '..'));
my $banner = <<'BANNER';
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
BANNER
chomp $banner;

sub slurp {
   my ($path) = @_;
   open(my $fh, '<:raw', $path) or die "could not open $path: $!\n";
   local $/;
   my $data = <$fh>;
   close($fh);
   return $data;
}

for my $parts (
   [qw(driver vcsc.c)],
   [qw(compiler vcsc_cc1.c)],
   [qw(assembler vcsc_as.c)],
   [qw(archiver vcsc_ar.c)],
   [qw(linker vcsc_ld.c)],
   [qw(simulator main.cpp)],
   [qw(libraries runtime vcsc-runtime.inc)],
   [qw(libraries runtime vcsc-rt0.s)],
   [qw(libraries runtime vcsc-zeropage.s)],
   [qw(libraries runtime libvcsc.a65)],
   [qw(libraries vcs vcs.vcsc)],
   [qw(libraries vcs LEGACY_KERNEL_CONVERSION.md)],
   [qw(libraries vcs legacy-basic-kernels standard std_kernel.asm)],
   [qw(libraries vcs legacy-basic-kernels multisprite multisprite_kernel.asm)],
) {
   my $path = File::Spec->catfile($repo, @$parts);
   -f $path or die "required renamed/retained file is missing: $path\n";
}

for my $parts (
   [qw(driver n65cc.c)],
   [qw(compiler n65c.c)],
   [qw(assembler n65asm.c)],
   [qw(archiver n65ar.c)],
   [qw(linker n65ld.c)],
   [qw(libraries nlib)],
) {
   my $path = File::Spec->catfile($repo, @$parts);
   !-e $path or die "obsolete branded path remains: $path\n";
}

my (@old_suffix, @old_branding, @unneeded_upstream_name);
my $upstream_name = join('', qw(ba ta ri));
find({
   no_chdir => 1,
   wanted => sub {
      return if -d $_;
      my $path = $File::Find::name;
      my $rel = File::Spec->abs2rel($path, $repo);
      push @old_suffix, $rel if $rel =~ /\.n$/;
      return if $rel eq 'test/vcsc_branding.pl';
      push @unneeded_upstream_name, $rel if $rel =~ /\Q$upstream_name\E/i;
      return if $rel eq 'COPYING' || $rel eq 'LICENSE' || $rel =~ m{(?:^|/)LICENSE(?:\.txt)?$};
      return if $rel !~ /(?:Makefile|\.(?:c|h|cpp|l|y|pl|md|txt|dox|vcsc|s|asm|inc|cfg))$/;
      my $data = slurp($path);
      push @unneeded_upstream_name, $rel if $data =~ /\Q$upstream_name\E/i;
      return if $rel eq 'context.txt' || $rel eq 'remove.txt';
      push @old_branding, $rel if $data =~ /(?:n65|libraries\/nlib|\bnlib\.(?:a65|inc)\b|\/opt\/n(?:\/|\b))/;
   },
}, $repo);
@old_suffix and die "obsolete .n source files remain: @old_suffix\n";
@old_branding and die "obsolete N/n65/nlib branding remains in current files: @old_branding\n";
@unneeded_upstream_name and die "unneeded upstream project name remains outside its license file: @unneeded_upstream_name\n";

my @markdown;
find({
   no_chdir => 1,
   wanted => sub {
      push @markdown, $File::Find::name if -f $_ && $_ =~ /\.md$/;
   },
}, $repo);
for my $path (@markdown) {
   my $data = slurp($path);
   my $prefix = "```text\n$banner\n```\n\n";
   index($data, $prefix) == 0 or die "documentation lacks VCSC FIGlet banner: $path\n";
}
for my $rel ('compiler/ABI.txt', 'context.txt', 'software_stack_inventory.txt',
             'libraries/vcs/legacy-basic-kernels/OMITTED-UPSTREAM-ARTIFACTS.txt') {
   my $path = File::Spec->catfile($repo, split('/', $rel));
   my $data = slurp($path);
   index($data, "$banner\n\n") == 0 or die "text documentation lacks VCSC FIGlet banner: $path\n";
}
for my $rel ('docs/mainpage.dox', 'docs/tool_usage.dox') {
   my $path = File::Spec->catfile($repo, split('/', $rel));
   my $data = slurp($path);
   my $dox = "//! \@verbatim\n" . join('', map { "//! $_\n" } split(/\n/, $banner)) . "//! \@endverbatim\n//!\n";
   index($data, $dox) == 0 or die "Doxygen page lacks VCSC FIGlet banner: $path\n";
}

my $archive = File::Spec->catfile($repo, qw(libraries runtime libvcsc.a65));
open(my $afh, '<:raw', $archive) or die "could not open $archive: $!\n";
read($afh, my $magic, 7) == 7 or die "could not read archive magic\n";
close($afh);
$magic eq "VCSCAR\x01" or die "archive uses wrong magic\n";

print "VCSC hard rename and documentation branding ok\n";
