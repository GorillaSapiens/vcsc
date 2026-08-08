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
      next if $rel =~ /\.(?:bin|hex|map|sym|lst|o26|l26)\z/;
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
my $bankswitching=slurp(File::Spec->catfile($repo,'...','bankswitching.txt'));
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
$bankswitching =~ /stable final green-background\/white-PASS or dark-red-\s*background\/white-FAIL frame/ &&
$bankswitching =~ /exact letters copied\s+from the default ASCII font/ &&
$bankswitching =~ /six-glyph-wide score\s+component/ &&
$bankswitching =~ /deliberately poisoned F8SC image/ &&
$bankswitching =~ /exactly 262 scanlines/ &&
$bankswitching =~ /proving read-window\/write-window\s+direction/
   or die "bankswitching plan lost completed Stella bank diagnostics or future Superchip extension\n";
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
-f File::Spec->catfile($test,'vcs_player_color_192_stella.pl') &&
-f File::Spec->catfile($test,'fixtures','player_color_192','reference_interactive_stella_7.0.png') &&
-f File::Spec->catfile($test,'vcs_faithful_legacy_multisprite.pl') &&
-f File::Spec->catfile($test,'vcs_faithful_legacy_multisprite_stella.pl') &&
-f File::Spec->catfile($test,'fixtures','faithful_legacy_multisprite','reference_diagnostic_stella_7.0.png') &&
-f File::Spec->catfile($repo,'libraries','vcs','renderers','faithful_legacy_multisprite','README.md') &&
-f File::Spec->catfile($repo,'libraries','vcs','renderers','faithful_legacy_multisprite','faithful_legacy_multisprite.c26') &&
-f File::Spec->catfile($repo,'examples','10_faithful_legacy_multisprite','01_diagnostic','faithful_legacy_multisprite_diagnostic.c26') &&
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
index($top_make,'stella-faithful-multisprite-test: tools')>=0 &&
index($top_make,'libraries/vcs/renderers/faithful_legacy_multisprite/faithful_legacy_multisprite_renderer.s26')>=0 &&
index($top_make,'rm -f $(DESTDIR)$(DATADIR)/vcs/renderers/faithful_legacy_multisprite/faithful_legacy_multisprite_renderer.s26')>=0 &&
index($top_make,'install -m 0644 libraries/vcs/six_glyph_wide_component.c26')>=0 &&
index($top_make,'rm -f $(DESTDIR)$(DATADIR)/vcs/six_glyph_wide_component.c26')>=0
   or die "top-level installed simulator/Stella and wide-score coverage is incomplete\n";
my $sim_readme=slurp(File::Spec->catfile($repo,'simulator','README.md'));
index($sim_readme,'--start-bank=N')>=0 &&
index($sim_readme,'mapper=F8')>=0 &&
index($sim_readme,'Stella remains the independent authority')>=0 &&
index($sim_readme,'The region name, window order,')>=0 &&
index($sim_readme,'--reset-on-pc=ADDR')>=0 &&
index($sim_readme,'--split-fill=BYTE')>=0
   or die "simulator documentation lost banked cfg/file-index/reset semantics\n";
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
index($bankswitching,'[x] 21. Add explicit multi-bank duplication for immutable objects and functions.')>=0 &&
index($bankswitching,'[x] 22. Coalesce a single returned automatic variable with `$$`.')>=0 &&
index($bankswitching,'[x] 23. Integrate automatic Superchip initialization and lifecycle tests.')>=0 &&
index($bankswitching,'bank0 bank1 const uint8_t table[] := { ... };')>=0 &&
index($bankswitching,'Combining `inline` with any named bank/memory-region specification')>=0 &&
index($bankswitching,'RETURN COALESCING')>=0
   or die "bankswitching plan lost completed Superchip locals, bank duplication, return coalescing, or lifecycle rules\n";
my $compiler_readme=slurp(File::Spec->catfile($repo,'compiler','README.md'));
my $abi_text=slurp(File::Spec->catfile($repo,'compiler','ABI.txt'));
my $linker_readme=slurp(File::Spec->catfile($repo,'linker','README.md'));
my $test_readme=slurp(File::Spec->catfile($repo,'test','README.md'));
index($compiler_readme,'bind that local directly to `$$`')>=0 &&
index($abi_text,'Returned-local coalescing')>=0 &&
index($linker_readme,'`RETURN COALESCING` is descriptive')>=0 &&
index($test_readme,'return_local_coalescing.pl')>=0
   or die "return-local coalescing documentation is incomplete\n";
index($bankswitching,'[x] 24. Define generic C26 cartridge-output and bank topology.')>=0 &&
index($bankswitching,'[x] 25. Make C26 `mem` declarations authoritative and derive output-bank ownership.')>=0 &&
index($bankswitching,'[x] 26. Migrate existing cartridge profiles and add a direct-bank packaging profile.')>=0 &&
index($bankswitching,'[x] 27. Move component-specific placement constraints out of cfg files.')>=0 &&
-f File::Spec->catfile($test,'linker_c26_mem_authority.pl') &&
-f File::Spec->catfile($test,'vcs_c26_cartridge_profiles.pl') &&
-f File::Spec->catfile($test,'assembler_component_constraints.pl') &&
index($compiler_readme,'Complete declarations are authoritative linker metadata')>=0 &&
index($compiler_readme,'configuration-only input')>=0 &&
index($abi_text,'Authoritative memory-region metadata')>=0 &&
index($linker_readme,'## Authoritative C26 memory regions')>=0 &&
index($linker_readme,'constructs its internal direct or selector-controlled bank model')>=0 &&
index($linker_readme,'## Component-owned placement and hidden-stack contracts')>=0 &&
index($test_readme,'vcs_c26_cartridge_profiles.pl')>=0 &&
index($test_readme,'assembler_component_constraints.pl')>=0 &&
index($test_readme,'vcs_interactive_sprite_orientation.pl')>=0
   or die "C26 profile migration, authoritative memory, or regression documentation is incomplete\n";

index($bankswitching,'[x] 28. Add the first composable banked profile for the maintained standard renderer.')>=0 &&
index($bankswitching,'37 cycles total, 25 more than direct JSR/RTS')>=0 &&
index($compiler_readme,'bank0 page const uint8_t glyph[8]')>=0 &&
index($test_readme,'vcs_standard_renderer_banked.pl')>=0 &&
index($linker_readme,'VBLANK-only')>=0
   or die "banked standard-renderer composition documentation is incomplete\n";
my $banked_renderer_make=slurp(File::Spec->catfile($repo,'examples','09_bankswitching','02_standard_renderer','Makefile'));
$banked_renderer_make =~ /^all:\s+f8\.bin\s*$/m &&
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
   'all_five_181/all_five_181.c26',
   'all_five_181_unofficial/all_five_181_unofficial.c26',
   'all_five_192/all_five_192.c26',
) {
   my $source=slurp(File::Spec->catfile($repo,'libraries','vcs','renderers',split('/',$component)));
   index($source,'asm .callstackextra 4;')>=0
      or die "$component lost its object-owned inline-assembly stack allowance\n";
}
for my $component (
   'player_color_181/player_color_181.c26',
   'player_color_181_unofficial/player_color_181_unofficial.c26',
) {
   my $source=slurp(File::Spec->catfile($repo,'libraries','vcs','renderers',split('/',$component)));
   index($source,'asm .callstackextra 0;')>=0 &&
   index($source,'TEMPLATE_object_masks')<0 &&
   index($source,'asm dec.z TEMPLATE_ball_y;')>=0
      or die "$component lost its mask-free direct-countdown zero-extra-stack contract\n";
}
my $player_color_192_source=slurp(File::Spec->catfile($repo,'libraries','vcs','renderers','player_color_192','player_color_192.c26'));
index($player_color_192_source,'asm .callstackextra 0;')>=0 &&
index($player_color_192_source,'TEMPLATE_object_masks')<0 &&
index($player_color_192_source,'asm jsr @TEMPLATE_prepare_object_masks;')<0 &&
index($player_color_192_source,'asm jsr @prepare_one;')<0 &&
index($player_color_192_source,'asm jsr @set_range;')<0 &&
index($player_color_192_source,'asm dec.z TEMPLATE_ball_y;')>=0 &&
index($player_color_192_source,'asm cmp.z TEMPLATE_ball_y;')>=0
   or die "player_color_192 lost its official direct-countdown zero-extra-stack contract\n";
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
my $score_source=slurp(File::Spec->catfile($repo,'examples','01_basic','03_score','score.c26'));
my $score_make=slurp(File::Spec->catfile($repo,'examples','01_basic','03_score','Makefile'));
index($score_source,'include "vcs_2k.c26"')>=0 &&
index($score_make,'-T $(VCS_DIR)/vcs.cfg')>=0 &&
index($score_make,'-eq 2048')>=0
   or die "score example is not locked to the 2K C26 profile
";
my $wide_source=slurp(File::Spec->catfile($repo,'examples','01_basic','05_wide_score','wide_score.c26'));
my $wide_make=slurp(File::Spec->catfile($repo,'examples','01_basic','05_wide_score','Makefile'));
index($wide_source,'include "vcs_2k.c26"')>=0 &&
index($wide_source,'template "six_glyph_wide_component.c26" as score')>=0 &&
index($wide_make,'-T $(VCS_DIR)/vcs.cfg')>=0 &&
index($wide_make,'-eq 2048')>=0 &&
-f File::Spec->catfile($test,'vcs_six_glyph_wide.pl') &&
-f File::Spec->catfile($test,'vcs_six_glyph_wide_181.pl') &&
-f File::Spec->catfile($test,'vcs_six_glyph_wide_raster.cpp') &&
-f File::Spec->catfile($test,'vcs_six_glyph_wide_stella.pl') &&
-f File::Spec->catfile($repo,'examples','04_player_color_181','11_wide_score_above','01_interactive','player_color_181_wide_score_above_interactive.c26') &&
-f File::Spec->catfile($repo,'examples','04_player_color_181','12_wide_score_below','01_interactive','player_color_181_wide_score_below_interactive.c26') &&
index(slurp(File::Spec->catfile($test,'vcs_examples_build.pl')),
   q{$file eq 'score.c26' || $file eq 'wide_score.c26'})>=0 &&
-f File::Spec->catfile($repo,'test','fixtures','vcs_examples','05_wide_score','reference_stella_7.0.png')
   or die "widely spaced score example, tests, or oracle are incomplete
";
my $bank_example_make=slurp(File::Spec->catfile($repo,'examples','09_bankswitching','01_diagnostic','Makefile'));
index($bank_example_make,'-DVCS_NO_DEFAULT_ROM')<0 &&
index($bank_example_make,'$(VCS_DIR)/vcs.cfg')>=0 &&
index($bank_example_make,'$(VCS_DIR)/vcs_8k_f8.cfg')<0
   or die "public bank diagnostics must build from C26 topology through reduced vcs.cfg\n";
for my $profile (qw(vcs_2k.c26 vcs_4k.c26 vcs_8k_f8.c26 vcs_16k_f6.c26 vcs_32k_f4.c26 vcs_8k_f8sc.c26 vcs_16k_f6sc.c26 vcs_32k_f4sc.c26 vcs_direct_8k.c26)) {
   -f File::Spec->catfile($repo,'libraries','vcs',$profile)
      or die "missing migrated C26 cartridge profile $profile\n";
   index($top_make,"libraries/vcs/$profile")>=0
      or die "$profile is not installed/uninstalled by the top-level Makefile\n";
}
-f File::Spec->catfile($repo,'libraries','vcs','vcs.cfg') &&
index($top_make,'libraries/vcs/vcs.cfg')>=0
   or die "reduced vcs.cfg is missing from installation coverage\n";
for my $name (qw(missing size start type)) {
   my $body=slurp(File::Spec->catfile($test,"e2e_mem_region_cfg_${name}_mismatch.c26"));
   index($body,'expectlinkfail')<0
      or die "stale cfg $name regression still expects C26 allocator metadata to lose\n";
}
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
$bankswitching =~ /placement modes assign pinned components first in stable input order/ &&
$bankswitching =~ /15 bytes and 25 extra cycles\s+for JSR, or 8 bytes and 6 extra cycles\s+for JMP/ &&
index($bankswitching,'RODATA.bank1.__vcsc_object$level_table')>=0
   or die "bankswitching plan lost completed deterministic automatic placement\n";
-f File::Spec->catfile($test,'linker_banked_auto_placement.pl')
   or die "automatic bank-placement regression test is missing\n";
index($bankswitching,'[x] 29. Improve automatic placement heuristics without changing semantics.')>=0 &&
index($bankswitching,'`optimized` as the default')>=0 &&
index($bankswitching,'`simple` as an explicit stable')>=0 &&
index($bankswitching,'`--explain-bank-placement`')>=0 &&
index($bankswitching,'refuses any cut')>=0 &&
index($bankswitching,'weighted hardware-return depth')>=0
   or die "bankswitching plan lost completed placement optimization and stack guard\n";
-f File::Spec->catfile($test,'linker_banked_placement_modes.pl')
   or die "placement-mode optimization regression test is missing\n";
index($bankswitching,'30. Mapper-family policy gate — not an unfinished implementation item.')>=0 &&
$bankswitching =~ /There is no\s+current action while no concrete program requires unsupported hardware/
   or die "bankswitching plan no longer distinguishes the mapper-family policy gate from implementation work\n";
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
$bankswitching =~ /orders unpinned components by decreasing byte size/
   or die "bankswitching plan lost generic startup-main or constrained automatic placement\n";
index($bankswitching,q{begin allocatable ROM at})>=0 &&
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
my $context=slurp(File::Spec->catfile($repo,'...','context.txt'));
my $roadmap=slurp(File::Spec->catfile($repo,'...','roadmap.txt'));
my $ram_roadmap=slurp(File::Spec->catfile($repo,'...','ram_optimization.txt'));
index($context,'Active workstream: `.../roadmap.txt`.')>=0 &&
index($context,'The focused RAM-optimization roadmap is complete through its final ordinary-application')>=0 &&
index($context,'RAM-roadmap items 0-14 are complete.')>=0 &&
index($context,'The RAM optimization workstream is complete.')>=0 &&
index($context,'The text after the comma is mandatory.')>=0 &&
index($context,'Main-roadmap item 23 remains an earlier')>=0 &&
index($context,'item 28 is active')>=0 &&
index($context,'faithful_legacy_multisprite')>=0 &&
index($context,'26-byte `A..Z` application window')>=0 &&
length($context) <= 100 * 1024
   or die "compact context lost its user-directed item-28 multisprite pointer, completed RAM/assembly closeout, history-title policy, skipped item-23 note, or size ceiling\n";
$ram_roadmap =~ /^\[x\] 0\. Add authoritative RAM-accounting fixtures before optimizing\./m &&
$ram_roadmap =~ /^\[x\] 1\. Add lifetime overlay between separate expressions inside one function\./m &&
$ram_roadmap =~ /^\[x\] 2\. Stop duplicating scratch groups for repeated expansions of one inline/m &&
$ram_roadmap =~ /^\[x\] 3\. Improve compact lowering for simple byte state updates\./m &&
$ram_roadmap =~ /^\[x\] 4\. Make `install_frames\(\)` ordinary VCSC and establish a minimal-assembly/m &&
$ram_roadmap =~ /^\[x\] 5a\. Separate hard page containment from explicit power-of-two alignment,/m &&
$ram_roadmap =~ /^\[x\] 4a\. Recover high-level frame-installation ROM through the existing optimizer/m &&
$ram_roadmap =~ /^\[x\] 5\. Overlay scratch across frame phases when contracts prove the lifetimes do/m &&
$ram_roadmap =~ /^\[x\] 6\. Reduce the gallery's persistent bookkeeping without changing behavior\./m &&
$ram_roadmap =~ /^\[x\] 7\. Reduce hardware-stack reservation by measurement, not by blanket inlining\./m &&
$ram_roadmap =~ /^\[x\] 8\. Remeasure the animated gallery on the existing P0\/P1\/Ball renderer after/m &&
$ram_roadmap =~ /^\[x\] 9\. Replace or redesign `game_object_masks` using an official-opcode direct-/m &&
$ram_roadmap =~ /^\[x\] 10\. Investigate a more compact Ball\/object schedule without removing Ball\./m &&
$ram_roadmap =~ /^\[x\] 10a\. Propagate the delayed-Ball row-boundary repair and RAM cleanup through/m &&
$ram_roadmap =~ /^\[x\] 11\. Only if a generally useful capability split is still justified, create a/m &&
$ram_roadmap =~ /^\[x\] 12\. Only if a generally useful capability split is still justified, create an/m &&
$ram_roadmap =~ /^\[x\] 13\. Establish completion gates and choose the retained architecture\./m &&
$ram_roadmap =~ /^\[x\] 14\. Remove remaining ordinary application assembly recorded by the example allowlist\./m &&
-f File::Spec->catfile($repo,qw(test fixtures vcs_animated_gallery_ram_accounting golden.json))
   or die "RAM-optimization roadmap, measured optimizer follow-up, or authoritative accounting fixture is stale\n";
$roadmap !~ /^\s*\[ \]\s+22i4d\./m
   or die "obsolete active roadmap item 22i4d was restored\n";
$roadmap =~ /^Current next action: 28\b/m &&
$roadmap =~ /^\[x\] 27\. Inventory and define the source-integration contract/m &&
$roadmap =~ /^\[ \] 28\. Port and verify the minimal unbanked, non-Superchip multisprite profile/m &&
index($roadmap,'faithful fixed baseline complete')>=0 &&
index($roadmap,'1472/4090 ROM bytes')>=0 &&
index($roadmap,'122 state +')>=0 &&
index($roadmap,'6 hardware-stack = 128/128 RIOT-RAM bytes')>=0
   or die "main roadmap lost the active item-28 faithful multisprite baseline or task-27 completion\n";
$roadmap =~ /^\s*\[x\] 22i4b5\./m
   or die "two-plus-two score roadmap leaf is not complete\n";
$roadmap =~ /^\s*\[x\] 22i4b6\./m
   or die "composition-matrix roadmap leaf is not complete\n";
$roadmap =~ /^\s*\[x\] 22i4c1\./m
   or die "public composition-matrix roadmap leaf is not complete\n";
$roadmap =~ /^\[x\] 24\. Add a widely spaced six-glyph score-display variant\./m
   or die "widely spaced score roadmap item is not complete\n";
$roadmap =~ /^\[x\] 29\. Add general 8K-and-larger Atari cartridge bankswitching/m &&
$roadmap =~ /^\[x\] 30\. Add Superchip cartridge RAM support/m
   or die "main roadmap lost completed banking or Superchip status\n";
$roadmap =~ /^\s*\[x\] 22i4\./m
   or die "visible-component roadmap gate is not complete\n";
$roadmap =~ /^\[x\] 34\./m
   or die "animated-sprite roadmap item is not complete\n";
$roadmap !~ /Task 22 remains the active roadmap family/
   or die "stale task-22 active-roadmap summary was restored\n";

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

for my $required (qw(
   libraries/vcs/superchip.c26
   libraries/vcs/vcs_8k_f8sc.c26
   libraries/vcs/vcs_16k_f6sc.c26
   libraries/vcs/vcs_32k_f4sc.c26
   libraries/vcs/vcs_8k_f8sc.cfg
   libraries/vcs/vcs_16k_f6sc.cfg
   libraries/vcs/vcs_32k_f4sc.cfg
)) {
   -f File::Spec->catfile($repo,split('/', $required))
      or die "missing required Superchip file $required\n";
}
my $superchip_header=slurp(File::Spec->catfile($repo,'libraries','vcs','superchip.c26'));
index($superchip_header,'mem superchip')>=0 &&
index($superchip_header,'$read_start:0xF080')>=0 &&
index($superchip_header,'$write_start:0xF000')>=0 &&
index($superchip_header,'$size:0x0080')>=0
   or die "superchip.c26 lost the allocatable split-memory region\n";
index($superchip_header,'superchip_ram')<0
   or die "superchip.c26 must not publish a whole-window alias\n";
my $superchip_diagnostic=slurp(File::Spec->catfile($repo,'libraries','vcs','bankswitching_diagnostic_suite.c26'));
index($superchip_diagnostic,'superchip uint8_t diagnostic_superchip_bss_head;')>=0 &&
index($superchip_diagnostic,'superchip uint8_t diagnostic_superchip_data_head := 0x5A;')>=0 &&
index($superchip_diagnostic,'superchip uint8_t diagnostic_superchip_bss[124];')>=0 &&
index($superchip_diagnostic,'superchip uint8_t diagnostic_superchip_data_tail := 0xA5;')>=0 &&
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

my $snapshot_keys=slurp(File::Spec->catfile($test,'stella_snapshot_keys.pl'));
index($snapshot_keys,"'--reset'")>=0 &&
index($snapshot_keys,"function_keycode('F2')")>=0
   or die "Stella bank diagnostics lost console-reset lifecycle coverage\n";
index($bankswitching,'[x] 11. Add explicit-binding Superchip profiles.')>=0
   or die "explicit-binding Superchip roadmap item is not complete\n";
index($top_make,'libraries/vcs/vcs_8k_f8sc.c26')>=0 &&
index($top_make,'libraries/vcs/vcs_8k_f8sc.cfg')>=0 &&
index($top_make,'libraries/vcs/superchip.c26')>=0
   or die "Superchip profiles/header are not installed and uninstalled\n";

print "source tree hygiene ok\n";
