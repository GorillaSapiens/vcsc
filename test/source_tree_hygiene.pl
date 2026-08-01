#!/usr/bin/perl
# runner: perl @FILE@ @REPO@
# phase: e2e
# expectstdout: source tree hygiene ok
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use Digest::SHA qw(sha256_hex);
use File::Basename qw(basename dirname);
use File::Find;
use File::Spec;

my $repo=abs_path($ARGV[0] // File::Spec->catdir(File::Spec->curdir(),'..'));
my $test=File::Spec->catdir($repo,'test');
my $fixtures=File::Spec->catdir($repo,'assembler','tests');

# Core README placement and relative-link sanity.  These checks catch accidental
# file swaps such as copying test/README.md over the repository front page.
my %readme_heading=(
   'README.md' => '# VCSC Toolchain',
   'test/README.md' => '# Test harness notes',
   '.top_secret/README.md' => '# For Developer Eyes Only',
);
for my $rel (sort keys %readme_heading) {
   my $path=File::Spec->catfile($repo,split('/', $rel));
   my $body=slurp($path);
   index($body,$readme_heading{$rel})>=0
      or die "$rel has the wrong primary heading; expected $readme_heading{$rel}\n";
}
index(slurp(File::Spec->catfile($repo,'.top_secret','README.md')),'### `instruction.txt`')>=0
   or die ".top_secret/README.md does not document instruction.txt\n";
index(slurp(File::Spec->catfile($repo,'.top_secret','README.md')),'### `bankswitching.txt`')>=0
   or die ".top_secret/README.md does not document bankswitching.txt\n";
my $bankswitching=slurp(File::Spec->catfile($repo,'.top_secret','bankswitching.txt'));
index($bankswitching,'BANK0           $F000-$FFFF')>=0
   or die "bankswitching plan lost descending BANK0 logical origin\n";
index($bankswitching,'BANK0 is always the final 4K bank in the file')>=0
   or die "bankswitching plan lost lowest-address-first output order\n";
index($bankswitching,'[ ] 2. Add per-bank vectors and same-offset reset bridges.')>=0
   or die "bankswitching plan no longer schedules per-bank reset early\n";
index($bankswitching,'[ ] 11. Add Automatic allocation of variables into Superchip RAM.')>=0
   or die "bankswitching plan lost automatic Superchip allocation roadmap item\n";
index($bankswitching,q{beginning each bank's allocatable ROM at})>=0 &&
index($bankswitching,'$x100')>=0
   or die "bankswitching plan lost Superchip ROM-prefix reservation\n";

# The two complete drawscreen profiles remain installed intentionally.  They are
# legacy compatibility/regression targets, not preferred component APIs and not
# a deletion milestone in the active roadmap.
for my $rel (
   'libraries/vcs/renderers/standard_4k_ntsc/README.md',
   'libraries/vcs/renderers/standard_4k_ntsc_playercolors/README.md',
) {
   index(slurp(File::Spec->catfile($repo,split('/', $rel))),
         '> **Legacy monolithic profile.**')>=0
      or die "$rel does not identify the retained legacy monolithic profile\n";
}
my $vcs_catalog=slurp(File::Spec->catfile($repo,'libraries','vcs','README.md'));
$vcs_catalog =~ /standard_4k_ntsc\/.*legacy monolithic/s &&
$vcs_catalog =~ /standard_4k_ntsc_playercolors\/.*legacy monolithic/s
   or die "VCS catalog does not identify both retained legacy monolithic profiles\n";
my $component_guide=slurp(File::Spec->catfile(
   $repo,'libraries','vcs','renderers','COMPONENT_CONVERSION.md'));
index($component_guide,'Retirement of these working profiles is not a completion')>=0
   or die "component guide restored retirement as a roadmap gate\n";
my $context=slurp(File::Spec->catfile($repo,'.top_secret','context.txt'));
$context !~ /^\s*\[ \]\s+22i4d\./m
   or die "obsolete active roadmap item 22i4d was restored\n";
$context =~ /^Current next action: 23\b/m
   or die "roadmap next action is not task 23\n";
$context =~ /^\s*\[x\] 22i4b5\./m
   or die "two-plus-two score roadmap leaf is not complete\n";
$context =~ /^\s*\[x\] 22i4b6\./m
   or die "composition-matrix roadmap leaf is not complete\n";
$context =~ /^\s*\[x\] 22i4c1\./m
   or die "public composition-matrix roadmap leaf is not complete\n";
$context =~ /^\s*\[x\] 22i4\./m
   or die "visible-component roadmap gate is not complete\n";
$context =~ /^\[x\] 34\./m
   or die "animated-sprite roadmap item is not complete\n";
$context !~ /Task 22 remains the active roadmap family/
   or die "stale task-22 active-roadmap summary was restored\n";

my @markdown;
find(sub {
   return unless -f $_ && /\.md\z/;
   push @markdown,$File::Find::name;
},$repo);
my @broken_links;
for my $path (sort @markdown) {
   my $body=slurp($path);
   while ($body =~ /!?\[[^\]]*\]\(([^)]+)\)/g) {
      my $target=$1;
      $target =~ s/^<|>$//g;
      $target =~ s/\s+["'][^"']*["']\s*\z//;
      next if $target =~ m{^[A-Za-z][A-Za-z0-9+.-]*:};
      next if $target =~ /^#/;
      $target =~ s/#.*\z//;
      next if $target eq '';
      my $resolved=File::Spec->rel2abs($target,dirname($path));
      push @broken_links,File::Spec->abs2rel($path,$repo)." -> $target"
         unless -e $resolved;
   }
}
@broken_links and die "broken relative Markdown links:\n".join("\n",@broken_links)."\n";

sub slurp {
   my($path)=@_;
   open(my $fh,'<:raw',$path) or die "read $path: $!\n";
   local $/; my $data=<$fh>; close($fh);
   return defined($data)?$data:'';
}

opendir(my $tdh,$test) or die "open $test: $!\n";
my @test_files=sort map { File::Spec->catfile($test,$_) }
   grep { $_ ne '.' && $_ ne '..' && -f File::Spec->catfile($test,$_) }
   readdir($tdh);
closedir($tdh);
my %text=map { $_ => slurp($_) } @test_files;

# User-facing examples are smoke-tested separately. Exact regression drivers
# must consume private fixtures so changing a color, sprite, score, tune, or
# motion constant in examples/ cannot invalidate a golden harness.
my @example_coupling;
for my $path (@test_files) {
   next unless basename($path) =~ /\.(?:pl|cpp)\z/;
   next if basename($path) eq 'vcs_examples_build.pl';
   push @example_coupling,basename($path) if $text{$path} =~ /(?:^|[\\\/])examples[\\\/][^\n'"]+\.c26\b/;
}
@example_coupling and die "exact regression code references editable examples: @example_coupling\n";

sub referenced_elsewhere {
   my($path)=@_;
   my $name=basename($path);
   for my $other (@test_files) {
      next if $other eq $path;
      return 1 if index($text{$other},$name)>=0;
   }
   return 0;
}

sub leading_header {
   my($body)=@_;
   my @header;
   for my $line (split(/\n/,$body)) {
      if ($line =~ /^\s*\z/ || $line =~ /^\s*(?:(?:\/\/)|#|;)/) {
         push @header,$line;
         next;
      }
      last;
   }
   return join("\n",@header);
}

sub has_runner_header {
   my($body)=@_;
   my $header=leading_header($body);
   return $header =~ /^\s*(?:(?:\/\/)|#|;)\s*(?:runner:|vcsc-cc1\b|vcsc\b|vcsc-as\b|vcsc-ld\b|vcsc-ar\b|vcsc-sim\b|perl\b|make\b|stdbuf\b)/m;
}

my @redundant_perl_wrappers;
for my $path (@test_files) {
   my $name=basename($path);
   next if $name !~ /^(.*)\.test\z/;
   my $stem=$1;
   push @redundant_perl_wrappers,$name
      if $text{$path} =~ /^\s*#\s*runner:\s*perl\s+\S*\Q$stem\E\.pl\b/m;
}
@redundant_perl_wrappers and die "redundant .test wrappers around same-named Perl tests: @redundant_perl_wrappers\n";

my @dead;
for my $path (@test_files) {
   my $name=basename($path);
   if ($name =~ /\.c26\z/) {
      push @dead,$name if !has_runner_header($text{$path}) && !referenced_elsewhere($path);
   }
   elsif ($name =~ /\.pl\z/ && $name ne 'test.pl') {
      push @dead,$name if !has_runner_header($text{$path}) && !referenced_elsewhere($path);
   }
   elsif ($name =~ /\.(?:s26|cfg|hex|cpp)\z/) {
      push @dead,$name if !referenced_elsewhere($path);
   }
}
@dead and die "unreferenced test/support files: @dead\n";

my $fixture_driver=slurp(File::Spec->catfile($test,'assembler_fixture_suite.pl'));
opendir(my $fdh,$fixtures) or die "open $fixtures: $!\n";
my @fixture_files=sort map { File::Spec->catfile($fixtures,$_) }
   grep { /\.s26\z/ && -f File::Spec->catfile($fixtures,$_) }
   readdir($fdh);
closedir($fdh);
my @unused_fixtures=grep { index($fixture_driver,basename($_))<0 } @fixture_files;
@unused_fixtures and die "assembler fixtures absent from suite: ".join(' ',map {basename($_)} @unused_fixtures)."\n";

my %hashes;
for my $path (@test_files,@fixture_files) {
   next unless basename($path) =~ /\.(?:c26|test|pl|s26|cfg|hex|cpp)\z/;
   push @{$hashes{sha256_hex(slurp($path))}},$path;
}
my @duplicates;
for my $paths (values %hashes) {
   next if @$paths<2;
   push @duplicates,join(' == ',map {File::Spec->abs2rel($_,$repo)} @$paths);
}
@duplicates and die "byte-identical source/test files remain:\n".join("\n",sort @duplicates)."\n";

my $ledger=File::Spec->catfile($repo,'.top_secret','remove.txt');
my %seen;
my %generated_paths=('compiler/coverage_map.h'=>1);
my(@duplicate_ledger,@resurrected);
for my $line (split(/\n/,slurp($ledger))) {
   $line =~ s/^\s+|\s+$//g;
   next if $line eq '';
   push @duplicate_ledger,$line if $seen{$line}++;
   push @resurrected,$line if !$generated_paths{$line} && -e File::Spec->catfile($repo,split('/', $line));
}
@duplicate_ledger and die "duplicate remove.txt paths: @duplicate_ledger\n";
@resurrected and die "remove.txt paths have reappeared: @resurrected\n";

print "source tree hygiene ok\n";
