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
my @python_test_helpers=glob(File::Spec->catfile($test,'*.py'));
@python_test_helpers and die "Python test helpers are not permitted: @python_test_helpers\n";

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
index($bankswitching,'BANK0                $F000-$FFFF')>=0
   or die "bankswitching plan lost descending BANK0 logical origin\n";
index($bankswitching,'VCSC BANK0 is always the final 4K chunk in the file')>=0
   or die "bankswitching plan lost lowest-address-first output order\n";
index($bankswitching,'[x] 2. Extend the cfg parser and linker image model for multiple full 4K banks.')>=0
   or die "bankswitching plan no longer records the completed multi-bank image foundation\n";
index($bankswitching,'[x] 3. Add per-bank vectors and same-offset reset bridges.')>=0
   or die "bankswitching plan no longer records completed per-bank reset bridges\n";
index($bankswitching,'[x] 10. Make archive selection, listings, map output, simulator execution,')>=0 &&
index($bankswitching,'Stella is the authoritative end-to-end execution environment')>=0 &&
$bankswitching =~ /every possible ordered source-bank\s+to destination-bank transition/ &&
$bankswitching =~ /one cartridge\s+per mapper rather than one cartridge per transition/ &&
$bankswitching =~ /stable final green-background\/white-P or dark-red-\s*background\/white-F frame/ &&
$bankswitching =~ /exact default ASCII\s+glyphs/ &&
$bankswitching =~ /ordinary indexed syntax which must remain\s+absolute for relocatable ROM/ &&
$bankswitching =~ /deliberately poisoned F8 image/ &&
$bankswitching =~ /exactly 262 scanlines/ &&
$bankswitching =~ /proving read-window\/write-window\s+direction/
   or die "bankswitching plan lost completed Stella bank diagnostics or future Superchip extension\n";
-f File::Spec->catfile($test,'assembler_relocatable_zp_relaxation.pl') &&
-f File::Spec->catfile($test,'linker_banked_archive_reporting.pl') &&
-f File::Spec->catfile($test,'vcs_bankswitching_diagnostic.pl') &&
-f File::Spec->catfile($test,'vcs_bankswitching_example_make.pl') &&
-f File::Spec->catfile($test,'stella_snapshot_keys.pl') &&
-f File::Spec->catfile($test,'stella_grade_bank_snapshot.pl') &&
!-e File::Spec->catfile($test,'stella_snapshot_keys.py') &&
!-e File::Spec->catfile($test,'stella_grade_bank_snapshot.py') &&
-f File::Spec->catfile($repo,'libraries','vcs','bankswitching_diagnostic_suite.c26') &&
-f File::Spec->catfile($repo,'examples','09_bankswitching','01_diagnostic','bankswitching_diagnostic.c26')
   or die "bank-aware archive/simulator/Stella diagnostics are incomplete\n";
my $top_make=slurp(File::Spec->catfile($repo,'Makefile'));
index($top_make,'stella-bank-test: tools')>=0 &&
index($top_make,'--stella')>=0 &&
index($top_make,'install -m 0644 libraries/vcs/bankswitching_diagnostic_suite.c26')>=0 &&
index($top_make,'rm -f $(DESTDIR)$(DATADIR)/vcs/bankswitching_diagnostic_suite.c26')>=0 &&
index($top_make,'--stop-pc=0x$$sim_done')>=0
   or die "top-level installed simulator/Stella bank diagnostics are incomplete\n";
my $sim_readme=slurp(File::Spec->catfile($repo,'simulator','README.md'));
index($sim_readme,'--start-bank=N')>=0 &&
index($sim_readme,'mapper=F8')>=0 &&
index($sim_readme,'Stella remains the independent authority')>=0 &&
index($sim_readme,'The region name, window order,')>=0
   or die "simulator documentation lost banked cfg/file-index semantics\n";
index($bankswitching,'[x] 12. Add Automatic allocation of variables into Superchip RAM.')>=0
   or die "bankswitching plan no longer records completed automatic Superchip allocation\n";
index($bankswitching,'mem superchip {')>=0 &&
index($bankswitching,'$read_start:  0xF080')>=0 &&
index($bankswitching,'$write_start: 0xF000')>=0 &&
index($bankswitching,'uint8_t foo@[0xF080/0xF000];')>=0 &&
index($bankswitching,'superchip uint8_t buffer[32];')>=0
   or die "bankswitching plan lost exact Superchip read/write allocation syntax\n";
-f File::Spec->catfile($test,'superchip_allocation.pl') &&
-f File::Spec->catfile($test,'superchip_locals.pl') &&
-f File::Spec->catfile($test,'superchip_static_locals.pl') &&
-f File::Spec->catfile($test,'split_memory_generic_regions.pl') &&
-f File::Spec->catfile($test,'superchip_parameters.pl') &&
-f File::Spec->catfile($test,'split_memory_value_parameters.pl') &&
-f File::Spec->catfile($test,'superchip_function_returns.pl') &&
-f File::Spec->catfile($test,'split_memory_function_returns.pl') &&
-f File::Spec->catfile($test,'absolute_binding_global_compile_test.c26') &&
-f File::Spec->catfile($test,'absolute_binding_local_compile_test.c26') &&
-f File::Spec->catfile($test,'absolute_binding_array_codegen_test.c26') &&
-f File::Spec->catfile($test,'e2e_absolute_binding_abi_mismatch_fail.c26') &&
-f File::Spec->catfile($test,'ref_object_absolute_binding_error_test.c26') &&
-f File::Spec->catfile($test,'split_memory_return_codegen_test.c26') &&
-f File::Spec->catfile($test,'split_memory_return_void_error_test.c26') &&
-f File::Spec->catfile($test,'split_memory_return_region_conflict_error_test.c26') &&
-f File::Spec->catfile($test,'split_memory_parameter_region_conflict_error_test.c26') &&
-f File::Spec->catfile($test,'linker_startup_main_generic.pl') &&
-f File::Spec->catfile($test,'split_memory_allocation_codegen_test.c26') &&
-f File::Spec->catfile($test,'split_memory_local_codegen_test.c26') &&
-f File::Spec->catfile($test,'split_memory_bitfield_write_codegen_test.c26') &&
-f File::Spec->catfile($test,'split_memory_static_local_codegen_test.c26') &&
	!-e File::Spec->catfile($test,'split_memory_static_local_error_test.c26') &&
!-e File::Spec->catfile($test,'split_memory_local_error_test.c26') &&
!-e File::Spec->catfile($test,'split_memory_bitfield_write_error_test.c26') &&
index(slurp(File::Spec->catfile($repo,'libraries','vcs','superchip.c26')),
      'mem superchip { $read_start:0xF080 $write_start:0xF000 $size:0x0080 $rw };')>=0
   or die "automatic Superchip allocation implementation or regression coverage is missing\n";
for my $cfg_name (qw(vcs_8k_f8sc.cfg vcs_16k_f6sc.cfg vcs_32k_f4sc.cfg)) {
   my $cfg_body=slurp(File::Spec->catfile($repo,'libraries','vcs',$cfg_name));
   $cfg_body =~ /superchip:\s+read_start\s*=\s*\$F080,\s*write_start\s*=\s*\$F000,\s*size\s*=\s*\$0080,\s*type\s*=\s*rw/
      or die "$cfg_name lost the shared split-address Superchip MEMORY region\n";
}
index($bankswitching,'[x] 13. Add Superchip-backed local variables.')>=0 &&
index($bankswitching,'[x] 14. Add Superchip-backed value parameters.')>=0 &&
index($bankswitching,'[x] 15. Add Superchip-backed function return storage.')>=0 &&
index($bankswitching,'[ ] 21. Add explicit multi-bank duplication for immutable objects and functions.')>=0 &&
index($bankswitching,'bank0 bank1 const uint8_t table[] := { ... };')>=0 &&
index($bankswitching,'Combining `inline` with any named bank/memory-region specification')>=0
   or die "bankswitching plan lost completed Superchip locals or future bank duplication rules\n";
index($bankswitching,'[x] 5. Add the byte-identical common trampoline table and cross-bank JMP.')>=0 &&
index($bankswitching,'STA  destination_hotspot')>=0 &&
index($bankswitching,'JMP  (BANK0-mirror address of inline_target)')>=0 &&
index($bankswitching,'target word never begins at page offset $FF')>=0
   or die "bankswitching plan lost the completed inline-target JMP trampoline design\n";
index($bankswitching,'[x] 6. Add JSR-to-indirect-JMP cross-bank calls and return stubs.')>=0 &&
index($bankswitching,'JSR  body')>=0 &&
index($bankswitching,'STA  source_hotspot')>=0 &&
index($bankswitching,'__call_stack_weighted_depth')>=0
   or die "bankswitching plan lost the completed cross-bank JSR return path\n";
index($bankswitching,'[x] 7. Add placement constraints and deterministic automatic bank placement.')>=0 &&
index($bankswitching,'Pinned components are assigned first in stable input order')>=0 &&
$bankswitching =~ /15 for JSR and 8 for\s+JMP/ &&
index($bankswitching,'RODATA.bank1.__vcsc_object$level_table')>=0
   or die "bankswitching plan lost completed deterministic automatic placement\n";
-f File::Spec->catfile($test,'linker_banked_auto_placement.pl')
   or die "automatic bank-placement regression test is missing\n";
index($bankswitching,'[x] 8. Add and certify `vcs_8k_f8.cfg`.')>=0
   or die "bankswitching plan no longer records the certified F8 profile\n";
-f File::Spec->catfile($repo,'libraries','vcs','vcs_8k_f8.cfg') &&
-f File::Spec->catfile($test,'vcs_f8_profile.pl') &&
-f File::Spec->catfile($test,'fixtures','bankswitching','f8_profile_diagnostic.c26')
   or die "certified F8 profile or its diagnostics are missing\n";
index($bankswitching,'[x] 9. Add F6 and F4 through the same implementation.')>=0
   or die "bankswitching plan no longer records certified F6/F4 profiles\n";
-f File::Spec->catfile($repo,'libraries','vcs','vcs_16k_f6.cfg') &&
-f File::Spec->catfile($repo,'libraries','vcs','vcs_32k_f4.cfg') &&
-f File::Spec->catfile($test,'vcs_f6_f4_profiles.pl')
   or die "certified F6/F4 profiles or their regression test are missing\n";
$bankswitching =~ /linker pins its private layout to the unique BANKS entry marked `startup=yes`/ &&
$bankswitching =~ /The compiler does not interpret names such\s+as `bank0`/ &&
$bankswitching =~ /Unpinned\s+components are considered by decreasing byte size/
   or die "bankswitching plan lost generic startup-main or constrained automatic placement\n";
index($bankswitching,q{beginning each bank's allocatable ROM at})>=0 &&
index($bankswitching,'$x100')>=0
   or die "bankswitching plan lost Superchip ROM-prefix reservation\n";
index($bankswitching,'bank1 void some_function(void)')>=0 &&
index($bankswitching,'$start:0xD100 $size:0x0E00')>=0
   or die "bankswitching plan lost named function-region syntax or correct Superchip ROM span\n";
index($bankswitching,'Every selector hotspot is reserved at the same low twelve-bit offset')>=0 &&
index($bankswitching,'hotspot bytes may not become code or ordinary ROM data')>=0
   or die "bankswitching plan lost per-bank hotspot reservation\n";
index($bankswitching,'CARTRIDGE trampoline')>=0 &&
index($bankswitching,'trampolinesize')>=0 &&
index($bankswitching,'CARTRIDGE vectorbridge')>=0 &&
index($bankswitching,'BIT BANK0_HOTSPOT; JMP __reset')>=0 &&
index($bankswitching,q{F4's $1FFA and $1FFB selector})>=0
   or die "bankswitching plan lost implemented vector bridge design\n";
index($bankswitching,'Three bank identities must be kept separate')>=0 &&
index($bankswitching,'F8      0           BANK1')>=0 &&
index($bankswitching,'1           BANK0      $F000-$FFFF   $1FF9')>=0 &&
index($bankswitching,'F4      0           BANK7')>=0 &&
index($bankswitching,'7           BANK0      $F000-$FFFF   $1FFB')>=0 &&
index($bankswitching,'file_index(BANKn) = bank_count - 1 - n')>=0
   or die "bankswitching plan lost logical/file/hotspot identity tables\n";

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

for my $required (qw(
   libraries/vcs/superchip.c26
   libraries/vcs/vcs_8k_f8sc.cfg
   libraries/vcs/vcs_16k_f6sc.cfg
   libraries/vcs/vcs_32k_f4sc.cfg
)) {
   -f File::Spec->catfile($repo,split('/', $required))
      or die "missing required Superchip file $required\n";
}
my $superchip_header=slurp(File::Spec->catfile($repo,'libraries','vcs','superchip.c26'));
index($superchip_header,'superchip_ram[128]@[0xF080/0xF000]')>=0
   or die "superchip.c26 lost @[read/write] alias order\n";
index($bankswitching,'[x] 11. Add explicit-binding Superchip profiles.')>=0
   or die "explicit-binding Superchip roadmap item is not complete\n";
index($top_make,'libraries/vcs/vcs_8k_f8sc.cfg')>=0 &&
index($top_make,'libraries/vcs/superchip.c26')>=0
   or die "Superchip profiles/header are not installed and uninstalled\n";

print "source tree hygiene ok\n";
