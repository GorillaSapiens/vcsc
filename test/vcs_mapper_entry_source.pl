#!/usr/bin/env perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 45
# expectstdout: mapper entry sources passed
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Spec;

sub read_file {
   my ($path) = @_;
   open my $fh, '<:raw', $path or die "read $path: $!\n";
   local $/;
   my $text = <$fh> // '';
   close $fh;
   return $text;
}

my $repo = abs_path(shift @ARGV // die "usage: $0 REPO TMP\n");
my $tmp = shift @ARGV // die "usage: $0 REPO TMP\n";
@ARGV and die "usage: $0 REPO TMP\n";

my %selector = (
   F8=>0x1ff9, F8SC=>0x1ff9, F6=>0x1ff9, F6SC=>0x1ff9,
   F4=>0x1ffb, F4SC=>0x1ffb, FA=>0x1ffa, DPC=>0x1ff9,
   FA2=>0x1ff5, JANE=>0x1ff1, '0840'=>0x0800, UA=>0x0220,
   UASW=>0x0240, '0FA0'=>0x0fc0, WD=>0x0039,
);
my @mapper = qw(F8 F8SC F6 F6SC F4 F4SC FA DPC FA2 JANE 0840 UA UASW 0FA0 WD 3F);
my $top = read_file(File::Spec->catfile($repo, 'Makefile'));
my @spec;
for my $mapper (@mapper) {
   my $src = File::Spec->catfile($repo, 'libraries', 'vcs', $mapper, 'entry.s26');
   -f $src or die "missing $mapper mapper entry source\n";
   my $text = read_file($src);
   if ($mapper eq '3F') {
      my $nop_count = () = $text =~ /^\s*nop\s*$/gmi;
      $nop_count == 3 && $text !~ /\bop0C\b/i && index($text, 'permanently visible') >= 0
         or die "3F entry must be the inert three-byte fixed-bank hook\n";
   }
   else {
      my $hex = sprintf('%04X', $selector{$mapper});
      $text =~ /\bop0C\s+\$$hex\b/i
         or die "$mapper entry does not use raw op0C on startup selector \$$hex\n";
      index($text, '--illegal') >= 0
         or die "$mapper entry does not explain why raw op0C avoids --illegal dependency\n";
   }
   index($top, "libraries/vcs/$mapper/entry.s26") >= 0
      or die "$mapper entry source is not installed\n";
   push @spec, (($mapper eq '0840' ? 'M0840' : $mapper eq '0FA0' ? 'M0FA0' : $mapper eq '3F' ? 'M3F' : $mapper) . "=$src");
}

my @old = glob(File::Spec->catfile($repo, 'libraries', 'vcs', '*', 'inline_bankcall.s26'));
@old == 0 or die "obsolete inline_bankcall.s26 source remains: @old\n";
for my $mapper (@mapper) {
   -f File::Spec->catfile($repo, 'libraries', 'vcs', $mapper, 'bankcall.s26')
      or die "missing renamed $mapper bankcall.s26\n";
   my @profiles = $mapper eq 'FA2'
      ? qw(mapper_24k.c26 mapper_28k.c26)
      : ('mapper.c26');
   for my $profile (@profiles) {
      my $profile_path = File::Spec->catfile($repo, 'libraries', 'vcs', $mapper, $profile);
      my $profile_text = read_file($profile_path);
      index($profile_text, '$bankcall') >= 0
         or die "$mapper/$profile does not opt into \$bankcall\n";
      index($profile_text, '$inline_bankcall') < 0
         or die "$mapper/$profile still uses obsolete \$inline_bankcall\n";
   }
}

my $as = File::Spec->catfile($repo, qw(assembler vcsc-as));
my $gen = File::Spec->catfile($repo, qw(linker gen_entry_templates.pl));
my $built = File::Spec->catfile($repo, qw(linker mapper_entry_templates.h));
my $fresh = File::Spec->catfile($tmp, 'mapper_entry_templates.h');
system($^X, $gen, $as, $fresh, @spec) == 0
   or die "could not regenerate mapper entry template header\n";
-f $built or die "missing generated linker mapper entry template header\n";
read_file($fresh) eq read_file($built)
   or die "built mapper entry template header is stale\n";

my $ld = read_file(File::Spec->catfile($repo, qw(linker vcsc_ld.c)));
index($ld, 'build_mapper_entry(cfg, startup, mapper_entry);') >= 0 &&
index($ld, 'memcpy(table + offset, entry, VCSC_MAPPER_ENTRY_SIZE);') >= 0 &&
index($ld, 'return 0x0Cu;') >= 0
   or die "linker does not consume mapper entry templates before vector handlers\n";

print "mapper entry sources passed\n";
