#!/usr/bin/perl
# runner: perl @FILE@ @REPO@
# phase: e2e
# expectstdout: version header generation ok
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path getcwd);
use File::Spec;
use File::Temp qw(tempdir);

my $repo = abs_path($ARGV[0] // File::Spec->catdir(File::Spec->curdir(), '..'));
my $generator = File::Spec->catfile($repo, 'gen_version_h.pl');
-f $generator or die "missing $generator\n";

sub run {
   my (@cmd) = @_;
   system(@cmd) == 0 or die "command failed: @cmd\n";
}

sub slurp {
   my ($path) = @_;
   open(my $fh, '<', $path) or die "could not open $path: $!\n";
   local $/;
   my $text = <$fh>;
   close($fh);
   return $text;
}

sub write_file {
   my ($path, $text) = @_;
   open(my $fh, '>', $path) or die "could not write $path: $!\n";
   print $fh $text;
   close($fh);
}

sub append_file {
   my ($path, $text) = @_;
   open(my $fh, '>>', $path) or die "could not append $path: $!\n";
   print $fh $text;
   close($fh);
}

sub generate {
   my ($dir) = @_;
   my $old = getcwd();
   chdir($dir) or die "could not chdir $dir: $!\n";
   my $out = File::Spec->catfile($dir, 'version.h');
   run($^X, $generator, $out);
   chdir($old) or die "could not chdir $old: $!\n";
   return slurp($out);
}

my $tmp = tempdir(CLEANUP => 1);
my $gitdir = File::Spec->catdir($tmp, 'repo');
mkdir($gitdir) or die "could not mkdir $gitdir: $!\n";
my $old = getcwd();
chdir($gitdir) or die "could not chdir $gitdir: $!\n";
run('git', 'init', '-q', '-b', 'version-test');
run('git', 'config', 'user.name', 'VCSC Version Test');
run('git', 'config', 'user.email', 'vcsc-version-test\@invalid.example');
write_file('tracked.txt', "one\n");
run('git', 'add', 'tracked.txt');
{
   local $ENV{GIT_AUTHOR_DATE} = '2026-08-10T12:34:56Z';
   local $ENV{GIT_COMMITTER_DATE} = '2026-08-10T12:34:56Z';
   run('git', 'commit', '-q', '-m', 'first');
}
chdir($old) or die "could not chdir $old: $!\n";

my $branch = generate($gitdir);
$branch =~ /^#define VERSION "2026-08-10 12:34:56Z version-test [0-9a-f]{12} clean"\n$/
   or die "unexpected branch version: $branch";

chdir($gitdir) or die "could not chdir $gitdir: $!\n";
run('git', 'tag', '-a', 'release-alpha', '-m', 'release tag');
chdir($old) or die "could not chdir $old: $!\n";
my $tagged = generate($gitdir);
$tagged =~ /^#define VERSION "2026-08-10 12:34:56Z release-alpha [0-9a-f]{12} clean"\n$/
   or die "exact tag was not preferred: $tagged";

append_file(File::Spec->catfile($gitdir, 'tracked.txt'), "dirty\n");
my $dirty = generate($gitdir);
$dirty =~ /^#define VERSION "2026-08-10 12:34:56Z release-alpha [0-9a-f]{12} modified"\n$/
   or die "dirty tagged version wrong: $dirty";

chdir($gitdir) or die "could not chdir $gitdir: $!\n";
run('git', 'checkout', '-q', '--', 'tracked.txt');
write_file('tracked.txt', "two\n");
run('git', 'add', 'tracked.txt');
{
   local $ENV{GIT_AUTHOR_DATE} = '2026-08-10T13:00:00Z';
   local $ENV{GIT_COMMITTER_DATE} = '2026-08-10T13:00:00Z';
   run('git', 'commit', '-q', '-m', 'second');
}
run('git', 'checkout', '-q', '--detach', 'HEAD');
chdir($old) or die "could not chdir $old: $!\n";
my $detached = generate($gitdir);
$detached =~ /^#define VERSION "2026-08-10 13:00:00Z detached [0-9a-f]{12} clean"\n$/
   or die "unexpected detached version: $detached";

my $nogit = File::Spec->catdir($tmp, 'nogit');
mkdir($nogit) or die "could not mkdir $nogit: $!\n";
my $plain = generate($nogit);
$plain =~ /^#define VERSION "\d{4}-\d\d-\d\d \d\d:\d\d:\d\dZ nogit \S+ clean"\n$/
   or die "unexpected no-git version: $plain";
my $plain_again = generate($nogit);
$plain_again eq $plain
   or die "no-git version changed across an unchanged tree\nfirst: $plain second: $plain_again";

for my $component (qw(driver compiler assembler linker archiver simulator tagger disassembler)) {
   my $makefile = slurp(File::Spec->catfile($repo, $component, 'Makefile'));
   $makefile =~ /version\.h: FORCE\n\tperl \.\.\/gen_version_h\.pl \$\@\n/
      or die "$component/Makefile does not use top-level gen_version_h.pl\n";
   $makefile !~ /git branch --show-current/
      or die "$component/Makefile still contains duplicated Git version logic\n";
}

my $workflow = slurp(File::Spec->catfile($repo, '.github', 'workflows', 'build-packages.yml'));
$workflow =~ /fetch-depth:\s*0/
   or die "GitHub package workflow does not fetch tags/history\n";
$workflow =~ /mv -- "\$\{windows\[0\]\}" "vcsc\.windows\.\$\{GITHUB_REF_NAME\}\.zip"/
   or die "GitHub package workflow does not tag-name the Windows package\n";
$workflow =~ /mv -- "\$\{linux\[0\]\}" "vcsc\.linux\.\$\{GITHUB_REF_NAME\}\.tar\.gz"/
   or die "GitHub package workflow does not tag-name the Linux package\n";
$workflow =~ /name:\s*vcsc-windows-\$\{\{ github\.ref_type == 'tag' && github\.ref_name \|\| github\.sha \}\}/
   or die "GitHub Windows Actions artifact does not prefer the tag name\n";
$workflow =~ /name:\s*vcsc-linux-\$\{\{ github\.ref_type == 'tag' && github\.ref_name \|\| github\.sha \}\}/
   or die "GitHub Linux Actions artifact does not prefer the tag name\n";
$workflow =~ /"vcsc\.windows\.\$\{tag\}\.zip"/ &&
$workflow =~ /"vcsc\.linux\.\$\{tag\}\.tar\.gz"/
   or die "GitHub release upload does not use exact tag-named package assets\n";

print "version header generation ok\n";
