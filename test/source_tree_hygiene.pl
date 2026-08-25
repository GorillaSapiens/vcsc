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

my $test_runner=slurp(File::Spec->catfile($test,'test.pl'));
$test_runner =~ /timeout\s*=>\s*45\s*,/
   or die "test runner default timeout is not 45 seconds\n";
my @short_timeout_headers;
find({no_chdir=>1,wanted=>sub {
   return unless -f $File::Find::name;
   my $rel=File::Spec->abs2rel($File::Find::name,$repo); $rel =~ s{\\}{/}g;
   my $body=slurp($File::Find::name);
   while ($body =~ /^\s*#\s*timeout:\s*(\d+)\s*$/mg) {
      push @short_timeout_headers,"$rel:$1" if $1 < 45;
   }
}},$test);
@short_timeout_headers and
   die "per-test timeout below 45 seconds remains: @short_timeout_headers\n";

my $retired_game_name='po'.'ng';
my @retired_game_name_hits;
find({no_chdir=>1,wanted=>sub {
   my $path=$File::Find::name;
   my $rel=File::Spec->abs2rel($path,$repo); $rel =~ s{\\}{/}g;
   # Git metadata may legitimately preserve historical names and content.  It
   # is not part of the editable source tree, so repository-wide hygiene
   # traversals must prune it completely.
   if ($rel eq '.git' || $rel =~ m{\A\.git/}) {
      $File::Find::prune=1 if -d $path;
      return;
   }
   if (index(lc($rel),$retired_game_name)>=0) {
      push @retired_game_name_hits,"path:$rel";
      return;
   }
   return unless -f $path;
   open(my $fh,'<:raw',$path) or die "read $path: $!\n";
   local $/; my $body=<$fh> // ''; close($fh);
   return if index($body,"\0")>=0;
   push @retired_game_name_hits,"text:$rel"
      if index(lc($body),$retired_game_name)>=0;
}},$repo);
@retired_game_name_hits and die "retired paddle-game name remains: @retired_game_name_hits\n";


# Everything under libraries/ and examples/ is cartridge-facing material.
# Libraries and ordinary examples use one root CC0 text and explicit per-file
# notices. The animated-sprite example is the one deliberate exception: its
# complete directory uses a local CC BY-NC-SA 4.0 license because its restored
# artwork is derived from Quick's PICO-8 Free 8x8 Sprites cartridge.
my $animated_rel=File::Spec->catdir(qw(examples 03_player_color_192 02_animated_sprites));
my $animated_root=File::Spec->catdir($repo,split('/', $animated_rel));
my $animated_license=File::Spec->catfile($animated_root,'LICENSE.txt');
my %animated_exception_docs=map { $_=>1 } (
   'examples/README.md',
   'examples/03_player_color_192/README.md',
);

for my $tree (qw(libraries examples)) {
   my $tree_root=File::Spec->catdir($repo,$tree);
   my $license=File::Spec->catfile($tree_root,'LICENSE.txt');
   -f $license or die "$tree/LICENSE.txt is missing\n";
   my $license_body=slurp($license);
   $license_body =~ /CC0 1\.0 Universal License\s*\n/ &&
   $license_body =~ /4\. Limitations and Disclaimers\./ &&
   $license_body =~ /use of the Work\.\s*\z/
      or die "$tree/LICENSE.txt is not the complete CC0-1.0 text\n";
   if ($tree eq 'examples') {
      $license_body =~ /03_player_color_192\/02_animated_sprites/ &&
      $license_body =~ /covered by its own `LICENSE\.txt` under CC BY-NC-SA 4\.0/
         or die "examples/LICENSE.txt does not scope the animated-sprite exception\n";
   }

   my @files;
   find({no_chdir=>1,wanted=>sub { push @files,$File::Find::name if -f $_ }},$tree_root);
   for my $path (sort @files) {
      next if $path eq $license;
      next if $tree eq 'examples' &&
         ($path eq $animated_license || index($path,$animated_root . '/')==0);
      my $rel=File::Spec->abs2rel($path,$repo);
      next if $rel =~ /(?:^|\/)(?:wrk)(?:\/|$)/;
      # Linker/Stella sidecars produced beside public example ROMs are build
      # products, not editable example sources.  In particular, ordinary example
      # builds leave a same-stem .cfg behind until `make clean`; hygiene must be
      # valid before or after that cleanup just as it is for .map/.sym/.lst.
      next if $rel =~ /\.(?:bin|hex|map|sym|lst|o26|l26)\z/;
      next if $tree eq 'examples' && $rel =~ /\.cfg\z/;
      basename($path) !~ /(?:license|copying|copyright)/i
         or die "subordinate license file remains under $tree: $rel\n";
      my $body=slurp($path);
      if ($body =~ /(?:BSD(?:-|\s)|GNU GENERAL PUBLIC LICENSE|\bGPL\b|CC BY(?:-|\b)|Attribution-NonCommercial|ShareAlike)/) {
         $tree eq 'examples' && $animated_exception_docs{$rel} &&
         ($body =~ /03_player_color_192\/02_animated_sprites/ ||
          ($rel eq 'examples/03_player_color_192/README.md' && $body =~ /02_animated_sprites/)) &&
         $body =~ /CC BY-NC-SA 4\.0/
            or die "contradictory license reference remains in $rel\n";
      }
      my $notice="This file is covered under CC0-1.0. See $tree/LICENSE.txt.";
      if ($rel =~ m{^libraries/vcs/fonts/[^/]+\.c26\z}) {
         $notice="This font is covered under CC0-1.0. See libraries/LICENSE.txt.";
      }
      index(substr($body,0,600),$notice)>=0
         or die "$rel lacks its explicit CC0 notice\n";
   }
}

-f $animated_license
   or die "$animated_rel/LICENSE.txt is missing\n";
my $animated_license_body=slurp($animated_license);
$animated_license_body =~ /explicit exception to `examples\/LICENSE\.txt`/ &&
$animated_license_body =~ /Creative Commons\s+Attribution-NonCommercial-ShareAlike 4\.0 International/ &&
$animated_license_body =~ /Free 8x8 Sprites/ &&
$animated_license_body =~ /Creator: Quick/ &&
$animated_license_body =~ m{https://www\.lexaloffle\.com/bbs/\?pid=42374}
   or die "animated-sprite local license or attribution is incomplete\n";
my @animated_files;
find({no_chdir=>1,wanted=>sub { push @animated_files,$File::Find::name if -f $_ }},$animated_root);
for my $path (sort @animated_files) {
   next if $path eq $animated_license;
   my $rel=File::Spec->abs2rel($path,$repo);
   next if $rel =~ /\.(?:bin|hex|map|sym|lst|o26|l26)\z/;
   basename($path) !~ /(?:license|copying|copyright)/i
      or die "unexpected second license file remains in animated example: $rel\n";
   my $body=slurp($path);
   my $notice='This example is covered under CC BY-NC-SA 4.0. See LICENSE.txt.';
   index(substr($body,0,600),$notice)>=0
      or die "$rel lacks its explicit local-license notice\n";
   $body !~ /(?:BSD(?:-|\s)|GNU GENERAL PUBLIC LICENSE|\bGPL\b)/
      or die "unrelated software license reference remains in $rel\n";
}

# Core README placement and relative-link sanity.  These checks catch accidental
# file swaps such as copying test/README.md over the repository front page.
my %readme_heading=(
   'README.md' => '# VCSC Toolchain',
   'test/README.md' => '# Test harness notes',
   '.../README.md' => '# For Developer Eyes Only',
);
for my $rel (sort keys %readme_heading) {
   my $path=File::Spec->catfile($repo,split('/', $rel));
   my $body=slurp($path);
   index($body,$readme_heading{$rel})>=0
      or die "$rel has the wrong primary heading; expected $readme_heading{$rel}\n";
}
index(slurp(File::Spec->catfile($repo,'...','README.md')),'### `instruction.txt`')>=0
   or die ".../README.md does not document instruction.txt\n";
index(slurp(File::Spec->catfile($repo,'...','README.md')),'### `bankswitching.txt`')>=0
   or die ".../README.md does not document bankswitching.txt\n";
index(slurp(File::Spec->catfile($repo,'...','README.md')),'### `roadmap.txt`')>=0 &&
index(slurp(File::Spec->catfile($repo,'...','README.md')),'### `context-history/`')>=0
   or die ".../README.md does not document the compact-context split\n";

# Every installed/user-facing host tool must use compiler-generated dependency
# files.  Keep dependency generation independent of caller-supplied CFLAGS,
# include the generated .d files, and ignore both object and dependency files.
for my $tool (qw(driver compiler assembler linker archiver simulator disassembler)) {
   my $make=slurp(File::Spec->catfile($repo,$tool,'Makefile'));
   $make =~ /^DEPFLAGS\s*=\s*-MMD\s+-MP\s*$/m
      or die "$tool/Makefile does not define standard .d dependency flags\n";
   index($make,'$(DEPFLAGS)')>=0 &&
   $make =~ /^-include\s+\$\(DEP(?:S)?\)\s*$/m &&
   $make =~ /\.o=\.d/
      or die "$tool/Makefile does not create and include .d dependency files\n";
   my $ignore=slurp(File::Spec->catfile($repo,$tool,'.gitignore'));
   $ignore =~ /^\*\.o\s*$/m && $ignore =~ /^\*\.d\s*$/m
      or die "$tool/.gitignore must ignore *.o and *.d\n";
}
my $sim_core_ignore=slurp(File::Spec->catfile($repo,'simulator','mos6502','.gitignore'));
$sim_core_ignore =~ /^\*\.o\s*$/m && $sim_core_ignore =~ /^\*\.d\s*$/m
   or die "simulator/mos6502/.gitignore must ignore *.o and *.d\n";
my $bankswitching=slurp(File::Spec->catfile($repo,'...','bankswitching.txt'));
length($bankswitching) <= 16 * 1024 &&
index($bankswitching,'Never use bare "bank 0" without saying which identity is meant.')>=0 &&
index($bankswitching,'file_index(BANKn) = bank_count - 1 - n')>=0 &&
index($bankswitching,'Public VCSC cartridge profiles reserve four bytes')>=0 &&
$bankswitching =~ /^\[ \] 38\. Reconsider the next tier: F0, FA2, and FC\. \*\*DEFERRED\.\*\*/m &&
$bankswitching =~ /^\[ \] 39\. Backfill an E0 public diagnostic cartridge\./m &&
$bankswitching =~ /^\[ \] 44\. Backfill a DPC public diagnostic cartridge\./m &&
$bankswitching !~ /^\[x\]/m
   or die "bankswitching hot record lost durable identities/open work or exceeded 16 KiB\n";
-f File::Spec->catfile($test,'assembler_relocatable_zp_relaxation.pl') &&
-f File::Spec->catfile($test,'linker_banked_archive_reporting.pl') &&
-f File::Spec->catfile($test,'vcs_bankswitching_diagnostic.pl') &&
-f File::Spec->catfile($test,'phase_overlay.pl') &&
-f File::Spec->catfile($test,'align_language_placement.pl') &&
-f File::Spec->catfile($test,'vcs_ascii_font_alignment.pl') &&
-f File::Spec->catfile($test,'vcs_big_ascii_font.pl') &&
-f File::Spec->catfile($repo,'libraries','vcs','fonts','big_ascii.c26') &&
-f File::Spec->catfile($test,'vcs_c26_cartridge_profiles.pl') &&
-f File::Spec->catfile($test,'assembler_component_constraints.pl') &&
-f File::Spec->catfile($test,'vcs_interactive_sprite_orientation.pl') &&
-f File::Spec->catfile($test,'vcs_bankswitching_example_make.pl') &&
-f File::Spec->catfile($test,'vcs_standard_renderer_banked.pl') &&
-f File::Spec->catfile($test,'vcs_standard_renderer_banked.cpp') &&
-f File::Spec->catfile($test,'vcs_standard_renderer_banked_stella.pl') &&
-f File::Spec->catfile($test,'page_named_mem_object_codegen_test.c26') &&
-f File::Spec->catfile($test,'stella_snapshot_keys.pl') &&
-f File::Spec->catfile($test,'stella_grade_bank_snapshot.pl') &&
-f File::Spec->catfile($test,'stella_png_rgb_digest.pl') &&
-f File::Spec->catfile($test,'vcs_three_plus_three_score_stella.pl') &&
-f File::Spec->catfile($test,'vcs_player_color_192_stella.pl') &&
-f File::Spec->catfile($test,'vcs_all_five_player_color_192_stella.pl') &&
-f File::Spec->catfile($test,'vcs_all_five_player_color_181_stella.pl') &&
-f File::Spec->catfile($test,'fixtures','player_color_192','reference_interactive_stella_7.0.png') &&
-f File::Spec->catfile($test,'vcs_faithful_legacy_multisprite.pl') &&
-f File::Spec->catfile($test,'vcs_faithful_legacy_multisprite_stella.pl') &&
-f File::Spec->catfile($test,'fixtures','faithful_legacy_multisprite','reference_diagnostic_stella_7.0.png') &&
-f File::Spec->catfile($repo,'libraries','vcs','renderers','faithful_legacy_multisprite','README.md') &&
-f File::Spec->catfile($repo,'libraries','vcs','renderers','faithful_legacy_multisprite','faithful_legacy_multisprite.c26') &&
-f File::Spec->catfile($repo,'examples','10_faithful_legacy_multisprite','01_diagnostic','faithful_legacy_multisprite_diagnostic.c26') &&
-f File::Spec->catfile($test,'vcs_multisprite_profiles.pl') &&
-f File::Spec->catfile($test,'vcs_multisprite_profiles.cpp') &&
-f File::Spec->catfile($test,'vcs_multisprite_stella.pl') &&
-f File::Spec->catfile($repo,'libraries','vcs','renderers','multisprite','README.md') &&
-f File::Spec->catfile($repo,'libraries','vcs','renderers','multisprite','multisprite.c26') &&
-f File::Spec->catfile($repo,'examples','14_multisprite','01_192','01_interactive','multisprite_192_interactive.c26') &&
-f File::Spec->catfile($repo,'examples','14_multisprite','02_181_score_above','01_interactive','multisprite_181_score_above_interactive.c26') &&
-f File::Spec->catfile($repo,'examples','14_multisprite','03_181_score_below','01_interactive','multisprite_181_score_below_interactive.c26') &&
-f File::Spec->catfile($repo,'examples','15_all_five_player_color_192','01_interactive','all_five_player_color_192_interactive.c26') &&
!-e File::Spec->catfile($test,'stella_snapshot_keys.py') &&
!-e File::Spec->catfile($test,'stella_grade_bank_snapshot.py') &&
-f File::Spec->catfile($repo,'libraries','vcs','bankswitching_diagnostic_suite.c26') &&
-f File::Spec->catfile($repo,'examples','09_bankswitching','01_diagnostic','bankswitching_diagnostic.c26') &&
-f File::Spec->catfile($repo,'examples','09_bankswitching','02_standard_renderer','banked_standard_renderer.c26') &&
-f File::Spec->catfile($repo,'examples','09_bankswitching','02_standard_renderer','README.md')
   or die "bank-aware archive/simulator/Stella diagnostics are incomplete\n";
my $top_make=slurp(File::Spec->catfile($repo,'Makefile'));
index($top_make,'stella-bank-test: tools')>=0 &&
index($top_make,'--stella')>=0 &&
index($top_make,'install -m 0644 libraries/vcs/bankswitching_diagnostic_suite.c26')>=0 &&
index($top_make,'rm -f $(DESTDIR)$(DATADIR)/vcs/bankswitching_diagnostic_suite.c26')>=0 &&
index($top_make,'--stop-pc=0x$$sim_done')>=0 &&
index($top_make,'--split-fill=0xA7 --reset-on-pc=0x$$sc_done')>=0 &&
index($top_make,'policy=every-reset bss=zero data=copy-through-write-alias')>=0 &&
index($top_make,'stella-renderer-bank-test: tools')>=0 &&
index($top_make,'standard_renderer_banked_f8.map')>=0 &&
index($top_make,'stella-wide-score-test: tools')>=0 &&
index($top_make,'stella-player-color-192-test: tools')>=0 &&
index($top_make,'stella-all-five-player-color-192-test: tools')>=0 &&
index($top_make,'libraries/vcs/renderers/all_five_player_color_192/all_five_player_color_192.c26')>=0 &&
index($top_make,'rm -f $(DESTDIR)$(DATADIR)/vcs/renderers/all_five_player_color_192/all_five_player_color_192.c26')>=0 &&
index($top_make,'stella-faithful-multisprite-test: tools')>=0 &&
index($top_make,'stella-multisprite-test: tools')>=0 &&
index($top_make,'libraries/vcs/renderers/faithful_legacy_multisprite/faithful_legacy_multisprite_renderer.s26')>=0 &&
index($top_make,'rm -f $(DESTDIR)$(DATADIR)/vcs/renderers/faithful_legacy_multisprite/faithful_legacy_multisprite_renderer.s26')>=0 &&
index($top_make,'libraries/vcs/renderers/multisprite/multisprite.c26')>=0 &&
index($top_make,'rm -f $(DESTDIR)$(DATADIR)/vcs/renderers/multisprite/multisprite.c26')>=0 &&
index($top_make,'examples/14_multisprite/01_192/01_interactive/multisprite_192_interactive.c26')>=0 &&
index($top_make,'examples/15_all_five_player_color_192/01_interactive/all_five_player_color_192_interactive.c26')>=0 &&
index($top_make,'install -m 0644 libraries/vcs/six_glyph_wide_component.c26')>=0 &&
index($top_make,'rm -f $(DESTDIR)$(DATADIR)/vcs/six_glyph_wide_component.c26')>=0 &&
index($top_make,'install -m 0644 libraries/vcs/six_glyph_big_wide_component.c26')>=0 &&
index($top_make,'rm -f $(DESTDIR)$(DATADIR)/vcs/six_glyph_big_wide_component.c26')>=0
   or die "top-level installed simulator/Stella and wide-score coverage is incomplete\n";
my $sim_readme=slurp(File::Spec->catfile($repo,'simulator','README.md'));
index($sim_readme,'--start-bank=N')>=0 &&
index($sim_readme,'mapper=F8')>=0 &&
index($sim_readme,'Stella remains the independent authority')>=0 &&
index($sim_readme,'The region name, window order,')>=0 &&
index($sim_readme,'--reset-on-pc=ADDR')>=0 &&
index($sim_readme,'--split-fill=BYTE')>=0
   or die "simulator documentation lost banked cfg/file-index/reset semantics\n";
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
-f File::Spec->catfile($test,'function_multiple_code_regions_codegen_test.c26') &&
-f File::Spec->catfile($test,'object_multiple_ro_regions_codegen_test.c26') &&
-f File::Spec->catfile($test,'replicated_rom_placement.pl') &&
-f File::Spec->catfile($test,'replicated_rom_missing_copy.pl') &&
-f File::Spec->catfile($test,'replicated_rom_separate_objects.pl') &&
-f File::Spec->catfile($test,'return_local_coalesce_codegen_test.c26') &&
-f File::Spec->catfile($test,'return_local_coalesce_split_codegen_test.c26') &&
-f File::Spec->catfile($test,'return_local_coalesce_fallback_codegen_test.c26') &&
-f File::Spec->catfile($test,'return_local_coalescing.pl') &&
!-e File::Spec->catfile($test,'function_multiple_code_regions_item21_error_test.c26') &&
	!-e File::Spec->catfile($test,'split_memory_static_local_error_test.c26') &&
!-e File::Spec->catfile($test,'split_memory_local_error_test.c26') &&
!-e File::Spec->catfile($test,'split_memory_bitfield_write_error_test.c26') &&
index(slurp(File::Spec->catfile($repo,'libraries','vcs','superchip.c26')),
      'mem cartram { $read_start:0xF080 $write_start:0xF000 $size:0x0080 $rw };')>=0
   or die "automatic Superchip allocation implementation or regression coverage is missing\n";
for my $cfg_name (qw(vcs_8k_f8sc.cfg vcs_16k_f6sc.cfg vcs_32k_f4sc.cfg)) {
   my $cfg_body=slurp(File::Spec->catfile($repo,'libraries','vcs',$cfg_name));
   $cfg_body =~ /cartram:\s+read_start\s*=\s*\$F080,\s*write_start\s*=\s*\$F000,\s*size\s*=\s*\$0080,\s*type\s*=\s*rw/
      or die "$cfg_name lost the shared split-address Superchip MEMORY region\n";
}
my $compiler_readme=slurp(File::Spec->catfile($repo,'compiler','README.md'));
my $abi_text=slurp(File::Spec->catfile($repo,'compiler','ABI.txt'));
my $linker_readme=slurp(File::Spec->catfile($repo,'linker','README.md'));
my $test_readme=slurp(File::Spec->catfile($repo,'test','README.md'));
index($compiler_readme,'bind that local directly to `$$`')>=0 &&
index($abi_text,'Returned-local coalescing')>=0 &&
index($linker_readme,'`RETURN COALESCING` is descriptive')>=0 &&
index($test_readme,'return_local_coalescing.pl')>=0
   or die "return-local coalescing documentation is incomplete\n";

my $banked_renderer_make=slurp(File::Spec->catfile($repo,'examples','09_bankswitching','02_standard_renderer','Makefile'));
$banked_renderer_make =~ /^all:\s+f8\.bin\s*$/m &&
$banked_renderer_make =~ /^play:\s+f8\.bin\s*\n\s*stella\s+-bs\s+F8\s+f8\.bin\s*$/m &&
$banked_renderer_make !~ /f6\.bin|f4\.bin|f8sc\.bin/ &&
index($banked_renderer_make,'vcs_standard_4k_ntsc.cfg')<0
   or die "banked standard renderer must remain one consolidated F8 public diagnostic\n";

my $standard_renderer_source=slurp(File::Spec->catfile($repo,'libraries','vcs','renderers','standard_4k_ntsc','standard_4k_ntsc_renderer.s26'));
index($standard_renderer_source,'.segmentregion "RENDERER_CODE", startup')>=0 &&
index($standard_renderer_source,'.segmentalign "RENDERER_CODE", 256')>=0 &&
index($standard_renderer_source,'.segmentprivate "RENDERER_CODE"')>=0 &&
index($standard_renderer_source,'.callstackextra 4')>=0
   or die "standard renderer lost object-owned placement or hidden-stack constraints
";
for my $component (
   'all_five/all_five.c26',
   'all_five_unofficial/all_five_unofficial.c26',
) {
   my $source=slurp(File::Spec->catfile($repo,'libraries','vcs','renderers',split('/',$component)));
   index($source,'asm .callstackextra 4;')>=0
      or die "$component lost its object-owned inline-assembly stack allowance\n";
}
{
   my $component='multisprite/multisprite.c26';
   my $source=slurp(File::Spec->catfile($repo,'libraries','vcs','renderers',split('/',$component)));
   index($source,'asm .callstackextra 2;')>=0
      or die "$component lost its reduced object-owned inline-assembly stack allowance\n";
}
for my $component (
   'player_color/player_color.c26',
   'player_color_181_unofficial/player_color_181_unofficial.c26',
) {
   my $source=slurp(File::Spec->catfile($repo,'libraries','vcs','renderers',split('/',$component)));
   index($source,'asm .callstackextra 0;')>=0 &&
   index($source,'TEMPLATE_object_masks')<0 &&
   index($source,'asm dec.z TEMPLATE_ball_y;')>=0
      or die "$component lost its mask-free direct-countdown zero-extra-stack contract\n";
}
my $player_color_source=slurp(File::Spec->catfile($repo,'libraries','vcs','renderers','player_color','player_color.c26'));
index($player_color_source,'parameter lines;')>=0 &&
index($player_color_source,'#if TEMPLATE_lines == 192')>=0 &&
index($player_color_source,'#elif TEMPLATE_lines == 181')>=0 &&
index($player_color_source,'#elif TEMPLATE_lines == 170')>=0 &&
index($player_color_source,'asm .callstackextra 0;')>=0 &&
index($player_color_source,'TEMPLATE_object_masks')<0 &&
index($player_color_source,'asm jsr @TEMPLATE_prepare_object_masks;')<0 &&
index($player_color_source,'asm jsr @prepare_one;')<0 &&
index($player_color_source,'asm jsr @set_range;')<0 &&
index($player_color_source,'asm dec.z TEMPLATE_ball_y;')>=0 &&
index($player_color_source,'asm cmp.z TEMPLATE_ball_y;')>=0
   or die "parameterized player_color lost its official direct-countdown zero-extra-stack contract\n";
my $standard_compat_cfg=slurp(File::Spec->catfile($repo,'libraries','vcs','renderers','standard_4k_ntsc','vcs_standard_4k_ntsc.cfg'));
$standard_compat_cfg !~ /callstack_extra|RENDERER_CODE|RENDERER_RODATA/
   or die "standard renderer compatibility cfg regained component-specific constraints
";
my @renderer_cfg_products;
find(sub {
   return unless -f $_ && /\.cfg\z/;
   push @renderer_cfg_products,$File::Find::name;
}, File::Spec->catdir($repo,'libraries','vcs','renderers'));
my %allowed_renderer_cfg = map { File::Spec->catfile($repo,split('/',$_)) => 1 } (
   'libraries/vcs/renderers/faithful_legacy_playercolors/faithful_legacy_playercolors.cfg',
   'libraries/vcs/renderers/faithful_legacy_multisprite/faithful_legacy_multisprite.cfg',
   'libraries/vcs/renderers/standard_4k_ntsc/vcs_standard_4k_ntsc.cfg',
   'libraries/vcs/renderers/standard_4k_ntsc_playercolors/vcs_standard_4k_ntsc_playercolors.cfg',
);
my @unexpected_renderer_cfg = grep { !$allowed_renderer_cfg{$_} } @renderer_cfg_products;
my @missing_renderer_cfg = grep { !-f $_ } sort keys %allowed_renderer_cfg;
!@unexpected_renderer_cfg && !@missing_renderer_cfg
   or die "new renderer x mapper cfg product is forbidden; unexpected=@unexpected_renderer_cfg missing=@missing_renderer_cfg
";
my $vcs_machine=slurp(File::Spec->catfile($repo,'libraries','vcs','vcs.c26'));
index($vcs_machine,'mem rom')<0
   or die "vcs.c26 must describe the machine only; cartridge ROM belongs to a profile\n";
my $vcs_2k_profile=slurp(File::Spec->catfile($repo,'libraries','vcs','vcs_2k.c26'));
index($vcs_2k_profile,'mem rom { $start:0xf800 $size:0x07fa $ro $priority:1 };')>=0 &&
index($vcs_2k_profile,'$image_size:0x0800')>=0 &&
index($vcs_2k_profile,'$vectors_offset:0x07fa')>=0
   or die "vcs_2k.c26 lost its canonical 2K mapping or vector reservation\n";
my $vcs_4k_profile=slurp(File::Spec->catfile($repo,'libraries','vcs','vcs_4k.c26'));
index($vcs_4k_profile,'mem rom { $start:0xf000 $size:0x0ffa $ro $priority:1 };')>=0
   or die "vcs_4k.c26 lost its allocatable-bytes-only ROM declaration\n";
my $score_source=slurp(File::Spec->catfile($repo,'examples','01_basic','04_score','score.c26'));
my $score_make=slurp(File::Spec->catfile($repo,'examples','01_basic','04_score','Makefile'));
my $examples_build=slurp(File::Spec->catfile($test,'vcs_examples_build.pl'));
index($score_source,'include "vcs_2k.c26"')>=0 &&
index($score_make,'-T $(VCS_DIR)/vcs.cfg')>=0 &&
index($score_make,'-eq 2048')>=0 &&
index($examples_build,'sub profile_from_source')>=0 &&
index($examples_build,q{include\s+"vcs_2k\.c26"})>=0 &&
index($examples_build,q{include\s+"vcs_8k_f8\.c26"})>=0 &&
index($examples_build,q{include\s+"vcs_8k_0840\.c26"})>=0 &&
index($examples_build,q{include\s+"vcs_8k_ua\.c26"})>=0 &&
index($examples_build,q{include\s+"vcs_8k_uasw\.c26"})>=0 &&
index($examples_build,q{include\s+"vcs_8k_0fa0\.c26"})>=0 &&
index($examples_build,q{$profile eq '2k'})>=0 &&
index($examples_build,q{$profile eq 'f8'})>=0 &&
index($examples_build,q{$profile eq '0840'})>=0 &&
index($examples_build,q{$profile eq 'ua'})>=0 &&
index($examples_build,q{$profile eq 'uasw'})>=0 &&
index($examples_build,q{$profile eq '0fa0'})>=0 &&
index($examples_build,q{'disassembler','roundtrip.pl'})>=0 &&
index($examples_build,'disassembler-roundtrip')>=0 &&
index($examples_build,'example disassembler round trip failed')>=0
   or die "editable example cartridge-profile/disassembler coverage is incomplete
";
-f File::Spec->catfile($test,'vcsc_disassembler_hardening.pl')
   or die "missing vcsc_disassembler_hardening.pl
";

# vcsc-disas is a first-class shipped tool on every package/install path.  Keep
# these source-level assertions even on hosts that cannot execute a MinGW build.
index($top_make,'./disassembler install')>=0 &&
index($top_make,'bin/vcsc-disas.exe')>=0 &&
index($top_make,'bin/vcsc-disas')>=0 &&
index($top_make,'vcsc-disas.exe; do')>=0 &&
index($top_make,'vcsc-sim vcsc-disas; do')>=0 &&
index($top_make,'"$$stage_bin/vcsc-disas"')>=0 &&
index($top_make,'blank_screen.roundtrip.hex')>=0
   or die "vcsc-disas install/Linux/Windows package integration is incomplete
";

# The two historically monolithic E2E drivers are implementation helpers now;
# their public test cases are fixed-size shards so the outer --jobs pool can
# schedule the work without nested worker pools.
for my $i (1..8) {
   my $path=File::Spec->catfile($test,"vcs_examples_build_${i}of8.test");
   -f $path or die "missing examples-build shard descriptor $path\n";
   my $body=slurp($path);
   index($body,"--shard $i/8")>=0
      or die "examples-build shard $i/8 has the wrong runner\n";
}
my @score_shards=(
   ['player_color_181',1],
   ['all_five_181',0],
   ['player_color_181_unofficial',0],
   ['all_five_181_unofficial',0],
);
for my $entry (@score_shards) {
   my($family,$mixed)=@$entry;
   my $path=File::Spec->catfile($test,"vcs_score_composition_raster_${family}.test");
   -f $path or die "missing score-composition shard descriptor $path\n";
   my $body=slurp($path);
   index($body,"--family $family")>=0
      or die "score-composition shard $family has the wrong runner\n";
   my $has_mixed=index($body,'--mixed')>=0 ? 1 : 0;
   $has_mixed==$mixed
      or die "score-composition mixed-instance coverage is assigned incorrectly for $family\n";
}
my $wide_source=slurp(File::Spec->catfile($repo,'examples','01_basic','06_wide_score','wide_score.c26'));
my $wide_make=slurp(File::Spec->catfile($repo,'examples','01_basic','06_wide_score','Makefile'));
index($wide_source,'include "vcs_2k.c26"')>=0 &&
index($wide_source,'instantiate "six_glyph_wide_component.c26" as score')>=0 &&
index($wide_make,'-T $(VCS_DIR)/vcs.cfg')>=0 &&
index($wide_make,'-eq 2048')>=0 &&
-f File::Spec->catfile($test,'vcs_six_glyph_wide.pl') &&
-f File::Spec->catfile($test,'vcs_six_glyph_wide_181.pl') &&
-f File::Spec->catfile($test,'vcs_six_glyph_wide_raster.cpp') &&
-f File::Spec->catfile($test,'vcs_six_glyph_wide_stella.pl') &&
-f File::Spec->catfile($repo,'examples','04_player_color_181','11_wide_score_above','01_interactive','player_color_181_wide_score_above_interactive.c26') &&
-f File::Spec->catfile($repo,'examples','04_player_color_181','12_wide_score_below','01_interactive','player_color_181_wide_score_below_interactive.c26') &&
-f File::Spec->catfile($repo,'test','fixtures','vcs_examples','05_wide_score','reference_stella_7.0.png')
   or die "widely spaced score example, tests, or oracle are incomplete
";
my $big_wide_source=slurp(File::Spec->catfile($repo,'examples','01_basic','07_big_wide_score','big_wide_score.c26'));
my $big_wide_make=slurp(File::Spec->catfile($repo,'examples','01_basic','07_big_wide_score','Makefile'));
index($big_wide_source,'include "fonts/big_decimal.c26"')>=0 &&
index($big_wide_source,'instantiate "six_glyph_big_wide_component.c26" as score')>=0 &&
index($big_wide_source,'vcs_ntsc_wait_component_scanlines(87)')>=0 &&
index($big_wide_source,'vcs_ntsc_wait_visible_tail_scanlines(86)')>=0 &&
index($big_wide_make,'-eq 2048')>=0 &&
-f File::Spec->catfile($repo,'libraries','vcs','fonts','big_decimal.c26') &&
-f File::Spec->catfile($repo,'libraries','vcs','fonts','big_hex.c26') &&
-f File::Spec->catfile($repo,'libraries','vcs','six_glyph_big_wide_component.c26') &&
-f File::Spec->catfile($test,'vcs_big_font_family.pl') &&
-f File::Spec->catfile($test,'vcs_six_glyph_big_wide.pl') &&
-f File::Spec->catfile($test,'vcs_six_glyph_big_wide_raster.cpp')
   or die "big 8x16 wide score family, example, or tests are incomplete
";
my $bank_example_make=slurp(File::Spec->catfile($repo,'examples','09_bankswitching','01_diagnostic','Makefile'));
index($bank_example_make,'-DVCS_NO_DEFAULT_ROM')<0 &&
index($bank_example_make,'$(VCS_DIR)/vcs.cfg')>=0 &&
index($bank_example_make,'$(VCS_DIR)/vcs_8k_f8.cfg')<0
   or die "public bank diagnostics must build from C26 topology through reduced vcs.cfg\n";
for my $profile (qw(vcs_2k.c26 vcs_2k_cv.c26 vcs_4k.c26 vcs_4k_sc.c26 vcs_8k_f8.c26 vcs_8k_0840.c26 vcs_8k_ua.c26 vcs_8k_uasw.c26 vcs_8k_0fa0.c26 vcs_12k_fa.c26 vcs_16k_f6.c26 vcs_16k_jane.c26 vcs_32k_f4.c26 vcs_8k_f8sc.c26 vcs_16k_f6sc.c26 vcs_32k_f4sc.c26 vcs_direct_8k.c26 vcs_omni_32k.c26)) {
   -f File::Spec->catfile($repo,'libraries','vcs',$profile)
      or die "missing migrated C26 cartridge profile $profile\n";
   index($top_make,"libraries/vcs/$profile")>=0
      or die "$profile is not installed/uninstalled by the top-level Makefile\n";
}
-f File::Spec->catfile($repo,'libraries','vcs','commavid.c26') &&
-f File::Spec->catfile($repo,'libraries','vcs','vcs_2k_cv.c26') &&
-f File::Spec->catfile($repo,'libraries','vcs','vcs_2k_cv.cfg') &&
index($top_make,'libraries/vcs/commavid.c26')>=0 &&
index($top_make,'libraries/vcs/vcs_2k_cv.c26')>=0 &&
index($top_make,'libraries/vcs/vcs_2k_cv.cfg')>=0 &&
-f File::Spec->catfile($test,'vcs_cv.pl') &&
-f File::Spec->catfile($repo,'examples','09_bankswitching','06_cv','cv_diagnostic.c26') &&
-f File::Spec->catfile($repo,'examples','09_bankswitching','06_cv','README.md')
   or die "CV profile/diagnostic support is missing installation or test coverage\n";
-f File::Spec->catfile($repo,'libraries','vcs','vcs_8k_0840.c26') &&
-f File::Spec->catfile($repo,'libraries','vcs','vcs_8k_0840.cfg') &&
index($top_make,'libraries/vcs/vcs_8k_0840.c26')>=0 &&
index($top_make,'libraries/vcs/vcs_8k_0840.cfg')>=0 &&
-f File::Spec->catfile($test,'vcs_0840.pl') &&
-f File::Spec->catfile($repo,'examples','09_bankswitching','08_0840','econobanking_diagnostic.c26') &&
-f File::Spec->catfile($repo,'examples','09_bankswitching','08_0840','README.md')
   or die "0840 profile/diagnostic support is missing installation or test coverage\n";
-f File::Spec->catfile($repo,'libraries','vcs','vcs_8k_ua.c26') &&
-f File::Spec->catfile($repo,'libraries','vcs','vcs_8k_uasw.c26') &&
-f File::Spec->catfile($repo,'libraries','vcs','vcs_8k_ua.cfg') &&
-f File::Spec->catfile($repo,'libraries','vcs','vcs_8k_uasw.cfg') &&
index($top_make,'libraries/vcs/vcs_8k_ua.c26')>=0 &&
index($top_make,'libraries/vcs/vcs_8k_uasw.c26')>=0 &&
index($top_make,'libraries/vcs/vcs_8k_ua.cfg')>=0 &&
index($top_make,'libraries/vcs/vcs_8k_uasw.cfg')>=0 &&
-f File::Spec->catfile($test,'vcs_ua.pl') &&
-f File::Spec->catfile($repo,'examples','09_bankswitching','09_ua','ua_diagnostic.c26') &&
-f File::Spec->catfile($repo,'examples','09_bankswitching','09_ua','uasw_diagnostic.c26') &&
-f File::Spec->catfile($repo,'examples','common','ua_diagnostic_common.c26') &&
-f File::Spec->catfile($repo,'examples','09_bankswitching','09_ua','README.md')
   or die "UA/UASW profile/diagnostic support is missing installation or test coverage
";
-f File::Spec->catfile($repo,'libraries','vcs','vcs_8k_0fa0.c26') &&
-f File::Spec->catfile($repo,'libraries','vcs','vcs_8k_0fa0.cfg') &&
index($top_make,'libraries/vcs/vcs_8k_0fa0.c26')>=0 &&
index($top_make,'libraries/vcs/vcs_8k_0fa0.cfg')>=0 &&
-f File::Spec->catfile($test,'vcs_0fa0.pl') &&
-f File::Spec->catfile($repo,'examples','09_bankswitching','10_0fa0','fotomania_diagnostic.c26') &&
-f File::Spec->catfile($repo,'examples','09_bankswitching','10_0fa0','README.md')
   or die "0FA0 profile/diagnostic support is missing installation or test coverage\n";
-f File::Spec->catfile($repo,'libraries','vcs','vcs_16k_jane.c26') &&
-f File::Spec->catfile($repo,'libraries','vcs','vcs_16k_jane.cfg') &&
index($top_make,'libraries/vcs/vcs_16k_jane.c26')>=0 &&
index($top_make,'libraries/vcs/vcs_16k_jane.cfg')>=0 &&
-f File::Spec->catfile($test,'vcs_jane.pl') &&
-f File::Spec->catfile($repo,'examples','09_bankswitching','07_jane','jane_diagnostic.c26') &&
-f File::Spec->catfile($repo,'examples','09_bankswitching','07_jane','README.md')
   or die "JANE profile/diagnostic support is missing installation or test coverage\n";
-f File::Spec->catfile($repo,'libraries','vcs','fa_ram_plus.c26') &&
index($top_make,'libraries/vcs/fa_ram_plus.c26')>=0 &&
-f File::Spec->catfile($repo,'libraries','vcs','vcs_12k_fa.cfg') &&
index($top_make,'libraries/vcs/vcs_12k_fa.cfg')>=0
   or die "FA/RAM Plus profile support is missing installation coverage\n";
-f File::Spec->catfile($repo,'libraries','vcs','vcs_4k_sc.cfg') &&
index($top_make,'libraries/vcs/vcs_4k_sc.cfg')>=0 &&
-f File::Spec->catfile($test,'vcs_4ksc.pl') &&
-f File::Spec->catfile($repo,'examples','09_bankswitching','04_4ksc','4ksc_diagnostic.c26')
   or die "4KSC profile/diagnostic support is missing installation or test coverage\n";
my $direct_profile=slurp(File::Spec->catfile($repo,'libraries','vcs','vcs_direct_8k.c26'));
my $omni_profile=slurp(File::Spec->catfile($repo,'libraries','vcs','vcs_omni_32k.c26'));
index($direct_profile,'No real hardware currently supports this exact configuration')>=0 &&
index($omni_profile,'No real hardware currently supports this configuration')>=0 &&
index($omni_profile,'$signature:OMNI')>=0 &&
index($omni_profile,'mem cartram { $start:0x1000 $size:0x1000 $rw }')>=0 &&
-f File::Spec->catfile($test,'vcs_omni_32k.pl') &&
-f File::Spec->catfile($repo,'libraries','vcs','vcs_omni_32k.cfg') &&
index($top_make,'libraries/vcs/vcs_omni_32k.cfg')>=0 &&
-f File::Spec->catfile($repo,'examples','09_bankswitching','05_omni','omni_diagnostic.c26') &&
-f File::Spec->catfile($repo,'examples','09_bankswitching','05_omni','README.md')
   or die "direct/OMNI certification profiles, simulator cfg, diagnostic, or hardware-status comments are incomplete
";
-f File::Spec->catfile($repo,'libraries','vcs','vcs.cfg') &&
index($top_make,'libraries/vcs/vcs.cfg')>=0
   or die "reduced vcs.cfg is missing from installation coverage\n";
for my $name (qw(missing size start type)) {
   my $body=slurp(File::Spec->catfile($test,"e2e_mem_region_cfg_${name}_mismatch.c26"));
   index($body,'expectlinkfail')<0
      or die "stale cfg $name regression still expects C26 allocator metadata to lose\n";
}
-f File::Spec->catfile($test,'linker_banked_auto_placement.pl')
   or die "automatic bank-placement regression test is missing\n";
-f File::Spec->catfile($test,'linker_banked_placement_modes.pl')
   or die "placement-mode optimization regression test is missing\n";
-f File::Spec->catfile($repo,'libraries','vcs','vcs_8k_f8.cfg') &&
-f File::Spec->catfile($test,'vcs_f8_profile.pl') &&
-f File::Spec->catfile($test,'fixtures','bankswitching','f8_profile_diagnostic.c26')
   or die "certified F8 profile or its diagnostics are missing\n";
-f File::Spec->catfile($repo,'libraries','vcs','vcs_16k_f6.cfg') &&
-f File::Spec->catfile($repo,'libraries','vcs','vcs_32k_f4.cfg') &&
-f File::Spec->catfile($test,'vcs_f6_f4_profiles.pl')
   or die "certified F6/F4 profiles or their regression test are missing\n";

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
my $context=slurp(File::Spec->catfile($repo,'...','context.txt'));
my $roadmap=slurp(File::Spec->catfile($repo,'...','roadmap.txt'));
my $ram_roadmap=slurp(File::Spec->catfile($repo,'...','ram_optimization.txt'));
my %hot_limits=(
   'README.md' => 8*1024,
   'context.txt' => 16*1024,
   'roadmap.txt' => 12*1024,
   'bankswitching.txt' => 16*1024,
   'disassembler.txt' => 16*1024,
   'enhanced_asymmetric.txt' => 20*1024,
   'ram_optimization.txt' => 8*1024,
   'inline_roadmap.txt' => 8*1024,
   'video_standard_roadmap.txt' => 8*1024,
   'instruction.txt' => 8*1024,
);
my $hot_total=0;
for my $name (sort keys %hot_limits) {
   my $body=slurp(File::Spec->catfile($repo,'...',$name));
   my $bytes=length($body);
   $bytes <= $hot_limits{$name}
      or die ".../$name exceeds compact hot-record limit: $bytes > $hot_limits{$name}\n";
   $hot_total += $bytes;
}
$hot_total <= 64*1024
   or die "developer hot records exceed 64 KiB total: $hot_total\n";

index($context,'Active workstream: `.../roadmap.txt`.')>=0 &&
index($context,'hard 16 KiB ceiling')>=0 &&
index($context,'Completed narratives belong in `.../context-history/YYYY-MM-DD.txt`.')>=0 &&
index($context,'Immediate TODO')>=0
   or die "compact context lost hot-state discipline or active-workstream pointer\n";
$context !~ /^\s*\[x\]/m
   or die "compact context contains completed checklist history\n";

$roadmap =~ /^Current next action: Item 44, public diagnostic cartridge\./m &&
$roadmap !~ /^\[ \] 43\./m &&
$roadmap =~ /^\[ \] 44\. Add a public diagnostic cartridge/m &&
$roadmap =~ /^\[ \] 45\. Add playfield-color support/m &&
$roadmap =~ /^\[ \] 46\. Add a public side-scroller\/platform example\./m &&
$roadmap !~ /^\s*\[x\]/m
   or die "main roadmap must contain only unfinished current work\n";

index($ram_roadmap,'No unfinished items.')>=0 &&
index($ram_roadmap,'test/fixtures/vcs_animated_gallery_ram_accounting/golden.json')>=0 &&
$ram_roadmap !~ /^\s*\[x\]/m &&
-f File::Spec->catfile($repo,qw(test fixtures vcs_animated_gallery_ram_accounting golden.json))
   or die "RAM closeout lost durable accounting authority or regained completed checklist history\n";

$context !~ /^Change log$/m
   or die "compact context regained an embedded chronological changelog\n";
my @context_history=sort glob(File::Spec->catfile($repo,'...','context-history','*.txt'));
@context_history
   or die "context-history contains no daily files\n";
for my $history_path (@context_history) {
   my $name=basename($history_path);
   $name =~ /\A(\d{4}-\d{2}-\d{2})\.txt\z/
      or die "invalid context-history filename $name\n";
   my $date=$1;
   my $body=slurp($history_path);
   $body !~ /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [A-Z]{3,4}\s*$/m
      or die "$name contains a timestamp-only history header; add a short standalone description on the same line\n";
   my @timestamps=($body =~ /^(\d{4}-\d{2}-\d{2}) \d{2}:\d{2}:\d{2} [A-Z]{3,4}, /mg);
   @timestamps
      or die "$name contains no timestamped history entries\n";
   for my $entry_date (@timestamps) {
      $entry_date eq $date
         or die "$name contains an entry dated $entry_date\n";
   }
}

my @markdown;
find({no_chdir=>1,wanted=>sub {
   my $path=$File::Find::name;
   my $rel=File::Spec->abs2rel($path,$repo); $rel =~ s{\\}{/}g;
   if ($rel eq '.git' || $rel =~ m{\A\.git/}) {
      $File::Find::prune=1 if -d $path;
      return;
   }
   return unless -f $path && $path =~ /\.md\z/;
   push @markdown,$path;
}},$repo);
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

for my $required (qw(
   libraries/vcs/superchip.c26
   libraries/vcs/vcs_4k_sc.c26
   libraries/vcs/vcs_4k_sc.cfg
   libraries/vcs/vcs_8k_f8sc.c26
   libraries/vcs/vcs_16k_f6sc.c26
   libraries/vcs/vcs_8k_ua.c26
   libraries/vcs/vcs_8k_uasw.c26
   libraries/vcs/vcs_8k_ua.cfg
   libraries/vcs/vcs_8k_uasw.cfg
   libraries/vcs/vcs_8k_0fa0.c26
   libraries/vcs/vcs_8k_0fa0.cfg
   libraries/vcs/vcs_16k_jane.c26
   libraries/vcs/vcs_16k_jane.cfg
   libraries/vcs/vcs_32k_f4sc.c26
   libraries/vcs/vcs_8k_f8sc.cfg
   libraries/vcs/vcs_16k_f6sc.cfg
   libraries/vcs/vcs_32k_f4sc.cfg
   libraries/vcs/vcs_omni_32k.cfg
)) {
   -f File::Spec->catfile($repo,split('/', $required))
      or die "missing required Superchip file $required\n";
}
my $superchip_header=slurp(File::Spec->catfile($repo,'libraries','vcs','superchip.c26'));
index($superchip_header,'mem cartram')>=0 &&
index($superchip_header,'$read_start:0xF080')>=0 &&
index($superchip_header,'$write_start:0xF000')>=0 &&
index($superchip_header,'$size:0x0080')>=0
   or die "superchip.c26 lost the allocatable split-memory region\n";
index($superchip_header,'superchip_ram')<0
   or die "superchip.c26 must not publish a whole-window alias\n";
my $superchip_diagnostic=slurp(File::Spec->catfile($repo,'libraries','vcs','bankswitching_diagnostic_suite.c26'));
index($superchip_diagnostic,'cartram uint8_t diagnostic_superchip_bss_head;')>=0 &&
index($superchip_diagnostic,'cartram uint8_t diagnostic_superchip_data_head := 0x5A;')>=0 &&
index($superchip_diagnostic,'cartram uint8_t diagnostic_superchip_bss[124];')>=0 &&
index($superchip_diagnostic,'cartram uint8_t diagnostic_superchip_data_tail := 0xA5;')>=0 &&
index($superchip_diagnostic,'validate_superchip_startup')>=0 &&
index($superchip_diagnostic,'poison_superchip_before_result')>=0 &&
index($superchip_diagnostic,'diagnostic_superchip_ram')<0
   or die "bankswitching diagnostic lost its mixed allocator-owned Superchip lifecycle probe\n";
my $pc192_test=slurp(File::Spec->catfile($test,'vcs_player_color_192.pl'));
my $pf_phase=slurp(File::Spec->catfile($test,'vcs_playfield_phase.cpp'));
index($pc192_test,'03_player_color_192 01_interactive player_color_192_interactive.c26')>=0 &&
index($pc192_test,q{'diagonal-192'})>=0 &&
index(slurp(File::Spec->catfile($test,'vcs_player_color_192_animation.pl')),q{'gallery-192'})>=0 &&
index($pf_phase,'kDiagonalPlayfield192')>=0 &&
index($pf_phase,'kGalleryPlayfield192')>=0 &&
index($pf_phase,'15/22/51/54')<0
   or die "player-color-192 asymmetric playfield regression coverage is incomplete
";
my $pc192_reference=File::Spec->catfile($test,'fixtures','player_color_192','reference_interactive_stella_7.0.png');
sha256_hex(slurp($pc192_reference)) eq '6ac771765db3b5c0b91836c69fd3e21ff755fe48a668b06938960f1c2373a980'
   or die "reviewed player-color-192 Stella reference PNG changed without updating its contract
";

index($top_make,'stella-three-plus-three-score-test: tools')>=0 &&
index($top_make,'test/vcs_three_plus_three_score_stella.pl')>=0
   or die "three-plus-three score lost its live Stella regression target\n";

my $snapshot_keys=slurp(File::Spec->catfile($test,'stella_snapshot_keys.pl'));
index($snapshot_keys,"'--reset'")>=0 &&
index($snapshot_keys,"function_keycode('F2')")>=0
   or die "Stella bank diagnostics lost console-reset lifecycle coverage\n";
index($top_make,'libraries/vcs/vcs_4k_sc.c26')>=0 &&
index($top_make,'libraries/vcs/vcs_4k_sc.cfg')>=0 &&
index($top_make,'libraries/vcs/vcs_8k_f8sc.c26')>=0 &&
index($top_make,'libraries/vcs/vcs_8k_f8sc.cfg')>=0 &&
index($top_make,'libraries/vcs/superchip.c26')>=0
   or die "4KSC/banked Superchip profiles/header are not installed and uninstalled\n";

print "source tree hygiene ok\n";
