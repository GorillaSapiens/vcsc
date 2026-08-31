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
my $jane_src = File::Spec->catfile($repo, qw(libraries vcs JANE inline_bankcall.s26));
my $m0840_src = File::Spec->catfile($repo, qw(libraries vcs 0840 inline_bankcall.s26));
my $ua_src = File::Spec->catfile($repo, qw(libraries vcs UA inline_bankcall.s26));
my $uasw_src = File::Spec->catfile($repo, qw(libraries vcs UASW inline_bankcall.s26));
my $generator = File::Spec->catfile($repo, qw(linker gen_inline_bankcall_template.pl));
my $built = File::Spec->catfile($repo, qw(linker generic_bankcall_template.h));
my $fa2_built = File::Spec->catfile($repo, qw(linker fa2_bankcall_template.h));
my $jane_built = File::Spec->catfile($repo, qw(linker jane_bankcall_template.h));
my $m0840_built = File::Spec->catfile($repo, qw(linker m0840_bankcall_template.h));
my $ua_built = File::Spec->catfile($repo, qw(linker ua_bankcall_template.h));
my $uasw_built = File::Spec->catfile($repo, qw(linker uasw_bankcall_template.h));
my $fresh = File::Spec->catfile($tmp, 'generic_bankcall_template.h');
my $fa2_fresh = File::Spec->catfile($tmp, 'fa2_bankcall_template.h');
my $jane_fresh = File::Spec->catfile($tmp, 'jane_bankcall_template.h');
my $m0840_fresh = File::Spec->catfile($tmp, 'm0840_bankcall_template.h');
my $ua_fresh = File::Spec->catfile($tmp, 'ua_bankcall_template.h');
my $uasw_fresh = File::Spec->catfile($tmp, 'uasw_bankcall_template.h');
my $ld = read_file(File::Spec->catfile($repo, qw(linker vcsc_ld.c)));
my $top = read_file(File::Spec->catfile($repo, 'Makefile'));
my $s26 = read_file($src);
my $fa2_s26 = read_file($fa2_src);
my $jane_s26 = read_file($jane_src);
my $m0840_s26 = read_file($m0840_src);
my $ua_s26 = read_file($ua_src);
my $uasw_s26 = read_file($uasw_src);

-f $as or die "missing assembler $as\n";
-f $src or die "missing maintained trampoline source $src\n";
for my $mapper (@generic_mapper_dirs) {
   my $copy = File::Spec->catfile($repo, 'libraries', 'vcs', $mapper, 'inline_bankcall.s26');
   -f $copy or die "missing mapper-local trampoline source $copy\n";
   read_file($copy) eq read_file($src)
      or die "$mapper inline_bankcall.s26 drifted from the shared F8-geometry source\n";
}
-f $fa2_src or die "missing maintained FA2 trampoline source $fa2_src\n";
-f $jane_src or die "missing maintained JANE trampoline source $jane_src\n";
-f $m0840_src or die "missing maintained 0840 trampoline source $m0840_src\n";
-f $ua_src or die "missing maintained UA trampoline source $ua_src\n";
-f $uasw_src or die "missing maintained UASW trampoline source $uasw_src\n";
-f $generator or die "missing template generator $generator\n";
-f $built or die "missing generated linker template $built\n";
-f $fa2_built or die "missing generated FA2 linker template $fa2_built\n";
-f $jane_built or die "missing generated JANE linker template $jane_built\n";
-f $m0840_built or die "missing generated 0840 linker template $m0840_built\n";
-f $ua_built or die "missing generated UA linker template $ua_built\n";
-f $uasw_built or die "missing generated UASW linker template $uasw_built\n";

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
   or die "maintained FA2 trampoline source lacks reversed selector transform
";
index($jane_s26, 'eor #7') >= 0 && index($jane_s26, 'cmp #2') >= 0 &&
index($jane_s26, 'eor #1') < 0 && index($jane_s26, '__vcsc_generic_bankcall_reserved_end = $6060') >= 0
   or die "maintained JANE trampoline source lacks simplified 0/1/8/9 selector transform
";
index($m0840_s26, 'lda VCSC_BANKCALL_SELECTOR_BASE,y') >= 0 &&
index($m0840_s26, 'eor #$20') >= 0 && index($m0840_s26, 'and #$20') >= 0 &&
index($m0840_s26, '__vcsc_generic_bankcall_reserved_end = $6050') >= 0
   or die "maintained 0840 trampoline source lacks read-selector transform
";
index($ua_s26, 'lda VCSC_BANKCALL_SELECTOR_BASE,y') >= 0 &&
index($ua_s26, 'eor #$20') >= 0 && index($ua_s26, 'and #$20') >= 0 &&
index($ua_s26, '__vcsc_generic_bankcall_reserved_end = $6050') >= 0
   or die "maintained UA trampoline source lacks swapped-PC read-selector transform
";
index($uasw_s26, 'lda VCSC_BANKCALL_SELECTOR_BASE,y') >= 0 &&
index($uasw_s26, 'eor #$20') < 0 && index($uasw_s26, 'and #$20') >= 0 &&
index($uasw_s26, '__vcsc_generic_bankcall_reserved_end = $6050') >= 0
   or die "maintained UASW trampoline source lacks direct-PC read-selector transform
";
index($ld, 'vcsc_generic_bankcall_template') >= 0 && index($ld, 'vcsc_fa2_bankcall_template') >= 0 &&
index($ld, 'vcsc_jane_bankcall_template') >= 0 && index($ld, 'vcsc_m0840_bankcall_template') >= 0 &&
index($ld, 'vcsc_ua_bankcall_template') >= 0 && index($ld, 'vcsc_uasw_bankcall_template') >= 0
   or die "linker does not consume all generated trampoline templates
";
index($ld, '#define PUT(') < 0
   or die "linker still contains hand-emitted generic trampoline opcodes\n";
(grep { index($top, "libraries/vcs/$_/inline_bankcall.s26") < 0 } @generic_mapper_dirs) == 0 &&
index($top, 'libraries/vcs/FA2/inline_bankcall.s26') >= 0 &&
index($top, 'libraries/vcs/JANE/inline_bankcall.s26') >= 0 &&
index($top, 'libraries/vcs/0840/inline_bankcall.s26') >= 0 &&
index($top, 'libraries/vcs/UA/inline_bankcall.s26') >= 0 &&
index($top, 'libraries/vcs/UASW/inline_bankcall.s26') >= 0
   or die "maintained trampoline sources are not installed
";

system($^X, $generator, $as, $src, $fresh, 'GENERIC') == 0
   or die "could not regenerate inline bank-call template\n";
system($^X, $generator, $as, $fa2_src, $fa2_fresh, 'FA2') == 0
   or die "could not regenerate FA2 inline bank-call template
";
system($^X, $generator, $as, $jane_src, $jane_fresh, 'JANE') == 0
   or die "could not regenerate JANE inline bank-call template
";
system($^X, $generator, $as, $m0840_src, $m0840_fresh, 'M0840') == 0
   or die "could not regenerate 0840 inline bank-call template
";
system($^X, $generator, $as, $ua_src, $ua_fresh, 'UA') == 0
   or die "could not regenerate UA inline bank-call template
";
system($^X, $generator, $as, $uasw_src, $uasw_fresh, 'UASW') == 0
   or die "could not regenerate UASW inline bank-call template
";
read_file($fresh) eq read_file($built)
   or die "built generic bank-call template is stale relative to F8/inline_bankcall.s26\n";
read_file($fa2_fresh) eq read_file($fa2_built)
   or die "built FA2 bank-call template is stale relative to FA2/inline_bankcall.s26
";
read_file($jane_fresh) eq read_file($jane_built)
   or die "built JANE bank-call template is stale relative to JANE/inline_bankcall.s26
";
read_file($m0840_fresh) eq read_file($m0840_built)
   or die "built 0840 bank-call template is stale relative to 0840/inline_bankcall.s26
";
read_file($ua_fresh) eq read_file($ua_built)
   or die "built UA bank-call template is stale relative to UA/inline_bankcall.s26
";
read_file($uasw_fresh) eq read_file($uasw_built)
   or die "built UASW bank-call template is stale relative to UASW/inline_bankcall.s26
";

my $header = read_file($built);
$header =~ /VCSC_GENERIC_BANKCALL_TEMPLATE_SIZE 0x4Fu/
   or die "generic trampoline payload is no longer 79 bytes\n";
$header =~ /VCSC_GENERIC_BANKCALL_RESERVED_SIZE 0x50u/
   or die "generic trampoline reservation is no longer 80 bytes\n";
my $fa2_header = read_file($fa2_built);
$fa2_header =~ /VCSC_FA2_BANKCALL_TEMPLATE_SIZE 0x53u/
   or die "FA2 trampoline payload is no longer 83 bytes\n";
$fa2_header =~ /VCSC_FA2_BANKCALL_RESERVED_SIZE 0x54u/
   or die "FA2 trampoline reservation is no longer 84 bytes
";
my $jane_header = read_file($jane_built);
$jane_header =~ /VCSC_JANE_BANKCALL_TEMPLATE_SIZE 0x5Fu/
   or die "JANE trampoline payload is no longer 95 bytes
";
$jane_header =~ /VCSC_JANE_BANKCALL_RESERVED_SIZE 0x60u/
   or die "JANE trampoline reservation is no longer 96 bytes
";
my $m0840_header = read_file($m0840_built);
$m0840_header =~ /VCSC_M0840_BANKCALL_TEMPLATE_SIZE 0x4Bu/
   or die "0840 trampoline payload is no longer 75 bytes
";
$m0840_header =~ /VCSC_M0840_BANKCALL_RESERVED_SIZE 0x50u/
   or die "0840 trampoline reservation is no longer 80 bytes
";
my $ua_header = read_file($ua_built);
$ua_header =~ /VCSC_UA_BANKCALL_TEMPLATE_SIZE 0x49u/
   or die "UA trampoline payload is no longer 73 bytes
";
$ua_header =~ /VCSC_UA_BANKCALL_RESERVED_SIZE 0x50u/
   or die "UA trampoline reservation is no longer 80 bytes
";
my $uasw_header = read_file($uasw_built);
$uasw_header =~ /VCSC_UASW_BANKCALL_TEMPLATE_SIZE 0x45u/
   or die "UASW trampoline payload is no longer 69 bytes
";
$uasw_header =~ /VCSC_UASW_BANKCALL_RESERVED_SIZE 0x50u/
   or die "UASW trampoline reservation is no longer 80 bytes
";

print "inline bank-call source template passed\n";
