#!/usr/bin/env perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 45
# expectstdout: inline bank-call source template passed
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

my $as = File::Spec->catfile($repo, qw(assembler vcsc-as));
my @generic_mapper_dirs = qw(F8 F8SC F6 F6SC F4 F4SC FA DPC);
my $src = File::Spec->catfile($repo, qw(libraries vcs F8 inline_bankcall.s26));
my $fa2_src = File::Spec->catfile($repo, qw(libraries vcs FA2 inline_bankcall.s26));
my $generator = File::Spec->catfile($repo, qw(linker gen_inline_bankcall_template.pl));
my $built = File::Spec->catfile($repo, qw(linker generic_bankcall_template.h));
my $fa2_built = File::Spec->catfile($repo, qw(linker fa2_bankcall_template.h));
my $fresh = File::Spec->catfile($tmp, 'generic_bankcall_template.h');
my $fa2_fresh = File::Spec->catfile($tmp, 'fa2_bankcall_template.h');
my $ld = read_file(File::Spec->catfile($repo, qw(linker vcsc_ld.c)));
my $top = read_file(File::Spec->catfile($repo, 'Makefile'));
my $s26 = read_file($src);
my $fa2_s26 = read_file($fa2_src);

-f $as or die "missing assembler $as\n";
-f $src or die "missing maintained trampoline source $src\n";
for my $mapper (@generic_mapper_dirs) {
   my $copy = File::Spec->catfile($repo, 'libraries', 'vcs', $mapper, 'inline_bankcall.s26');
   -f $copy or die "missing mapper-local trampoline source $copy\n";
   read_file($copy) eq read_file($src)
      or die "$mapper inline_bankcall.s26 drifted from the shared F8-geometry source\n";
}
-f $fa2_src or die "missing maintained FA2 trampoline source $fa2_src\n";
-f $generator or die "missing template generator $generator\n";
-f $built or die "missing generated linker template $built\n";
-f $fa2_built or die "missing generated FA2 linker template $fa2_built\n";

for my $label (qw(
   __vcsc_generic_bankcall_begin
   __vcsc_generic_bankreturn
   __vcsc_generic_bankcall_switch_and_jump
   __vcsc_generic_bankcall_end
)) {
   index($s26, $label) >= 0 or die "maintained trampoline source lacks $label\n";
}
index($s26, 'jsr __vcsc_generic_bankcall_switch_and_jump') >= 0
   or die "maintained trampoline source lacks internal JSR\n";
index($s26, 'sta VCSC_BANKCALL_SELECTOR_BASE,y') >= 0
   or die "maintained trampoline source lacks selector patch points\n";
index($fa2_s26, 'eor #7') >= 0 && index($fa2_s26, 'sta VCSC_BANKCALL_SELECTOR_BASE,y') >= 0
   or die "maintained FA2 trampoline source lacks reversed selector transform\n";
index($ld, 'vcsc_generic_bankcall_template') >= 0 && index($ld, 'vcsc_fa2_bankcall_template') >= 0
   or die "linker does not consume both generated trampoline templates\n";
index($ld, '#define PUT(') < 0
   or die "linker still contains hand-emitted generic trampoline opcodes\n";
(grep { index($top, "libraries/vcs/$_/inline_bankcall.s26") < 0 } @generic_mapper_dirs) == 0 &&
index($top, 'libraries/vcs/FA2/inline_bankcall.s26') >= 0
   or die "maintained trampoline sources are not installed\n";

system($^X, $generator, $as, $src, $fresh, 'GENERIC') == 0
   or die "could not regenerate inline bank-call template\n";
system($^X, $generator, $as, $fa2_src, $fa2_fresh, 'FA2') == 0
   or die "could not regenerate FA2 inline bank-call template\n";
read_file($fresh) eq read_file($built)
   or die "built generic bank-call template is stale relative to F8/inline_bankcall.s26\n";
read_file($fa2_fresh) eq read_file($fa2_built)
   or die "built FA2 bank-call template is stale relative to FA2/inline_bankcall.s26\n";

my $header = read_file($built);
$header =~ /VCSC_GENERIC_BANKCALL_TEMPLATE_SIZE 0x4Fu/
   or die "generic trampoline payload is no longer 79 bytes\n";
$header =~ /VCSC_GENERIC_BANKCALL_RESERVED_SIZE 0x50u/
   or die "generic trampoline reservation is no longer 80 bytes\n";
my $fa2_header = read_file($fa2_built);
$fa2_header =~ /VCSC_FA2_BANKCALL_TEMPLATE_SIZE 0x53u/
   or die "FA2 trampoline payload is no longer 83 bytes\n";
$fa2_header =~ /VCSC_FA2_BANKCALL_RESERVED_SIZE 0x54u/
   or die "FA2 trampoline reservation is no longer 84 bytes\n";

print "inline bank-call source template passed\n";
