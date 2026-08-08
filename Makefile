PREFIX ?= /opt/vcsc
DESTDIR ?=
BINDIR ?= $(PREFIX)/bin
LIBDIR ?= $(PREFIX)/lib
INCLUDEDIR ?= $(PREFIX)/include
DATADIR ?= $(PREFIX)/share
CFGDIR ?= $(DATADIR)/cfg
PACKAGE_PREFIX ?= /opt/vcsc
PACKAGE_STAGING ?= $(CURDIR)/pkgroot
INSTALLCHECK_STAGING ?= $(CURDIR)/.installcheck-root
DOXYGEN ?= doxygen
STELLA ?= stella
STELLA_BANK_TEST_TMP ?= $(CURDIR)/.stella-bank-test
STELLA_RENDERER_BANK_TEST_TMP ?= $(CURDIR)/.stella-renderer-bank-test
STELLA_WIDE_SCORE_TEST_TMP ?= $(CURDIR)/.stella-wide-score-test
STELLA_PLAYER_COLOR_192_TEST_TMP ?= $(CURDIR)/.stella-player-color-192-test
STELLA_FAITHFUL_MULTISPRITE_TEST_TMP ?= $(CURDIR)/.stella-faithful-multisprite-test

all: test

.NOTPARALLEL:

compiler/vcsc-cc1:
	@$(MAKE) --no-print-directory -C ./compiler vcsc-cc1

assembler/vcsc-as:
	@$(MAKE) --no-print-directory -C ./assembler vcsc-as

archiver/vcsc-ar:
	@$(MAKE) --no-print-directory -C ./archiver vcsc-ar

tools: clean
	@$(MAKE) --no-print-directory -C ./assembler all
	@$(MAKE) --no-print-directory -C ./linker all
	@$(MAKE) --no-print-directory -C ./archiver all
	@$(MAKE) --no-print-directory -C ./libraries/runtime all
	@$(MAKE) --no-print-directory -C ./compiler vcsc-cc1
	@$(MAKE) --no-print-directory -C ./simulator all
	@$(MAKE) --no-print-directory -C ./driver all

.PHONY: exam

exam:
	@for each in $$(find examples -type f -name Makefile \
		| sed 's|/Makefile$$||' \
		| sort); do \
		echo ==== $$each; \
		$(MAKE) -C "$$each" clean && \
		$(MAKE) -C "$$each" || exit $$?; \
		for bin in $$(find "$$each" -type f -name '*.bin' | sort); do \
			stella "$$bin"; \
		done; \
	done
#	stella test/oracles/pristine_basic_v1.9_playercolors/faithful_legacy_playercolors.bin

clean:
	rm -rf $(STELLA_BANK_TEST_TMP) $(STELLA_RENDERER_BANK_TEST_TMP) $(STELLA_WIDE_SCORE_TEST_TMP) $(STELLA_PLAYER_COLOR_192_TEST_TMP) $(STELLA_FAITHFUL_MULTISPRITE_TEST_TMP)
	@$(MAKE) --no-print-directory -C ./assembler clean
	@$(MAKE) --no-print-directory -C ./linker clean
	@$(MAKE) --no-print-directory -C ./archiver clean
	@$(MAKE) --no-print-directory -C ./libraries/runtime clean
	@$(MAKE) --no-print-directory -C ./compiler clean
	@$(MAKE) --no-print-directory -C ./simulator clean
	@$(MAKE) --no-print-directory -C ./driver clean

docs:
	mkdir -p doxygen
	$(DOXYGEN) Doxyfile

install: tools install-core

install-core:
	@$(MAKE) --no-print-directory -C ./assembler install DESTDIR="$(DESTDIR)" BINDIR="$(BINDIR)" CFGDIR="$(CFGDIR)"
	@$(MAKE) --no-print-directory -C ./linker install DESTDIR="$(DESTDIR)" BINDIR="$(BINDIR)"
	@$(MAKE) --no-print-directory -C ./archiver install DESTDIR="$(DESTDIR)" BINDIR="$(BINDIR)"
	@$(MAKE) --no-print-directory -C ./compiler install DESTDIR="$(DESTDIR)" BINDIR="$(BINDIR)"
	@$(MAKE) --no-print-directory -C ./simulator install DESTDIR="$(DESTDIR)" BINDIR="$(BINDIR)"
	@$(MAKE) --no-print-directory -C ./driver install DESTDIR="$(DESTDIR)" BINDIR="$(BINDIR)"
	install -d $(DESTDIR)$(BINDIR)
	@$(MAKE) --no-print-directory -C ./libraries/runtime install DESTDIR="$(DESTDIR)" LIBDIR="$(LIBDIR)" INCLUDEDIR="$(INCLUDEDIR)" DATADIR="$(DATADIR)"
	@$(MAKE) --no-print-directory install-data DESTDIR="$(DESTDIR)" DATADIR="$(DATADIR)"

install-data:
	install -d $(DESTDIR)$(DATADIR)/vcs
	install -m 0644 libraries/LICENSE.txt $(DESTDIR)$(DATADIR)/vcs/LICENSE.txt
	install -m 0644 libraries/vcs/README.md $(DESTDIR)$(DATADIR)/vcs/README.md
	install -m 0644 libraries/vcs/LEGACY_RENDERER_CONVERSION.md $(DESTDIR)$(DATADIR)/vcs/LEGACY_RENDERER_CONVERSION.md
	install -m 0644 libraries/vcs/color_ntsc.c26 $(DESTDIR)$(DATADIR)/vcs/color_ntsc.c26
	install -m 0644 libraries/vcs/bankswitching_diagnostic_suite.c26 $(DESTDIR)$(DATADIR)/vcs/bankswitching_diagnostic_suite.c26
	install -m 0644 libraries/vcs/frame_ntsc.c26 $(DESTDIR)$(DATADIR)/vcs/frame_ntsc.c26
	install -m 0644 libraries/vcs/playfield.c26 $(DESTDIR)$(DATADIR)/vcs/playfield.c26
	install -m 0644 libraries/vcs/riot.c26 $(DESTDIR)$(DATADIR)/vcs/riot.c26
	install -m 0644 libraries/vcs/six_glyph_component.c26 $(DESTDIR)$(DATADIR)/vcs/six_glyph_component.c26
	install -m 0644 libraries/vcs/six_glyph_wide_component.c26 $(DESTDIR)$(DATADIR)/vcs/six_glyph_wide_component.c26
	install -m 0644 libraries/vcs/six_glyph_left_component.c26 $(DESTDIR)$(DATADIR)/vcs/six_glyph_left_component.c26
	install -m 0644 libraries/vcs/six_glyph_right_component.c26 $(DESTDIR)$(DATADIR)/vcs/six_glyph_right_component.c26
	install -m 0644 libraries/vcs/six_glyph_color_component.c26 $(DESTDIR)$(DATADIR)/vcs/six_glyph_color_component.c26
	install -m 0644 libraries/vcs/two_plus_two_score_component.c26 $(DESTDIR)$(DATADIR)/vcs/two_plus_two_score_component.c26
	install -m 0644 libraries/vcs/two_plus_two_score_support.c26 $(DESTDIR)$(DATADIR)/vcs/two_plus_two_score_support.c26
	install -m 0644 libraries/vcs/sound_ntsc.c26 $(DESTDIR)$(DATADIR)/vcs/sound_ntsc.c26
	install -m 0644 libraries/vcs/superchip.c26 $(DESTDIR)$(DATADIR)/vcs/superchip.c26
	install -m 0644 libraries/vcs/tia.c26 $(DESTDIR)$(DATADIR)/vcs/tia.c26
	install -m 0644 libraries/vcs/vcs.c26 $(DESTDIR)$(DATADIR)/vcs/vcs.c26
	install -m 0644 libraries/vcs/vcs.cfg $(DESTDIR)$(DATADIR)/vcs/vcs.cfg
	install -m 0644 libraries/vcs/vcs_2k.c26 $(DESTDIR)$(DATADIR)/vcs/vcs_2k.c26
	install -m 0644 libraries/vcs/vcs_4k.c26 $(DESTDIR)$(DATADIR)/vcs/vcs_4k.c26
	install -m 0644 libraries/vcs/vcs_8k_f8.c26 $(DESTDIR)$(DATADIR)/vcs/vcs_8k_f8.c26
	install -m 0644 libraries/vcs/vcs_16k_f6.c26 $(DESTDIR)$(DATADIR)/vcs/vcs_16k_f6.c26
	install -m 0644 libraries/vcs/vcs_32k_f4.c26 $(DESTDIR)$(DATADIR)/vcs/vcs_32k_f4.c26
	install -m 0644 libraries/vcs/vcs_8k_f8sc.c26 $(DESTDIR)$(DATADIR)/vcs/vcs_8k_f8sc.c26
	install -m 0644 libraries/vcs/vcs_16k_f6sc.c26 $(DESTDIR)$(DATADIR)/vcs/vcs_16k_f6sc.c26
	install -m 0644 libraries/vcs/vcs_32k_f4sc.c26 $(DESTDIR)$(DATADIR)/vcs/vcs_32k_f4sc.c26
	install -m 0644 libraries/vcs/vcs_direct_8k.c26 $(DESTDIR)$(DATADIR)/vcs/vcs_direct_8k.c26
	install -m 0644 libraries/vcs/vcs_4k.cfg $(DESTDIR)$(DATADIR)/vcs/vcs_4k.cfg
	install -m 0644 libraries/vcs/vcs_8k_f8.cfg $(DESTDIR)$(DATADIR)/vcs/vcs_8k_f8.cfg
	install -m 0644 libraries/vcs/vcs_16k_f6.cfg $(DESTDIR)$(DATADIR)/vcs/vcs_16k_f6.cfg
	install -m 0644 libraries/vcs/vcs_32k_f4.cfg $(DESTDIR)$(DATADIR)/vcs/vcs_32k_f4.cfg
	install -m 0644 libraries/vcs/vcs_8k_f8sc.cfg $(DESTDIR)$(DATADIR)/vcs/vcs_8k_f8sc.cfg
	install -m 0644 libraries/vcs/vcs_16k_f6sc.cfg $(DESTDIR)$(DATADIR)/vcs/vcs_16k_f6sc.cfg
	install -m 0644 libraries/vcs/vcs_32k_f4sc.cfg $(DESTDIR)$(DATADIR)/vcs/vcs_32k_f4sc.cfg
	install -d $(DESTDIR)$(DATADIR)/vcs/renderers
	install -m 0644 libraries/vcs/renderers/COMPONENT_CONVERSION.md \
	  $(DESTDIR)$(DATADIR)/vcs/renderers/COMPONENT_CONVERSION.md
	install -d $(DESTDIR)$(DATADIR)/vcs/renderers/faithful_legacy_playercolors
	install -m 0644 libraries/vcs/renderers/faithful_legacy_playercolors/README.md \
	  libraries/vcs/renderers/faithful_legacy_playercolors/faithful_legacy_playercolors.c26 \
	  libraries/vcs/renderers/faithful_legacy_playercolors/faithful_legacy_playercolors_macros.inc \
	  libraries/vcs/renderers/faithful_legacy_playercolors/faithful_legacy_playercolors_reference.s26 \
	  libraries/vcs/renderers/faithful_legacy_playercolors/faithful_legacy_playercolors.cfg \
	  $(DESTDIR)$(DATADIR)/vcs/renderers/faithful_legacy_playercolors/
	install -d $(DESTDIR)$(DATADIR)/vcs/renderers/faithful_legacy_multisprite
	install -m 0644 libraries/vcs/renderers/faithful_legacy_multisprite/README.md \
	  libraries/vcs/renderers/faithful_legacy_multisprite/faithful_legacy_multisprite.c26 \
	  libraries/vcs/renderers/faithful_legacy_multisprite/faithful_legacy_multisprite_macros.inc \
	  libraries/vcs/renderers/faithful_legacy_multisprite/faithful_legacy_multisprite_renderer.s26 \
	  libraries/vcs/renderers/faithful_legacy_multisprite/faithful_legacy_multisprite_startup.s26 \
	  libraries/vcs/renderers/faithful_legacy_multisprite/faithful_legacy_multisprite.cfg \
	  $(DESTDIR)$(DATADIR)/vcs/renderers/faithful_legacy_multisprite/
	install -d $(DESTDIR)$(DATADIR)/vcs/renderers/all_five
	install -m 0644 libraries/vcs/renderers/all_five/README.md \
	  libraries/vcs/renderers/all_five/all_five.c26 \
	  $(DESTDIR)$(DATADIR)/vcs/renderers/all_five/
	install -d $(DESTDIR)$(DATADIR)/vcs/renderers/all_five_181_unofficial
	install -m 0644 libraries/vcs/renderers/all_five_181_unofficial/README.md \
	  libraries/vcs/renderers/all_five_181_unofficial/all_five_181_unofficial.c26 \
	  $(DESTDIR)$(DATADIR)/vcs/renderers/all_five_181_unofficial/
	install -d $(DESTDIR)$(DATADIR)/vcs/renderers/player_color_181
	install -m 0644 libraries/vcs/renderers/player_color_181/README.md \
	  libraries/vcs/renderers/player_color_181/player_color_181.c26 \
	  $(DESTDIR)$(DATADIR)/vcs/renderers/player_color_181/
	install -d $(DESTDIR)$(DATADIR)/vcs/renderers/player_color_181_unofficial
	install -m 0644 libraries/vcs/renderers/player_color_181_unofficial/README.md \
	  libraries/vcs/renderers/player_color_181_unofficial/player_color_181_unofficial.c26 \
	  $(DESTDIR)$(DATADIR)/vcs/renderers/player_color_181_unofficial/
	install -d $(DESTDIR)$(DATADIR)/vcs/renderers/player_color_192
	install -m 0644 libraries/vcs/renderers/player_color_192/README.md \
	  libraries/vcs/renderers/player_color_192/player_color_192.c26 \
	  $(DESTDIR)$(DATADIR)/vcs/renderers/player_color_192/
	install -d $(DESTDIR)$(DATADIR)/vcs/renderers/poison_debug_score
	install -m 0644 libraries/vcs/renderers/poison_debug_score/README.md \
	  libraries/vcs/renderers/poison_debug_score/poison_debug_score.c26 \
	  $(DESTDIR)$(DATADIR)/vcs/renderers/poison_debug_score/
	install -d $(DESTDIR)$(DATADIR)/vcs/renderers/standard_4k_ntsc
	install -m 0644 libraries/vcs/renderers/standard_4k_ntsc/README.md \
	  libraries/vcs/renderers/standard_4k_ntsc/DCP_LEGALIZATION.md \
	  libraries/vcs/renderers/standard_4k_ntsc/UNOFFICIAL_OPCODES.md \
	  libraries/vcs/renderers/standard_4k_ntsc/standard_4k_ntsc.c26 \
	  libraries/vcs/renderers/standard_4k_ntsc/standard_4k_ntsc_renderer.s26 \
	  libraries/vcs/renderers/standard_4k_ntsc/standard_4k_ntsc_macros.inc \
	  libraries/vcs/renderers/standard_4k_ntsc/vcs_standard_4k_ntsc.cfg \
	  $(DESTDIR)$(DATADIR)/vcs/renderers/standard_4k_ntsc/
	install -d $(DESTDIR)$(DATADIR)/vcs/renderers/standard_4k_ntsc_playercolors
	install -m 0644 libraries/vcs/renderers/standard_4k_ntsc_playercolors/README.md \
	  libraries/vcs/renderers/standard_4k_ntsc_playercolors/standard_4k_ntsc_playercolors.c26 \
	  libraries/vcs/renderers/standard_4k_ntsc_playercolors/standard_4k_ntsc_playercolors_renderer.s26 \
	  libraries/vcs/renderers/standard_4k_ntsc_playercolors/standard_4k_ntsc_playercolors_macros.inc \
	  libraries/vcs/renderers/standard_4k_ntsc_playercolors/vcs_standard_4k_ntsc_playercolors.cfg \
	  $(DESTDIR)$(DATADIR)/vcs/renderers/standard_4k_ntsc_playercolors/
	install -d $(DESTDIR)$(DATADIR)/vcs/fonts
	install -m 0644 libraries/vcs/fonts/README.md libraries/vcs/fonts/*.c26 $(DESTDIR)$(DATADIR)/vcs/fonts/
	install -d $(DESTDIR)$(DATADIR)/vcs/legacy-basic-renderers
	install -m 0644 libraries/vcs/legacy-basic-renderers/OMITTED-UPSTREAM-ARTIFACTS.txt $(DESTDIR)$(DATADIR)/vcs/legacy-basic-renderers/OMITTED-UPSTREAM-ARTIFACTS.txt
	install -m 0644 libraries/vcs/legacy-basic-renderers/README.md $(DESTDIR)$(DATADIR)/vcs/legacy-basic-renderers/README.md

uninstall:
	@$(MAKE) --no-print-directory uninstall-data DESTDIR="$(DESTDIR)" DATADIR="$(DATADIR)"
	@$(MAKE) --no-print-directory -C ./libraries/runtime uninstall DESTDIR="$(DESTDIR)" LIBDIR="$(LIBDIR)" INCLUDEDIR="$(INCLUDEDIR)" DATADIR="$(DATADIR)"
	@$(MAKE) --no-print-directory -C ./driver uninstall DESTDIR="$(DESTDIR)" BINDIR="$(BINDIR)"
	@$(MAKE) --no-print-directory -C ./simulator uninstall DESTDIR="$(DESTDIR)" BINDIR="$(BINDIR)"
	@$(MAKE) --no-print-directory -C ./compiler uninstall DESTDIR="$(DESTDIR)" BINDIR="$(BINDIR)"
	@$(MAKE) --no-print-directory -C ./archiver uninstall DESTDIR="$(DESTDIR)" BINDIR="$(BINDIR)"
	@$(MAKE) --no-print-directory -C ./linker uninstall DESTDIR="$(DESTDIR)" BINDIR="$(BINDIR)"
	@$(MAKE) --no-print-directory -C ./assembler uninstall DESTDIR="$(DESTDIR)" BINDIR="$(BINDIR)" CFGDIR="$(CFGDIR)"

uninstall-data:
	rm -f $(DESTDIR)$(DATADIR)/vcs/LICENSE.txt
	rm -f $(DESTDIR)$(DATADIR)/vcs/README.md
	rm -f $(DESTDIR)$(DATADIR)/vcs/LEGACY_RENDERER_CONVERSION.md
	rm -f $(DESTDIR)$(DATADIR)/vcs/color_ntsc.c26
	rm -f $(DESTDIR)$(DATADIR)/vcs/bankswitching_diagnostic_suite.c26
	rm -f $(DESTDIR)$(DATADIR)/vcs/frame_ntsc.c26
	rm -f $(DESTDIR)$(DATADIR)/vcs/playfield.c26
	rm -f $(DESTDIR)$(DATADIR)/vcs/riot.c26
	rm -f $(DESTDIR)$(DATADIR)/vcs/six_glyph_component.c26
	rm -f $(DESTDIR)$(DATADIR)/vcs/six_glyph_wide_component.c26
	rm -f $(DESTDIR)$(DATADIR)/vcs/six_glyph_left_component.c26
	rm -f $(DESTDIR)$(DATADIR)/vcs/six_glyph_right_component.c26
	rm -f $(DESTDIR)$(DATADIR)/vcs/six_glyph_color_component.c26
	rm -f $(DESTDIR)$(DATADIR)/vcs/two_plus_two_score_component.c26
	rm -f $(DESTDIR)$(DATADIR)/vcs/two_plus_two_score_support.c26
	rm -f $(DESTDIR)$(DATADIR)/vcs/sound_ntsc.c26
	rm -f $(DESTDIR)$(DATADIR)/vcs/superchip.c26
	rm -f $(DESTDIR)$(DATADIR)/vcs/tia.c26
	rm -f $(DESTDIR)$(DATADIR)/vcs/vcs.c26
	rm -f $(DESTDIR)$(DATADIR)/vcs/vcs.cfg
	rm -f $(DESTDIR)$(DATADIR)/vcs/vcs_2k.c26
	rm -f $(DESTDIR)$(DATADIR)/vcs/vcs_4k.c26
	rm -f $(DESTDIR)$(DATADIR)/vcs/vcs_8k_f8.c26
	rm -f $(DESTDIR)$(DATADIR)/vcs/vcs_16k_f6.c26
	rm -f $(DESTDIR)$(DATADIR)/vcs/vcs_32k_f4.c26
	rm -f $(DESTDIR)$(DATADIR)/vcs/vcs_8k_f8sc.c26
	rm -f $(DESTDIR)$(DATADIR)/vcs/vcs_16k_f6sc.c26
	rm -f $(DESTDIR)$(DATADIR)/vcs/vcs_32k_f4sc.c26
	rm -f $(DESTDIR)$(DATADIR)/vcs/vcs_direct_8k.c26
	rm -f $(DESTDIR)$(DATADIR)/vcs/vcs_4k.cfg
	rm -f $(DESTDIR)$(DATADIR)/vcs/vcs_8k_f8.cfg
	rm -f $(DESTDIR)$(DATADIR)/vcs/vcs_16k_f6.cfg
	rm -f $(DESTDIR)$(DATADIR)/vcs/vcs_32k_f4.cfg
	rm -f $(DESTDIR)$(DATADIR)/vcs/vcs_8k_f8sc.cfg
	rm -f $(DESTDIR)$(DATADIR)/vcs/vcs_16k_f6sc.cfg
	rm -f $(DESTDIR)$(DATADIR)/vcs/vcs_32k_f4sc.cfg
	rm -f $(DESTDIR)$(DATADIR)/vcs/renderers/COMPONENT_CONVERSION.md
	rm -f $(DESTDIR)$(DATADIR)/vcs/renderers/faithful_legacy_playercolors/README.md
	rm -f $(DESTDIR)$(DATADIR)/vcs/renderers/faithful_legacy_playercolors/faithful_legacy_playercolors.c26
	rm -f $(DESTDIR)$(DATADIR)/vcs/renderers/faithful_legacy_playercolors/faithful_legacy_playercolors_macros.inc
	rm -f $(DESTDIR)$(DATADIR)/vcs/renderers/faithful_legacy_playercolors/faithful_legacy_playercolors_reference.s26
	rm -f $(DESTDIR)$(DATADIR)/vcs/renderers/faithful_legacy_playercolors/faithful_legacy_playercolors.cfg
	rmdir $(DESTDIR)$(DATADIR)/vcs/renderers/faithful_legacy_playercolors 2>/dev/null || true
	rm -f $(DESTDIR)$(DATADIR)/vcs/renderers/faithful_legacy_multisprite/README.md
	rm -f $(DESTDIR)$(DATADIR)/vcs/renderers/faithful_legacy_multisprite/faithful_legacy_multisprite.c26
	rm -f $(DESTDIR)$(DATADIR)/vcs/renderers/faithful_legacy_multisprite/faithful_legacy_multisprite_macros.inc
	rm -f $(DESTDIR)$(DATADIR)/vcs/renderers/faithful_legacy_multisprite/faithful_legacy_multisprite_renderer.s26
	rm -f $(DESTDIR)$(DATADIR)/vcs/renderers/faithful_legacy_multisprite/faithful_legacy_multisprite_startup.s26
	rm -f $(DESTDIR)$(DATADIR)/vcs/renderers/faithful_legacy_multisprite/faithful_legacy_multisprite.cfg
	rmdir $(DESTDIR)$(DATADIR)/vcs/renderers/faithful_legacy_multisprite 2>/dev/null || true
	rm -f $(DESTDIR)$(DATADIR)/vcs/renderers/all_five/README.md
	rm -f $(DESTDIR)$(DATADIR)/vcs/renderers/all_five/all_five.c26
	rmdir $(DESTDIR)$(DATADIR)/vcs/renderers/all_five 2>/dev/null || true
	rm -f $(DESTDIR)$(DATADIR)/vcs/renderers/all_five_181_unofficial/README.md
	rm -f $(DESTDIR)$(DATADIR)/vcs/renderers/all_five_181_unofficial/all_five_181_unofficial.c26
	rmdir $(DESTDIR)$(DATADIR)/vcs/renderers/all_five_181_unofficial 2>/dev/null || true
	rm -f $(DESTDIR)$(DATADIR)/vcs/renderers/player_color_181/README.md
	rm -f $(DESTDIR)$(DATADIR)/vcs/renderers/player_color_181/player_color_181.c26
	rmdir $(DESTDIR)$(DATADIR)/vcs/renderers/player_color_181 2>/dev/null || true
	rm -f $(DESTDIR)$(DATADIR)/vcs/renderers/player_color_181_unofficial/README.md
	rm -f $(DESTDIR)$(DATADIR)/vcs/renderers/player_color_181_unofficial/player_color_181_unofficial.c26
	rmdir $(DESTDIR)$(DATADIR)/vcs/renderers/player_color_181_unofficial 2>/dev/null || true
	rm -f $(DESTDIR)$(DATADIR)/vcs/renderers/player_color_192/README.md
	rm -f $(DESTDIR)$(DATADIR)/vcs/renderers/player_color_192/player_color_192.c26
	rmdir $(DESTDIR)$(DATADIR)/vcs/renderers/player_color_192 2>/dev/null || true
	rm -f $(DESTDIR)$(DATADIR)/vcs/renderers/poison_debug_score/README.md
	rm -f $(DESTDIR)$(DATADIR)/vcs/renderers/poison_debug_score/poison_debug_score.c26
	rmdir $(DESTDIR)$(DATADIR)/vcs/renderers/poison_debug_score 2>/dev/null || true
	rm -f $(DESTDIR)$(DATADIR)/vcs/renderers/standard_4k_ntsc/README.md
	rm -f $(DESTDIR)$(DATADIR)/vcs/renderers/standard_4k_ntsc/DCP_LEGALIZATION.md
	rm -f $(DESTDIR)$(DATADIR)/vcs/renderers/standard_4k_ntsc/UNOFFICIAL_OPCODES.md
	rm -f $(DESTDIR)$(DATADIR)/vcs/renderers/standard_4k_ntsc/standard_4k_ntsc.c26
	rm -f $(DESTDIR)$(DATADIR)/vcs/renderers/standard_4k_ntsc/standard_4k_ntsc_renderer.s26
	rm -f $(DESTDIR)$(DATADIR)/vcs/renderers/standard_4k_ntsc/standard_4k_ntsc_macros.inc
	rm -f $(DESTDIR)$(DATADIR)/vcs/renderers/standard_4k_ntsc/vcs_standard_4k_ntsc.cfg
	rmdir $(DESTDIR)$(DATADIR)/vcs/renderers/standard_4k_ntsc 2>/dev/null || true
	rm -f $(DESTDIR)$(DATADIR)/vcs/renderers/standard_4k_ntsc_playercolors/README.md
	rm -f $(DESTDIR)$(DATADIR)/vcs/renderers/standard_4k_ntsc_playercolors/standard_4k_ntsc_playercolors.c26
	rm -f $(DESTDIR)$(DATADIR)/vcs/renderers/standard_4k_ntsc_playercolors/standard_4k_ntsc_playercolors_renderer.s26
	rm -f $(DESTDIR)$(DATADIR)/vcs/renderers/standard_4k_ntsc_playercolors/standard_4k_ntsc_playercolors_macros.inc
	rm -f $(DESTDIR)$(DATADIR)/vcs/renderers/standard_4k_ntsc_playercolors/vcs_standard_4k_ntsc_playercolors.cfg
	rmdir $(DESTDIR)$(DATADIR)/vcs/renderers/standard_4k_ntsc_playercolors 2>/dev/null || true
	rmdir $(DESTDIR)$(DATADIR)/vcs/renderers 2>/dev/null || true
	rm -f $(DESTDIR)$(DATADIR)/vcs/fonts/README.md
	rm -f $(DESTDIR)$(DATADIR)/vcs/fonts/*.c26
	rmdir $(DESTDIR)$(DATADIR)/vcs/fonts 2>/dev/null || true
	rm -f $(DESTDIR)$(DATADIR)/vcs/legacy-basic-renderers/OMITTED-UPSTREAM-ARTIFACTS.txt
	rm -f $(DESTDIR)$(DATADIR)/vcs/legacy-basic-renderers/README.md

package: tools
	rm -rf $(PACKAGE_STAGING)
	$(MAKE) --no-print-directory install-core DESTDIR="$(PACKAGE_STAGING)" PREFIX="$(PACKAGE_PREFIX)" BINDIR="$(PACKAGE_PREFIX)/bin" LIBDIR="$(PACKAGE_PREFIX)/lib" INCLUDEDIR="$(PACKAGE_PREFIX)/include" DATADIR="$(PACKAGE_PREFIX)/share" CFGDIR="$(PACKAGE_PREFIX)/share/cfg"
	tar -C $(PACKAGE_STAGING) -czf ./vcsc.install.`date -u "+%Y%m%d_%H%M%S"`.tar.gz .

installcheck: tools
	rm -rf $(INSTALLCHECK_STAGING)
	$(MAKE) --no-print-directory install-core DESTDIR="$(INSTALLCHECK_STAGING)" PREFIX="/opt/vcsc" BINDIR="/opt/vcsc/bin" LIBDIR="/opt/vcsc/lib" INCLUDEDIR="/opt/vcsc/include" DATADIR="/opt/vcsc/share" CFGDIR="/opt/vcsc/share/cfg"
	set -e; \
	stage_bin="$(INSTALLCHECK_STAGING)/opt/vcsc/bin"; \
	stage_vcs="$(INSTALLCHECK_STAGING)/opt/vcsc/share/vcs"; \
	test -f "$$stage_vcs/LICENSE.txt"; \
	"$$stage_bin/vcsc" -print-prog-name=cc1 >/dev/null; \
	"$$stage_bin/vcsc" -print-prog-name=as >/dev/null; \
	"$$stage_bin/vcsc" -I "$$stage_vcs" "$(CURDIR)/examples/01_basic/01_blank_screen/blank_screen.c26" -o "$(INSTALLCHECK_STAGING)/blank_screen.bin"; \
	test `wc -c < "$(INSTALLCHECK_STAGING)/blank_screen.bin"` -eq 4096; \
	"$$stage_bin/vcsc" -I "$$stage_vcs" "$(CURDIR)/test/vcs_headers_smoke_test.c26" -o "$(INSTALLCHECK_STAGING)/vcs_headers_smoke.bin"; \
	test `wc -c < "$(INSTALLCHECK_STAGING)/vcs_headers_smoke.bin"` -eq 4096; \
	"$$stage_bin/vcsc" -I "$$stage_vcs" -T "$$stage_vcs/vcs.cfg" "$$stage_vcs/vcs_2k.c26" "$(CURDIR)/examples/01_basic/01_blank_screen/blank_screen.c26" -o "$(INSTALLCHECK_STAGING)/blank_screen_2k.bin"; \
	test `wc -c < "$(INSTALLCHECK_STAGING)/blank_screen_2k.bin"` -eq 2048; \
	test -f "$$stage_vcs/bankswitching_diagnostic_suite.c26"; \
	for profile in vcs.cfg vcs_2k.c26 vcs_4k.c26 vcs_8k_f8.c26 vcs_16k_f6.c26 vcs_32k_f4.c26 vcs_8k_f8sc.c26 vcs_16k_f6sc.c26 vcs_32k_f4sc.c26 vcs_direct_8k.c26; do test -f "$$stage_vcs/$$profile"; done; \
	test -f "$$stage_vcs/vcs_8k_f8.cfg"; \
	"$$stage_bin/vcsc" -I "$(CURDIR)/test" \
	  -DMACHINE_6502_NO_DEFAULT_ZEROPAGE -DMACHINE_6502_NO_DEFAULT_CPUSTACK \
	  -DMACHINE_6502_NO_DEFAULT_RAM -DMACHINE_6502_NO_DEFAULT_ROM \
	  -T "$$stage_vcs/vcs.cfg" \
	  -Map "$(INSTALLCHECK_STAGING)/f8_profile_diagnostic.map" \
	  "$$stage_vcs/vcs_8k_f8.c26" \
	  "$(CURDIR)/test/fixtures/bankswitching/f8_profile_diagnostic.c26" \
	  -o "$(INSTALLCHECK_STAGING)/f8_profile_diagnostic.bin"; \
	test `wc -c < "$(INSTALLCHECK_STAGING)/f8_profile_diagnostic.bin"` -eq 8192; \
	grep -q "bank0.*hotspot=\$$1FF9.*file=\$$00001000.*startup=yes" "$(INSTALLCHECK_STAGING)/f8_profile_diagnostic.map"; \
	grep -q "bank1.*hotspot=\$$1FF8.*file=\$$00000000" "$(INSTALLCHECK_STAGING)/f8_profile_diagnostic.map"; \
	"$$stage_bin/vcsc" -I "$$stage_vcs" \
	  -DMAPPER_BANKS=2 -DSIMULATOR_TEST \
	  -T "$$stage_vcs/vcs.cfg" \
	  -Map "$(INSTALLCHECK_STAGING)/f8_bank_diagnostic.map" \
	  "$$stage_vcs/bankswitching_diagnostic_suite.c26" \
	  -o "$(INSTALLCHECK_STAGING)/f8_bank_diagnostic.bin"; \
	test `wc -c < "$(INSTALLCHECK_STAGING)/f8_bank_diagnostic.bin"` -eq 8192; \
	sim_done=`awk '$$2 == "simulator_done" { print substr($$1, 2); exit }' "$(INSTALLCHECK_STAGING)/f8_bank_diagnostic.map"`; \
	test -n "$$sim_done"; \
	"$$stage_bin/vcsc-sim" -T "$$stage_vcs/vcs_8k_f8.cfg" --start-bank=0 \
	  --stop-pc=0x$$sim_done "$(INSTALLCHECK_STAGING)/f8_bank_diagnostic.bin"; \
	"$$stage_bin/vcsc-sim" -T "$$stage_vcs/vcs_8k_f8.cfg" --start-bank=1 \
	  --stop-pc=0x$$sim_done "$(INSTALLCHECK_STAGING)/f8_bank_diagnostic.bin"; \
	test -f "$$stage_vcs/vcs_16k_f6.cfg"; \
	"$$stage_bin/vcsc" -I "$(CURDIR)/test" \
	  -DMACHINE_6502_NO_DEFAULT_ZEROPAGE -DMACHINE_6502_NO_DEFAULT_CPUSTACK \
	  -DMACHINE_6502_NO_DEFAULT_RAM -DMACHINE_6502_NO_DEFAULT_ROM \
	  -T "$$stage_vcs/vcs.cfg" \
	  -Map "$(INSTALLCHECK_STAGING)/f6_profile_diagnostic.map" \
	  "$$stage_vcs/vcs_16k_f6.c26" \
	  "$(CURDIR)/test/fixtures/bankswitching/f8_profile_diagnostic.c26" \
	  -o "$(INSTALLCHECK_STAGING)/f6_profile_diagnostic.bin"; \
	test `wc -c < "$(INSTALLCHECK_STAGING)/f6_profile_diagnostic.bin"` -eq 16384; \
	grep -q "bank3.*hotspot=\$$1FF6.*file=\$$00000000" "$(INSTALLCHECK_STAGING)/f6_profile_diagnostic.map"; \
	grep -q "bank0.*hotspot=\$$1FF9.*file=\$$00003000.*startup=yes" "$(INSTALLCHECK_STAGING)/f6_profile_diagnostic.map"; \
	test -f "$$stage_vcs/vcs_32k_f4.cfg"; \
	"$$stage_bin/vcsc" -I "$(CURDIR)/test" \
	  -DMACHINE_6502_NO_DEFAULT_ZEROPAGE -DMACHINE_6502_NO_DEFAULT_CPUSTACK \
	  -DMACHINE_6502_NO_DEFAULT_RAM -DMACHINE_6502_NO_DEFAULT_ROM \
	  -T "$$stage_vcs/vcs.cfg" \
	  -Map "$(INSTALLCHECK_STAGING)/f4_profile_diagnostic.map" \
	  "$$stage_vcs/vcs_32k_f4.c26" \
	  "$(CURDIR)/test/fixtures/bankswitching/f8_profile_diagnostic.c26" \
	  -o "$(INSTALLCHECK_STAGING)/f4_profile_diagnostic.bin"; \
	test `wc -c < "$(INSTALLCHECK_STAGING)/f4_profile_diagnostic.bin"` -eq 32768; \
	grep -q "bank7.*hotspot=\$$1FF4.*file=\$$00000000" "$(INSTALLCHECK_STAGING)/f4_profile_diagnostic.map"; \
	grep -q "bank0.*hotspot=\$$1FFB.*file=\$$00007000.*startup=yes" "$(INSTALLCHECK_STAGING)/f4_profile_diagnostic.map"; \
	test -f "$$stage_vcs/superchip.c26"; \
	test -f "$$stage_vcs/vcs_8k_f8sc.cfg"; \
	"$$stage_bin/vcsc" -I "$$stage_vcs" \
	  -DMAPPER_BANKS=2 -DSUPERCHIP_TEST -DSIMULATOR_TEST \
	  -T "$$stage_vcs/vcs.cfg" \
	  -Map "$(INSTALLCHECK_STAGING)/f8sc_bank_diagnostic.map" \
	  "$$stage_vcs/bankswitching_diagnostic_suite.c26" \
	  -o "$(INSTALLCHECK_STAGING)/f8sc_bank_diagnostic.bin"; \
	test `wc -c < "$(INSTALLCHECK_STAGING)/f8sc_bank_diagnostic.bin"` -eq 8192; \
	sc_done=`awk '$$2 == "simulator_done" { print substr($$1, 2); exit }' "$(INSTALLCHECK_STAGING)/f8sc_bank_diagnostic.map"`; \
	sc_failure=`awk '$$2 == "failure" { print substr($$1, 2); exit }' "$(INSTALLCHECK_STAGING)/f8sc_bank_diagnostic.map"`; \
	test -n "$$sc_done"; test -n "$$sc_failure"; \
	grep -q "policy=every-reset bss=zero data=copy-through-write-alias" "$(INSTALLCHECK_STAGING)/f8sc_bank_diagnostic.map"; \
	"$$stage_bin/vcsc-sim" --help | grep -q -- "--reset-on-pc=ADDR"; \
	"$$stage_bin/vcsc-sim" --help | grep -q -- "--split-fill=BYTE"; \
	"$$stage_bin/vcsc-sim" -T "$$stage_vcs/vcs_8k_f8sc.cfg" --start-bank=0 \
	  --split-fill=0xA7 --reset-on-pc=0x$$sc_done --stop-pc=0x$$sc_done \
	  --dump-on-stop "$(INSTALLCHECK_STAGING)/f8sc_bank_diagnostic.bin" \
	  > "$(INSTALLCHECK_STAGING)/f8sc_bank_diagnostic.dump"; \
	perl -e '$$w=hex(shift); while (<>) { next unless /^:([0-9A-Fa-f]{2})([0-9A-Fa-f]{4})00([0-9A-Fa-f]*)/; ($$n,$$a,$$d)=(hex($$1),hex($$2),$$3); if ($$w >= $$a && $$w < $$a+$$n) { exit(hex(substr($$d,2*($$w-$$a),2)) == 0 ? 0 : 1); } } exit 2' \
	  "$$sc_failure" "$(INSTALLCHECK_STAGING)/f8sc_bank_diagnostic.dump"; \
	"$$stage_bin/vcsc" -I "$$stage_vcs" -I "$(CURDIR)/examples/01_basic/03_score" \
	  -T "$$stage_vcs/vcs.cfg" \
	  "$(CURDIR)/examples/01_basic/03_score/score.c26" \
	  -o "$(INSTALLCHECK_STAGING)/score.bin"; \
	test `wc -c < "$(INSTALLCHECK_STAGING)/score.bin"` -eq 2048; \
	"$$stage_bin/vcsc" -I "$$stage_vcs" -I "$(CURDIR)/examples/01_basic/05_wide_score" \
	  -T "$$stage_vcs/vcs.cfg" \
	  "$(CURDIR)/examples/01_basic/05_wide_score/wide_score.c26" \
	  -o "$(INSTALLCHECK_STAGING)/wide_score.bin"; \
	test `wc -c < "$(INSTALLCHECK_STAGING)/wide_score.bin"` -eq 2048; \
	"$$stage_bin/vcsc" -I "$$stage_vcs" -Wa,--illegals \
	  "$(CURDIR)/examples/01_basic/04_fingerprint/fingerprint.c26" \
	  -o "$(INSTALLCHECK_STAGING)/fingerprint.bin"; \
	test `wc -c < "$(INSTALLCHECK_STAGING)/fingerprint.bin"` -eq 4096; \
	test -f "$$stage_vcs/color_ntsc.c26"; \
	test -f "$$stage_vcs/frame_ntsc.c26"; \
	test -f "$$stage_vcs/six_glyph_component.c26"; \
	test -f "$$stage_vcs/six_glyph_wide_component.c26"; \
	test -f "$$stage_vcs/six_glyph_left_component.c26"; \
	test -f "$$stage_vcs/six_glyph_right_component.c26"; \
	test -f "$$stage_vcs/six_glyph_color_component.c26"; \
	test -f "$$stage_vcs/two_plus_two_score_component.c26"; \
	test -f "$$stage_vcs/two_plus_two_score_support.c26"; \
	test ! -e "$$stage_vcs/six_glyph_display.c26"; \
	"$$stage_bin/vcsc" -I "$$stage_vcs" \
	  "$(CURDIR)/test/fixtures/six_glyph_component/two_instances.c26" \
	  -o "$(INSTALLCHECK_STAGING)/six_glyph_component.bin"; \
	test `wc -c < "$(INSTALLCHECK_STAGING)/six_glyph_component.bin"` -eq 4096; \
	"$$stage_bin/vcsc" -I "$$stage_vcs" \
	  "$(CURDIR)/test/fixtures/vcs_examples/05_wide_score/golden.c26" \
	  -o "$(INSTALLCHECK_STAGING)/six_glyph_wide_component.bin"; \
	test `wc -c < "$(INSTALLCHECK_STAGING)/six_glyph_wide_component.bin"` -eq 4096; \
	"$$stage_bin/vcsc" -I "$$stage_vcs" \
	  "$(CURDIR)/test/fixtures/six_glyph_component/two_instances_reversed.c26" \
	  -o "$(INSTALLCHECK_STAGING)/six_glyph_component_reversed.bin"; \
	test `wc -c < "$(INSTALLCHECK_STAGING)/six_glyph_component_reversed.bin"` -eq 4096; \
	"$$stage_bin/vcsc" -I "$$stage_vcs" \
	  "$(CURDIR)/test/fixtures/two_plus_two_score/two_instances_motion.c26" \
	  -o "$(INSTALLCHECK_STAGING)/two_plus_two_score.bin"; \
	test `wc -c < "$(INSTALLCHECK_STAGING)/two_plus_two_score.bin"` -eq 4096; \
	test -f "$$stage_vcs/playfield.c26"; \
	test -f "$$stage_vcs/sound_ntsc.c26"; \
	test -f "$$stage_vcs/renderers/COMPONENT_CONVERSION.md"; \
	test -f "$$stage_vcs/renderers/faithful_legacy_playercolors/README.md"; \
	test -f "$$stage_vcs/renderers/faithful_legacy_playercolors/faithful_legacy_playercolors.c26"; \
	test -f "$$stage_vcs/renderers/faithful_legacy_playercolors/faithful_legacy_playercolors_macros.inc"; \
	test -f "$$stage_vcs/renderers/faithful_legacy_playercolors/faithful_legacy_playercolors_reference.s26"; \
	test -f "$$stage_vcs/renderers/faithful_legacy_playercolors/faithful_legacy_playercolors.cfg"; \
	"$$stage_bin/vcsc" -I "$$stage_vcs" \
	  "$(CURDIR)/examples/03_player_color_192/01_interactive/player_color_192_interactive.c26" \
	  -o "$(INSTALLCHECK_STAGING)/player_color_192_interactive.bin"; \
	test `wc -c < "$(INSTALLCHECK_STAGING)/player_color_192_interactive.bin"` -eq 4096; \
	"$$stage_bin/vcsc" -I "$$stage_vcs" \
	  "$(CURDIR)/examples/03_player_color_192/02_animated_sprites/player_color_192_animated_sprites.c26" \
	  -o "$(INSTALLCHECK_STAGING)/player_color_192_animated_sprites.bin"; \
	test `wc -c < "$(INSTALLCHECK_STAGING)/player_color_192_animated_sprites.bin"` -eq 4096; \
	"$$stage_bin/vcsc" -I "$$stage_vcs" -Wa,--illegals \
	  -T "$$stage_vcs/renderers/faithful_legacy_playercolors/faithful_legacy_playercolors.cfg" \
	  "$(CURDIR)/examples/02_faithful_legacy_playercolors/01_interactive/faithful_legacy_playercolors_interactive.c26" \
	  -o "$(INSTALLCHECK_STAGING)/faithful_legacy_playercolors_interactive.bin"; \
	test `wc -c < "$(INSTALLCHECK_STAGING)/faithful_legacy_playercolors_interactive.bin"` -eq 4096; \
	test -f "$$stage_vcs/renderers/faithful_legacy_multisprite/README.md"; \
	test -f "$$stage_vcs/renderers/faithful_legacy_multisprite/faithful_legacy_multisprite.c26"; \
	test -f "$$stage_vcs/renderers/faithful_legacy_multisprite/faithful_legacy_multisprite_macros.inc"; \
	test -f "$$stage_vcs/renderers/faithful_legacy_multisprite/faithful_legacy_multisprite_renderer.s26"; \
	test -f "$$stage_vcs/renderers/faithful_legacy_multisprite/faithful_legacy_multisprite_startup.s26"; \
	test -f "$$stage_vcs/renderers/faithful_legacy_multisprite/faithful_legacy_multisprite.cfg"; \
	"$$stage_bin/vcsc" -nostdlib -I "$$stage_vcs" -Wa,--illegals \
	  -T "$$stage_vcs/renderers/faithful_legacy_multisprite/faithful_legacy_multisprite.cfg" \
	  "$(CURDIR)/examples/10_faithful_legacy_multisprite/01_diagnostic/faithful_legacy_multisprite_diagnostic.c26" \
	  "$(CURDIR)/examples/10_faithful_legacy_multisprite/01_diagnostic/faithful_legacy_multisprite_diagnostic_data.s26" \
	  "$$stage_vcs/renderers/faithful_legacy_multisprite/faithful_legacy_multisprite_renderer.s26" \
	  "$$stage_vcs/renderers/faithful_legacy_multisprite/faithful_legacy_multisprite_startup.s26" \
	  -o "$(INSTALLCHECK_STAGING)/faithful_legacy_multisprite_diagnostic.bin"; \
	test `wc -c < "$(INSTALLCHECK_STAGING)/faithful_legacy_multisprite_diagnostic.bin"` -eq 4096; \
	test -f "$$stage_vcs/renderers/all_five/README.md"; \
	test -f "$$stage_vcs/renderers/all_five/all_five.c26"; \
	"$$stage_bin/vcsc" -I "$$stage_vcs" \
	  "$(CURDIR)/test/fixtures/all_five_181/smoke.c26" \
	  -o "$(INSTALLCHECK_STAGING)/all_five_181.bin"; \
	test `wc -c < "$(INSTALLCHECK_STAGING)/all_five_181.bin"` -eq 4096; \
	for fixture in static_score_above static_score_below motion_score_above motion_score_below; do \
	  "$$stage_bin/vcsc" -I "$$stage_vcs" \
	    "$(CURDIR)/test/fixtures/all_five_181/$$fixture.c26" \
	    -o "$(INSTALLCHECK_STAGING)/$$fixture.bin"; \
	  test `wc -c < "$(INSTALLCHECK_STAGING)/$$fixture.bin"` -eq 4096; \
	done; \
	test -f "$$stage_vcs/renderers/all_five_181_unofficial/README.md"; \
	test -f "$$stage_vcs/renderers/all_five_181_unofficial/all_five_181_unofficial.c26"; \
	"$$stage_bin/vcsc" -I "$$stage_vcs" -Wa,--illegals \
	  "$(CURDIR)/test/fixtures/all_five_181_unofficial/smoke.c26" \
	  -o "$(INSTALLCHECK_STAGING)/all_five_181_unofficial.bin"; \
	test `wc -c < "$(INSTALLCHECK_STAGING)/all_five_181_unofficial.bin"` -eq 4096; \
	"$$stage_bin/vcsc" -I "$$stage_vcs" \
	  "$(CURDIR)/test/fixtures/all_five_192/smoke.c26" \
	  -o "$(INSTALLCHECK_STAGING)/all_five_192.bin"; \
	test `wc -c < "$(INSTALLCHECK_STAGING)/all_five_192.bin"` -eq 4096; \
	"$$stage_bin/vcsc" -I "$$stage_vcs" \
	  "$(CURDIR)/test/fixtures/all_five_170/smoke.c26" \
	  -o "$(INSTALLCHECK_STAGING)/all_five_170.bin"; \
	test `wc -c < "$(INSTALLCHECK_STAGING)/all_five_170.bin"` -eq 4096; \
	test -f "$$stage_vcs/renderers/player_color_181/README.md"; \
	test -f "$$stage_vcs/renderers/player_color_181/player_color_181.c26"; \
	"$$stage_bin/vcsc" -I "$$stage_vcs" \
	  "$(CURDIR)/test/fixtures/player_color_181/smoke.c26" \
	  -o "$(INSTALLCHECK_STAGING)/player_color_181.bin"; \
	test `wc -c < "$(INSTALLCHECK_STAGING)/player_color_181.bin"` -eq 4096; \
	test -f "$$stage_vcs/renderers/player_color_181_unofficial/README.md"; \
	test -f "$$stage_vcs/renderers/player_color_181_unofficial/player_color_181_unofficial.c26"; \
	"$$stage_bin/vcsc" -I "$$stage_vcs" -Wa,--illegals \
	  "$(CURDIR)/test/fixtures/player_color_181_unofficial/smoke.c26" \
	  -o "$(INSTALLCHECK_STAGING)/player_color_181_unofficial.bin"; \
	test `wc -c < "$(INSTALLCHECK_STAGING)/player_color_181_unofficial.bin"` -eq 4096; \
	test -f "$$stage_vcs/renderers/player_color_192/README.md"; \
	test -f "$$stage_vcs/renderers/player_color_192/player_color_192.c26"; \
	"$$stage_bin/vcsc" -I "$$stage_vcs" \
	  "$(CURDIR)/test/fixtures/player_color_192/smoke.c26" \
	  -o "$(INSTALLCHECK_STAGING)/player_color_192.bin"; \
	test `wc -c < "$(INSTALLCHECK_STAGING)/player_color_192.bin"` -eq 4096; \
	test -f "$$stage_vcs/renderers/poison_debug_score/README.md"; \
	test -f "$$stage_vcs/renderers/poison_debug_score/poison_debug_score.c26"; \
	"$$stage_bin/vcsc" -I "$$stage_vcs" \
	  "$(CURDIR)/test/fixtures/poison_debug_score/standalone.c26" \
	  -o "$(INSTALLCHECK_STAGING)/poison_debug_score.bin"; \
	test `wc -c < "$(INSTALLCHECK_STAGING)/poison_debug_score.bin"` -eq 4096; \
	for fixture in static_score_above static_score_below motion_score_above motion_score_below; do \
	  "$$stage_bin/vcsc" -I "$$stage_vcs" \
	    "$(CURDIR)/test/fixtures/player_color_181/$$fixture.c26" \
	    -o "$(INSTALLCHECK_STAGING)/player_color_$$fixture.bin"; \
	  test `wc -c < "$(INSTALLCHECK_STAGING)/player_color_$$fixture.bin"` -eq 4096; \
	done; \
	test -f "$$stage_vcs/renderers/standard_4k_ntsc/README.md"; \
	test -f "$$stage_vcs/renderers/standard_4k_ntsc/DCP_LEGALIZATION.md"; \
	test -f "$$stage_vcs/renderers/standard_4k_ntsc/UNOFFICIAL_OPCODES.md"; \
	test -f "$$stage_vcs/renderers/standard_4k_ntsc/standard_4k_ntsc.c26"; \
	test -f "$$stage_vcs/renderers/standard_4k_ntsc/standard_4k_ntsc_renderer.s26"; \
	test -f "$$stage_vcs/renderers/standard_4k_ntsc/standard_4k_ntsc_macros.inc"; \
	test -f "$$stage_vcs/renderers/standard_4k_ntsc/vcs_standard_4k_ntsc.cfg"; \
	test -f "$$stage_vcs/renderers/standard_4k_ntsc_playercolors/README.md"; \
	test -f "$$stage_vcs/renderers/standard_4k_ntsc_playercolors/standard_4k_ntsc_playercolors.c26"; \
	test -f "$$stage_vcs/renderers/standard_4k_ntsc_playercolors/standard_4k_ntsc_playercolors_renderer.s26"; \
	test -f "$$stage_vcs/renderers/standard_4k_ntsc_playercolors/standard_4k_ntsc_playercolors_macros.inc"; \
	test -f "$$stage_vcs/renderers/standard_4k_ntsc_playercolors/vcs_standard_4k_ntsc_playercolors.cfg"; \
	"$$stage_bin/vcsc-as" \
	  -I "$$stage_vcs/renderers/standard_4k_ntsc" \
	  --map="$(INSTALLCHECK_STAGING)/standard_4k_ntsc_renderer.map" \
	  -o "$(INSTALLCHECK_STAGING)/standard_4k_ntsc_renderer.o26" \
	  "$$stage_vcs/renderers/standard_4k_ntsc/standard_4k_ntsc_renderer.s26"; \
	test `wc -c < "$(INSTALLCHECK_STAGING)/standard_4k_ntsc_renderer.o26"` -gt 0; \
	grep -aFq '__componentmeta$$V1$$S$$4' "$(INSTALLCHECK_STAGING)/standard_4k_ntsc_renderer.o26"; \
	grep -aFq '__componentmeta$$V1$$L$$52454E44455245525F434F4445$$4073746172747570$$256$$1' "$(INSTALLCHECK_STAGING)/standard_4k_ntsc_renderer.o26"; \
	test "$$(head -c 6 "$(INSTALLCHECK_STAGING)/standard_4k_ntsc_renderer.o26" | od -An -tx1 | tr -d ' \n')" = "01006f323602"; \
	if "$$stage_bin/vcsc" -I "$$stage_vcs" \
	  "$(CURDIR)/test/vcs_standard_renderer_contract_smoke.c26" \
	  "$$stage_vcs/renderers/standard_4k_ntsc/standard_4k_ntsc_renderer.s26" \
	  -o "$(INSTALLCHECK_STAGING)/standard_renderer_contract_smoke.bin" \
	  >"$(INSTALLCHECK_STAGING)/standard_renderer_contract_smoke.stdout" \
	  2>"$(INSTALLCHECK_STAGING)/standard_renderer_contract_smoke.stderr"; then \
	  echo "mutable standard-renderer playfield unexpectedly linked" >&2; exit 1; \
	fi; \
	test ! -s "$(INSTALLCHECK_STAGING)/standard_renderer_contract_smoke.stdout"; \
	grep -q "ram overflow" "$(INSTALLCHECK_STAGING)/standard_renderer_contract_smoke.stderr"; \
	"$$stage_bin/vcsc" -I "$$stage_vcs" \
	  "$(CURDIR)/test/vcs_standard_renderer_contract_rom_smoke.c26" \
	  "$$stage_vcs/renderers/standard_4k_ntsc/standard_4k_ntsc_renderer.s26" \
	  -o "$(INSTALLCHECK_STAGING)/standard_renderer_contract_rom_smoke.bin"; \
	test `wc -c < "$(INSTALLCHECK_STAGING)/standard_renderer_contract_rom_smoke.bin"` -eq 4096; \
	"$$stage_bin/vcsc" -I "$$stage_vcs" -DMAPPER_BANKS=2 \
	  -T "$$stage_vcs/vcs.cfg" \
	  -Map "$(INSTALLCHECK_STAGING)/standard_renderer_banked_f8.map" \
	  "$(CURDIR)/examples/09_bankswitching/02_standard_renderer/banked_standard_renderer.c26" \
	  "$$stage_vcs/renderers/standard_4k_ntsc/standard_4k_ntsc_renderer.s26" \
	  -o "$(INSTALLCHECK_STAGING)/standard_renderer_banked_f8.bin"; \
	test `wc -c < "$(INSTALLCHECK_STAGING)/standard_renderer_banked_f8.bin"` -eq 8192; \
	grep -q 'vcs_standard_overscan_hook source=bank0.*destination=bank1' "$(INSTALLCHECK_STAGING)/standard_renderer_banked_f8.map"; \
	grep -q 'RENDERER_CODE.*bank=bank0.*component-region=@startup' "$(INSTALLCHECK_STAGING)/standard_renderer_banked_f8.map"; \
	for src in $$(find \
	  "$(CURDIR)/examples/04_player_color_181" \
	  "$(CURDIR)/examples/06_all_five_181" \
	  "$(CURDIR)/examples/07_player_color_181_unofficial" \
	  "$(CURDIR)/examples/08_all_five_181_unofficial" \
	  "$(CURDIR)/examples/11_all_five_170" \
	  -path '*/01_interactive/*.c26' -type f | sort); do \
	  leaf=$$(dirname "$$src"); stem=$$(basename "$$src" .c26); extra=; \
	  case "$$src" in *_unofficial/*) extra='-Wa,--illegals' ;; esac; \
	  "$$stage_bin/vcsc" -I "$$stage_vcs" -I "$$leaf" $$extra \
	    "$$src" -o "$(INSTALLCHECK_STAGING)/$$stem.bin"; \
	  test `wc -c < "$(INSTALLCHECK_STAGING)/$$stem.bin"` -eq 4096; \
	done
	rm -rf $(INSTALLCHECK_STAGING)

tar:
	rm -f ../`basename $$(git rev-parse --show-toplevel)`.*.tar.gz
	git ls-files | tar -czv -T - -f /tmp/`basename $$(git rev-parse --show-toplevel)`.`date -u "+%Y%m%d_%H%M%S"`.tar.gz

patch:
	rm -f ../`basename $$(git rev-parse --show-toplevel)`.*.patch
	git diff > /tmp/`basename $$(git rev-parse --show-toplevel)`.`date -u "+%Y%m%d_%H%M%S"`.patch

unit: tools
	@$(MAKE) --no-print-directory -C ./test unit

sieve: tools
	./driver/vcsc -I test -T test/generic_6502.cfg test/sieve.c26 -o sieve.hex
	simulator/vcsc-sim sieve.hex | head

e2e: tools
	@$(MAKE) --no-print-directory -C ./test e2e

test: tools
	@$(MAKE) --no-print-directory -C ./test test

stella-bank-test: tools
	rm -rf $(STELLA_BANK_TEST_TMP)
	VCSC_STELLA="$(STELLA)" perl test/vcs_bankswitching_diagnostic.pl \
	  "$(CURDIR)" "$(STELLA_BANK_TEST_TMP)" --stella
	rm -rf $(STELLA_BANK_TEST_TMP)

stella-renderer-bank-test: tools
	rm -rf $(STELLA_RENDERER_BANK_TEST_TMP)
	VCSC_STELLA="$(STELLA)" perl test/vcs_standard_renderer_banked_stella.pl \
	  "$(CURDIR)" "$(STELLA_RENDERER_BANK_TEST_TMP)"
	rm -rf $(STELLA_RENDERER_BANK_TEST_TMP)

stella-wide-score-test: tools
	rm -rf $(STELLA_WIDE_SCORE_TEST_TMP)
	VCSC_STELLA="$(STELLA)" perl test/vcs_six_glyph_wide_stella.pl \
	  "$(CURDIR)" "$(STELLA_WIDE_SCORE_TEST_TMP)"
	rm -rf $(STELLA_WIDE_SCORE_TEST_TMP)

stella-player-color-192-test: tools
	rm -rf $(STELLA_PLAYER_COLOR_192_TEST_TMP)
	VCSC_STELLA="$(STELLA)" perl test/vcs_player_color_192_stella.pl \
	  "$(CURDIR)" "$(STELLA_PLAYER_COLOR_192_TEST_TMP)"
	rm -rf $(STELLA_PLAYER_COLOR_192_TEST_TMP)

stella-faithful-multisprite-test: tools
	rm -rf $(STELLA_FAITHFUL_MULTISPRITE_TEST_TMP)
	VCSC_STELLA="$(STELLA)" perl test/vcs_faithful_legacy_multisprite_stella.pl \
	  "$(CURDIR)" "$(STELLA_FAITHFUL_MULTISPRITE_TEST_TMP)"
	rm -rf $(STELLA_FAITHFUL_MULTISPRITE_TEST_TMP)

.PHONY: all tools install install-core install-data uninstall uninstall-data package installcheck tarball unit sieve e2e test stella-bank-test stella-renderer-bank-test stella-wide-score-test stella-player-color-192-test stella-faithful-multisprite-test docs
