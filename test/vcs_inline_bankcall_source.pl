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
my $src = File::Spec->catfile($repo, qw(libraries vcs inline_bankcall.s26));
my $generator = File::Spec->catfile($repo, qw(linker gen_inline_bankcall_template.pl));
my $built = File::Spec->catfile($repo, qw(linker generic_bankcall_template.h));
my $fresh = File::Spec->catfile($tmp, 'generic_bankcall_template.h');
my $ld = read_file(File::Spec->catfile($repo, qw(linker vcsc_ld.c)));
my $top = read_file(File::Spec->catfile($repo, 'Makefile'));
my $s26 = read_file($src);

-f $as or die "missing assembler $as\n";
-f $src or die "missing maintained trampoline source $src\n";
-f $generator or die "missing template generator $generator\n";
-f $built or die "missing generated linker template $built\n";

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
index($ld, 'vcsc_generic_bankcall_template') >= 0
   or die "linker does not consume generated trampoline template\n";
index($ld, '#define PUT(') < 0
   or die "linker still contains hand-emitted generic trampoline opcodes\n";
index($top, 'libraries/vcs/inline_bankcall.s26') >= 0
   or die "maintained trampoline source is not installed\n";

system($^X, $generator, $as, $src, $fresh) == 0
   or die "could not regenerate inline bank-call template\n";
read_file($fresh) eq read_file($built)
   or die "built generic bank-call template is stale relative to inline_bankcall.s26\n";

my $header = read_file($built);
$header =~ /VCSC_GENERIC_BANKCALL_TEMPLATE_SIZE 0x4Fu/
   or die "generic trampoline payload is no longer 79 bytes\n";
$header =~ /VCSC_GENERIC_BANKCALL_RESERVED_SIZE 0x50u/
   or die "generic trampoline reservation is no longer 80 bytes\n";

print "inline bank-call source template passed\n";
