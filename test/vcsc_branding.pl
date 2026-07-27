#!/usr/bin/perl

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Find;
use File::Spec;
use File::Temp qw(tempdir);

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

sub write_raw {
   my ($path, $data) = @_;
   open(my $fh, '>:raw', $path) or die "could not write $path: $!\n";
   print {$fh} $data or die "could not write $path: $!\n";
   close($fh) or die "could not close $path: $!\n";
}

sub run_quiet {
   my ($stdout_path, $stderr_path, @cmd) = @_;
   my $pid = fork();
   defined($pid) or die "fork failed: $!\n";
   if ($pid == 0) {
      open(STDOUT, '>', $stdout_path) or exit 126;
      open(STDERR, '>', $stderr_path) or exit 126;
      exec @cmd;
      exit 127;
   }
   waitpid($pid, 0);
   return $? >> 8;
}

for my $parts (
   [qw(driver vcsc.c)],
   [qw(compiler vcsc_cc1.c)],
   [qw(assembler vcsc_as.c)],
   [qw(archiver vcsc_ar.c)],
   [qw(linker vcsc_ld.c)],
   [qw(simulator main.cpp)],
   [qw(libraries runtime vcsc-runtime.inc)],
   [qw(libraries runtime vcsc-rt0.s26)],
   [qw(libraries runtime vcsc-zp-arg0.s26)],
   [qw(libraries runtime vcsc-zp-arg1.s26)],
   [qw(libraries runtime vcsc-zp-ptr0.s26)],
   [qw(libraries runtime vcsc-zp-ptr1.s26)],
   [qw(libraries runtime vcsc-zp-ptr2.s26)],
   [qw(libraries runtime libvcsc.l26)],
   [qw(libraries vcs vcs.c26)],
   [qw(libraries vcs LEGACY_RENDERER_CONVERSION.md)],
   [qw(libraries vcs legacy-basic-renderers standard std_renderer.asm)],
   [qw(libraries vcs legacy-basic-renderers multisprite multisprite_renderer.asm)],
) {
   my $path = File::Spec->catfile($repo, @$parts);
   -f $path or die "required renamed/retained file is missing: $path\n";
}

for my $parts (
   [qw(libraries runtime vcsc-zeropage.s26)],
   [qw(libraries runtime vcsc-zp-ptr3.s26)],
   [qw(libraries runtime vcsc-zp-tmp0.s26)],
   [qw(libraries runtime vcsc-zp-tmp1.s26)],
   [qw(libraries runtime vcsc-zp-tmp2.s26)],
   [qw(libraries runtime vcsc-zp-tmp3.s26)],
   [qw(libraries runtime vcsc-zp-tmp4.s26)],
   [qw(libraries runtime vcsc-zp-tmp5.s26)],
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

my $top_secret = File::Spec->catdir($repo, '.top_secret');
opendir(my $top_secret_dh, $top_secret) or die "could not open $top_secret: $!\n";
my @top_secret_extra = sort grep {
   $_ ne '.' && $_ ne '..' && $_ ne 'README.md' && $_ ne 'context.txt' && $_ ne 'remove.txt' && $_ ne 'instruction.txt'
} readdir($top_secret_dh);
closedir($top_secret_dh);
@top_secret_extra and die "unexpected developer-only files remain: @top_secret_extra\n";

for my $parts (
   [qw(.top_secret README.md)],
   [qw(.top_secret context.txt)],
   [qw(.top_secret remove.txt)],
   [qw(.top_secret instruction.txt)],
) {
   my $path = File::Spec->catfile($repo, @$parts);
   -f $path or die "required developer-only record is missing: $path\n";
}

for my $parts (
   [qw(NOTES.md)],
   [qw(context.txt)],
   [qw(remove.txt)],
   [qw(software_stack_inventory.txt)],
   [qw(compiler parserparser.pl)],
   [qw(test unimpl_audit.pl)],
   [qw(test e2e_static_parameter_cycle_fail.c26)],
   [qw(test switch_range_compact_codegen_test.c26)],
   [qw(assembler tests obj2.s26)],
   [qw(libraries vcs renderers standard_4k_ntsc unofficial_opcodes.pl)],
   [qw(libraries vcs renderers standard_4k_ntsc standard_4k_ntsc_unofficial_opcodes.tsv)],
) {
   my $path = File::Spec->catfile($repo, @$parts);
   !-e $path or die "developer-only or obsolete root file remains: $path\n";
}

my (@old_suffix, @old_artifact_suffix, @old_branding, @unneeded_upstream_name);
my $upstream_name = join('', qw(ba ta ri));
my @obsolete_artifact_suffixes = (join('', qw(v c s c)), join('', qw(o 6 5)), join('', qw(a 6 5)));
find({
   no_chdir => 1,
   wanted => sub {
      return if -d $_;
      my $path = $File::Find::name;
      my $rel = File::Spec->abs2rel($path, $repo);
      push @old_suffix, $rel if $rel =~ /\.n$/;
      for my $suffix (@obsolete_artifact_suffixes) {
         push @old_artifact_suffix, $rel if $rel =~ /\.\Q$suffix\E$/;
      }
      return if $rel eq 'test/vcsc_branding.pl';
      push @unneeded_upstream_name, $rel if $rel =~ /\Q$upstream_name\E/i;
      return if $rel eq 'COPYING' || $rel eq 'LICENSE' || $rel =~ m{(?:^|/)LICENSE(?:\.txt)?$};
      return if $rel !~ /(?:Makefile|\.(?:c|h|cpp|l|y|pl|md|txt|dox|c26|s|asm|inc|cfg))$/;
      my $data = slurp($path);
      push @unneeded_upstream_name, $rel if $data =~ /\Q$upstream_name\E/i;
      return if $rel eq '.top_secret/context.txt' || $rel eq '.top_secret/remove.txt';
      push @old_branding, $rel if $data =~ /(?:n65|libraries\/nlib|\bnlib\.(?:l26|inc)\b|\/opt\/n(?:\/|\b))/;
   },
}, $repo);
@old_suffix and die "obsolete .n source files remain: @old_suffix\n";
@old_artifact_suffix and die "obsolete artifact suffixes remain: @old_artifact_suffix\n";
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
for my $rel ('compiler/ABI.txt', '.top_secret/context.txt',
             'libraries/vcs/legacy-basic-renderers/OMITTED-UPSTREAM-ARTIFACTS.txt') {
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

my $archive = File::Spec->catfile($repo, qw(libraries runtime libvcsc.l26));
open(my $afh, '<:raw', $archive) or die "could not open $archive: $!\n";
read($afh, my $magic, 7) == 7 or die "could not read archive magic\n";
$magic eq "VCSL26\x01" or die "archive uses wrong magic\n";
read($afh, my $member_header, 6) == 6 or die "could not read first archive member header\n";
my ($name_len, $member_size) = unpack('vV', $member_header);
$name_len > 0 or die "first archive member has an empty name\n";
$member_size >= 5 or die "first archive member is too short for o26 magic\n";
read($afh, my $member_name, $name_len) == $name_len or die "could not read first archive member name\n";
read($afh, my $object_magic, 5) == 5 or die "could not read first archive member object magic\n";
read($afh, my $object_tail, $member_size - 5) == $member_size - 5
   or die "could not read first archive member payload\n";
close($afh);
$member_name =~ /\.o26$/ or die "archive member does not use .o26: $member_name\n";
$object_magic eq "\x01\x00o26" or die "archive member uses wrong object magic\n";

my $tmp = tempdir(CLEANUP => 1);
my $linker = File::Spec->catfile($repo, qw(linker vcsc-ld));
my $cfg = File::Spec->catfile($repo, qw(test generic_6502.cfg));
my $bad_object = $object_magic . $object_tail;
substr($bad_object, 2, 3) = pack('C*', 111, 54, 53);
my $bad_object_path = File::Spec->catfile($tmp, 'wrong-magic.o26');
write_raw($bad_object_path, $bad_object);
my $bad_object_out = File::Spec->catfile($tmp, 'wrong-object.out');
my $bad_object_err = File::Spec->catfile($tmp, 'wrong-object.err');
run_quiet($bad_object_out, $bad_object_err,
   $linker, '-T', $cfg, '-o', File::Spec->catfile($tmp, 'wrong-object.hex'), $bad_object_path) != 0
   or die "linker accepted a pre-o26 object magic\n";
index(slurp($bad_object_err), 'not an o26 file') >= 0
   or die "linker gave the wrong diagnostic for a pre-o26 object magic\n";

my $bad_archive = slurp($archive);
substr($bad_archive, 0, 7) = pack('C*', 86, 67, 83, 67, 65, 82, 1);
my $bad_archive_path = File::Spec->catfile($tmp, 'wrong-magic.l26');
write_raw($bad_archive_path, $bad_archive);
my $bad_archive_out = File::Spec->catfile($tmp, 'wrong-archive.out');
my $bad_archive_err = File::Spec->catfile($tmp, 'wrong-archive.err');
run_quiet($bad_archive_out, $bad_archive_err,
   $linker, '-T', $cfg, '-o', File::Spec->catfile($tmp, 'wrong-archive.hex'), $bad_archive_path) != 0
   or die "linker accepted a pre-l26 archive magic\n";
index(slurp($bad_archive_err), 'not an l26 archive') >= 0
   or die "linker gave the wrong diagnostic for a pre-l26 archive magic\n";

print "VCSC hard rename and documentation branding ok\n";
