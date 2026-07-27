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
	stella test/oracles/pristine_basic_v1.9_playercolors/faithful_legacy_playercolors.bin
	@for each in examples/*; do \
		if [ -d "$$each" ]; then \
			$(MAKE) -C "$$each" clean && \
			$(MAKE) -C "$$each" && \
			stella "$$each"/*.bin; \
		fi; \
	done

clean:
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
	install -m 0644 libraries/vcs/README.md $(DESTDIR)$(DATADIR)/vcs/README.md
	install -m 0644 libraries/vcs/LEGACY_KERNEL_CONVERSION.md $(DESTDIR)$(DATADIR)/vcs/LEGACY_KERNEL_CONVERSION.md
	install -m 0644 libraries/vcs/color_ntsc.c26 $(DESTDIR)$(DATADIR)/vcs/color_ntsc.c26
	install -m 0644 libraries/vcs/frame_ntsc.c26 $(DESTDIR)$(DATADIR)/vcs/frame_ntsc.c26
	install -m 0644 libraries/vcs/playfield.c26 $(DESTDIR)$(DATADIR)/vcs/playfield.c26
	install -m 0644 libraries/vcs/riot.c26 $(DESTDIR)$(DATADIR)/vcs/riot.c26
	install -m 0644 libraries/vcs/six_glyph_component.c26 $(DESTDIR)$(DATADIR)/vcs/six_glyph_component.c26
	install -m 0644 libraries/vcs/sound_ntsc.c26 $(DESTDIR)$(DATADIR)/vcs/sound_ntsc.c26
	install -m 0644 libraries/vcs/tia.c26 $(DESTDIR)$(DATADIR)/vcs/tia.c26
	install -m 0644 libraries/vcs/vcs.c26 $(DESTDIR)$(DATADIR)/vcs/vcs.c26
	install -m 0644 libraries/vcs/vcs_4k.cfg $(DESTDIR)$(DATADIR)/vcs/vcs_4k.cfg
	install -d $(DESTDIR)$(DATADIR)/vcs/kernels
	install -m 0644 libraries/vcs/kernels/COMPONENT_CONVERSION.md \
	  $(DESTDIR)$(DATADIR)/vcs/kernels/COMPONENT_CONVERSION.md
	install -d $(DESTDIR)$(DATADIR)/vcs/kernels/faithful_legacy_playercolors
	install -m 0644 libraries/vcs/kernels/faithful_legacy_playercolors/README.md \
	  libraries/vcs/kernels/faithful_legacy_playercolors/faithful_legacy_playercolors.c26 \
	  libraries/vcs/kernels/faithful_legacy_playercolors/faithful_legacy_playercolors_macros.inc \
	  libraries/vcs/kernels/faithful_legacy_playercolors/faithful_legacy_playercolors_reference.s26 \
	  libraries/vcs/kernels/faithful_legacy_playercolors/faithful_legacy_playercolors.cfg \
	  $(DESTDIR)$(DATADIR)/vcs/kernels/faithful_legacy_playercolors/
	install -d $(DESTDIR)$(DATADIR)/vcs/kernels/all_five_181
	install -m 0644 libraries/vcs/kernels/all_five_181/README.md \
	  libraries/vcs/kernels/all_five_181/all_five_181.c26 \
	  $(DESTDIR)$(DATADIR)/vcs/kernels/all_five_181/
	install -d $(DESTDIR)$(DATADIR)/vcs/kernels/all_five_181_unofficial
	install -m 0644 libraries/vcs/kernels/all_five_181_unofficial/README.md \
	  libraries/vcs/kernels/all_five_181_unofficial/all_five_181_unofficial.c26 \
	  $(DESTDIR)$(DATADIR)/vcs/kernels/all_five_181_unofficial/
	install -d $(DESTDIR)$(DATADIR)/vcs/kernels/all_five_192
	install -m 0644 libraries/vcs/kernels/all_five_192/README.md \
	  libraries/vcs/kernels/all_five_192/all_five_192.c26 \
	  $(DESTDIR)$(DATADIR)/vcs/kernels/all_five_192/
	install -d $(DESTDIR)$(DATADIR)/vcs/kernels/player_color_181
	install -m 0644 libraries/vcs/kernels/player_color_181/README.md \
	  libraries/vcs/kernels/player_color_181/player_color_181.c26 \
	  $(DESTDIR)$(DATADIR)/vcs/kernels/player_color_181/
	install -d $(DESTDIR)$(DATADIR)/vcs/kernels/player_color_181_unofficial
	install -m 0644 libraries/vcs/kernels/player_color_181_unofficial/README.md \
	  libraries/vcs/kernels/player_color_181_unofficial/player_color_181_unofficial.c26 \
	  $(DESTDIR)$(DATADIR)/vcs/kernels/player_color_181_unofficial/
	install -d $(DESTDIR)$(DATADIR)/vcs/kernels/player_color_192
	install -m 0644 libraries/vcs/kernels/player_color_192/README.md \
	  libraries/vcs/kernels/player_color_192/player_color_192.c26 \
	  $(DESTDIR)$(DATADIR)/vcs/kernels/player_color_192/
	install -d $(DESTDIR)$(DATADIR)/vcs/kernels/poison_debug_score
	install -m 0644 libraries/vcs/kernels/poison_debug_score/README.md \
	  libraries/vcs/kernels/poison_debug_score/poison_debug_score.c26 \
	  $(DESTDIR)$(DATADIR)/vcs/kernels/poison_debug_score/
	install -d $(DESTDIR)$(DATADIR)/vcs/kernels/standard_4k_ntsc
	install -m 0644 libraries/vcs/kernels/standard_4k_ntsc/README.md \
	  libraries/vcs/kernels/standard_4k_ntsc/DCP_LEGALIZATION.md \
	  libraries/vcs/kernels/standard_4k_ntsc/UNOFFICIAL_OPCODES.md \
	  libraries/vcs/kernels/standard_4k_ntsc/standard_4k_ntsc.c26 \
	  libraries/vcs/kernels/standard_4k_ntsc/standard_4k_ntsc_kernel.s26 \
	  libraries/vcs/kernels/standard_4k_ntsc/standard_4k_ntsc_macros.inc \
	  libraries/vcs/kernels/standard_4k_ntsc/vcs_standard_4k_ntsc.cfg \
	  $(DESTDIR)$(DATADIR)/vcs/kernels/standard_4k_ntsc/
	install -d $(DESTDIR)$(DATADIR)/vcs/kernels/standard_4k_ntsc_playercolors
	install -m 0644 libraries/vcs/kernels/standard_4k_ntsc_playercolors/README.md \
	  libraries/vcs/kernels/standard_4k_ntsc_playercolors/standard_4k_ntsc_playercolors.c26 \
	  libraries/vcs/kernels/standard_4k_ntsc_playercolors/standard_4k_ntsc_playercolors_kernel.s26 \
	  libraries/vcs/kernels/standard_4k_ntsc_playercolors/standard_4k_ntsc_playercolors_macros.inc \
	  libraries/vcs/kernels/standard_4k_ntsc_playercolors/vcs_standard_4k_ntsc_playercolors.cfg \
	  $(DESTDIR)$(DATADIR)/vcs/kernels/standard_4k_ntsc_playercolors/
	install -d $(DESTDIR)$(DATADIR)/vcs/fonts
	install -m 0644 libraries/vcs/fonts/README.md libraries/vcs/fonts/*.c26 $(DESTDIR)$(DATADIR)/vcs/fonts/
	install -d $(DESTDIR)$(DATADIR)/vcs/legacy-basic-kernels
	install -m 0644 libraries/vcs/legacy-basic-kernels/LICENSE.txt $(DESTDIR)$(DATADIR)/vcs/legacy-basic-kernels/LICENSE.txt
	install -m 0644 libraries/vcs/legacy-basic-kernels/OMITTED-UPSTREAM-ARTIFACTS.txt $(DESTDIR)$(DATADIR)/vcs/legacy-basic-kernels/OMITTED-UPSTREAM-ARTIFACTS.txt
	install -m 0644 libraries/vcs/legacy-basic-kernels/README.md $(DESTDIR)$(DATADIR)/vcs/legacy-basic-kernels/README.md

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
	rm -f $(DESTDIR)$(DATADIR)/vcs/README.md
	rm -f $(DESTDIR)$(DATADIR)/vcs/LEGACY_KERNEL_CONVERSION.md
	rm -f $(DESTDIR)$(DATADIR)/vcs/color_ntsc.c26
	rm -f $(DESTDIR)$(DATADIR)/vcs/frame_ntsc.c26
	rm -f $(DESTDIR)$(DATADIR)/vcs/playfield.c26
	rm -f $(DESTDIR)$(DATADIR)/vcs/riot.c26
	rm -f $(DESTDIR)$(DATADIR)/vcs/six_glyph_component.c26
	rm -f $(DESTDIR)$(DATADIR)/vcs/sound_ntsc.c26
	rm -f $(DESTDIR)$(DATADIR)/vcs/tia.c26
	rm -f $(DESTDIR)$(DATADIR)/vcs/vcs.c26
	rm -f $(DESTDIR)$(DATADIR)/vcs/vcs_4k.cfg
	rm -f $(DESTDIR)$(DATADIR)/vcs/kernels/COMPONENT_CONVERSION.md
	rm -f $(DESTDIR)$(DATADIR)/vcs/kernels/faithful_legacy_playercolors/README.md
	rm -f $(DESTDIR)$(DATADIR)/vcs/kernels/faithful_legacy_playercolors/faithful_legacy_playercolors.c26
	rm -f $(DESTDIR)$(DATADIR)/vcs/kernels/faithful_legacy_playercolors/faithful_legacy_playercolors_macros.inc
	rm -f $(DESTDIR)$(DATADIR)/vcs/kernels/faithful_legacy_playercolors/faithful_legacy_playercolors_reference.s26
	rm -f $(DESTDIR)$(DATADIR)/vcs/kernels/faithful_legacy_playercolors/faithful_legacy_playercolors.cfg
	rmdir $(DESTDIR)$(DATADIR)/vcs/kernels/faithful_legacy_playercolors 2>/dev/null || true
	rm -f $(DESTDIR)$(DATADIR)/vcs/kernels/all_five_181/README.md
	rm -f $(DESTDIR)$(DATADIR)/vcs/kernels/all_five_181/all_five_181.c26
	rmdir $(DESTDIR)$(DATADIR)/vcs/kernels/all_five_181 2>/dev/null || true
	rm -f $(DESTDIR)$(DATADIR)/vcs/kernels/all_five_181_unofficial/README.md
	rm -f $(DESTDIR)$(DATADIR)/vcs/kernels/all_five_181_unofficial/all_five_181_unofficial.c26
	rmdir $(DESTDIR)$(DATADIR)/vcs/kernels/all_five_181_unofficial 2>/dev/null || true
	rm -f $(DESTDIR)$(DATADIR)/vcs/kernels/all_five_192/README.md
	rm -f $(DESTDIR)$(DATADIR)/vcs/kernels/all_five_192/all_five_192.c26
	rmdir $(DESTDIR)$(DATADIR)/vcs/kernels/all_five_192 2>/dev/null || true
	rm -f $(DESTDIR)$(DATADIR)/vcs/kernels/player_color_181/README.md
	rm -f $(DESTDIR)$(DATADIR)/vcs/kernels/player_color_181/player_color_181.c26
	rmdir $(DESTDIR)$(DATADIR)/vcs/kernels/player_color_181 2>/dev/null || true
	rm -f $(DESTDIR)$(DATADIR)/vcs/kernels/player_color_181_unofficial/README.md
	rm -f $(DESTDIR)$(DATADIR)/vcs/kernels/player_color_181_unofficial/player_color_181_unofficial.c26
	rmdir $(DESTDIR)$(DATADIR)/vcs/kernels/player_color_181_unofficial 2>/dev/null || true
	rm -f $(DESTDIR)$(DATADIR)/vcs/kernels/player_color_192/README.md
	rm -f $(DESTDIR)$(DATADIR)/vcs/kernels/player_color_192/player_color_192.c26
	rmdir $(DESTDIR)$(DATADIR)/vcs/kernels/player_color_192 2>/dev/null || true
	rm -f $(DESTDIR)$(DATADIR)/vcs/kernels/poison_debug_score/README.md
	rm -f $(DESTDIR)$(DATADIR)/vcs/kernels/poison_debug_score/poison_debug_score.c26
	rmdir $(DESTDIR)$(DATADIR)/vcs/kernels/poison_debug_score 2>/dev/null || true
	rm -f $(DESTDIR)$(DATADIR)/vcs/kernels/standard_4k_ntsc/README.md
	rm -f $(DESTDIR)$(DATADIR)/vcs/kernels/standard_4k_ntsc/DCP_LEGALIZATION.md
	rm -f $(DESTDIR)$(DATADIR)/vcs/kernels/standard_4k_ntsc/UNOFFICIAL_OPCODES.md
	rm -f $(DESTDIR)$(DATADIR)/vcs/kernels/standard_4k_ntsc/standard_4k_ntsc.c26
	rm -f $(DESTDIR)$(DATADIR)/vcs/kernels/standard_4k_ntsc/standard_4k_ntsc_kernel.s26
	rm -f $(DESTDIR)$(DATADIR)/vcs/kernels/standard_4k_ntsc/standard_4k_ntsc_macros.inc
	rm -f $(DESTDIR)$(DATADIR)/vcs/kernels/standard_4k_ntsc/vcs_standard_4k_ntsc.cfg
	rmdir $(DESTDIR)$(DATADIR)/vcs/kernels/standard_4k_ntsc 2>/dev/null || true
	rm -f $(DESTDIR)$(DATADIR)/vcs/kernels/standard_4k_ntsc_playercolors/README.md
	rm -f $(DESTDIR)$(DATADIR)/vcs/kernels/standard_4k_ntsc_playercolors/standard_4k_ntsc_playercolors.c26
	rm -f $(DESTDIR)$(DATADIR)/vcs/kernels/standard_4k_ntsc_playercolors/standard_4k_ntsc_playercolors_kernel.s26
	rm -f $(DESTDIR)$(DATADIR)/vcs/kernels/standard_4k_ntsc_playercolors/standard_4k_ntsc_playercolors_macros.inc
	rm -f $(DESTDIR)$(DATADIR)/vcs/kernels/standard_4k_ntsc_playercolors/vcs_standard_4k_ntsc_playercolors.cfg
	rmdir $(DESTDIR)$(DATADIR)/vcs/kernels/standard_4k_ntsc_playercolors 2>/dev/null || true
	rmdir $(DESTDIR)$(DATADIR)/vcs/kernels 2>/dev/null || true
	rm -f $(DESTDIR)$(DATADIR)/vcs/fonts/README.md
	rm -f $(DESTDIR)$(DATADIR)/vcs/fonts/*.c26
	rmdir $(DESTDIR)$(DATADIR)/vcs/fonts 2>/dev/null || true
	rm -f $(DESTDIR)$(DATADIR)/vcs/legacy-basic-kernels/LICENSE.txt
	rm -f $(DESTDIR)$(DATADIR)/vcs/legacy-basic-kernels/OMITTED-UPSTREAM-ARTIFACTS.txt
	rm -f $(DESTDIR)$(DATADIR)/vcs/legacy-basic-kernels/README.md

package: tools
	rm -rf $(PACKAGE_STAGING)
	$(MAKE) --no-print-directory install-core DESTDIR="$(PACKAGE_STAGING)" PREFIX="$(PACKAGE_PREFIX)" BINDIR="$(PACKAGE_PREFIX)/bin" LIBDIR="$(PACKAGE_PREFIX)/lib" INCLUDEDIR="$(PACKAGE_PREFIX)/include" DATADIR="$(PACKAGE_PREFIX)/share" CFGDIR="$(PACKAGE_PREFIX)/share/cfg"
	tar -C $(PACKAGE_STAGING) -czf ./vcsc.install.`date -u "+%Y%m%d_%H%M%S"`.tar.gz .

installcheck: tools
	rm -rf $(INSTALLCHECK_STAGING)
	$(MAKE) --no-print-directory install-core DESTDIR="$(INSTALLCHECK_STAGING)" PREFIX="/opt/vcsc" BINDIR="/opt/vcsc/bin" LIBDIR="/opt/vcsc/lib" INCLUDEDIR="/opt/vcsc/include" DATADIR="/opt/vcsc/share" CFGDIR="/opt/vcsc/share/cfg"
	stage_bin="$(INSTALLCHECK_STAGING)/opt/vcsc/bin"; \
	stage_vcs="$(INSTALLCHECK_STAGING)/opt/vcsc/share/vcs"; \
	"$$stage_bin/vcsc" -print-prog-name=cc1 >/dev/null; \
	"$$stage_bin/vcsc" -print-prog-name=as >/dev/null; \
	"$$stage_bin/vcsc" -I "$$stage_vcs" "$(CURDIR)/examples/01_blank_screen/blank_screen.c26" -o "$(INSTALLCHECK_STAGING)/blank_screen.bin"; \
	test `wc -c < "$(INSTALLCHECK_STAGING)/blank_screen.bin"` -eq 4096; \
	"$$stage_bin/vcsc" -I "$$stage_vcs" "$(CURDIR)/test/vcs_headers_smoke_test.c26" -o "$(INSTALLCHECK_STAGING)/vcs_headers_smoke.bin"; \
	test `wc -c < "$(INSTALLCHECK_STAGING)/vcs_headers_smoke.bin"` -eq 4096; \
	"$$stage_bin/vcsc" -I "$$stage_vcs" -I "$(CURDIR)/examples/03_score" \
	  "$(CURDIR)/examples/03_score/score.c26" \
	  -o "$(INSTALLCHECK_STAGING)/score.bin"; \
	test `wc -c < "$(INSTALLCHECK_STAGING)/score.bin"` -eq 4096; \
	"$$stage_bin/vcsc" -I "$$stage_vcs" -Wa,--illegals \
	  "$(CURDIR)/examples/04_fingerprint/fingerprint.c26" \
	  -o "$(INSTALLCHECK_STAGING)/fingerprint.bin"; \
	test `wc -c < "$(INSTALLCHECK_STAGING)/fingerprint.bin"` -eq 4096; \
	test -f "$$stage_vcs/color_ntsc.c26"; \
	test -f "$$stage_vcs/frame_ntsc.c26"; \
	test -f "$$stage_vcs/six_glyph_component.c26"; \
	test ! -e "$$stage_vcs/six_glyph_display.c26"; \
	"$$stage_bin/vcsc" -I "$$stage_vcs" \
	  "$(CURDIR)/test/fixtures/six_glyph_component/two_instances.c26" \
	  -o "$(INSTALLCHECK_STAGING)/six_glyph_component.bin"; \
	test `wc -c < "$(INSTALLCHECK_STAGING)/six_glyph_component.bin"` -eq 4096; \
	"$$stage_bin/vcsc" -I "$$stage_vcs" \
	  "$(CURDIR)/test/fixtures/six_glyph_component/two_instances_reversed.c26" \
	  -o "$(INSTALLCHECK_STAGING)/six_glyph_component_reversed.bin"; \
	test `wc -c < "$(INSTALLCHECK_STAGING)/six_glyph_component_reversed.bin"` -eq 4096; \
	test -f "$$stage_vcs/playfield.c26"; \
	test -f "$$stage_vcs/sound_ntsc.c26"; \
	test -f "$$stage_vcs/kernels/COMPONENT_CONVERSION.md"; \
	test -f "$$stage_vcs/kernels/faithful_legacy_playercolors/README.md"; \
	test -f "$$stage_vcs/kernels/faithful_legacy_playercolors/faithful_legacy_playercolors.c26"; \
	test -f "$$stage_vcs/kernels/faithful_legacy_playercolors/faithful_legacy_playercolors_macros.inc"; \
	test -f "$$stage_vcs/kernels/faithful_legacy_playercolors/faithful_legacy_playercolors_reference.s26"; \
	test -f "$$stage_vcs/kernels/faithful_legacy_playercolors/faithful_legacy_playercolors.cfg"; \
	"$$stage_bin/vcsc" -I "$$stage_vcs" -Wa,--illegals \
	  -T "$$stage_vcs/kernels/faithful_legacy_playercolors/faithful_legacy_playercolors.cfg" \
	  "$(CURDIR)/test/fixtures/faithful_legacy_playercolors/template_static.c26" \
	  -o "$(INSTALLCHECK_STAGING)/faithful_legacy_static_test.bin"; \
	test `wc -c < "$(INSTALLCHECK_STAGING)/faithful_legacy_static_test.bin"` -eq 4096; \
	test -f "$$stage_vcs/kernels/all_five_181/README.md"; \
	test -f "$$stage_vcs/kernels/all_five_181/all_five_181.c26"; \
	"$$stage_bin/vcsc" -I "$$stage_vcs" \
	  -T "$$stage_vcs/kernels/standard_4k_ntsc/vcs_standard_4k_ntsc.cfg" \
	  "$(CURDIR)/test/fixtures/all_five_181/smoke.c26" \
	  -o "$(INSTALLCHECK_STAGING)/all_five_181.bin"; \
	test `wc -c < "$(INSTALLCHECK_STAGING)/all_five_181.bin"` -eq 4096; \
	for fixture in static_score_above static_score_below motion_score_above motion_score_below; do \
	  "$$stage_bin/vcsc" -I "$$stage_vcs" \
	    -T "$$stage_vcs/kernels/standard_4k_ntsc/vcs_standard_4k_ntsc.cfg" \
	    "$(CURDIR)/test/fixtures/all_five_181/$$fixture.c26" \
	    -o "$(INSTALLCHECK_STAGING)/$$fixture.bin"; \
	  test `wc -c < "$(INSTALLCHECK_STAGING)/$$fixture.bin"` -eq 4096; \
	done; \
	test -f "$$stage_vcs/kernels/all_five_181_unofficial/README.md"; \
	test -f "$$stage_vcs/kernels/all_five_181_unofficial/all_five_181_unofficial.c26"; \
	"$$stage_bin/vcsc" -I "$$stage_vcs" -Wa,--illegals \
	  -T "$$stage_vcs/kernels/standard_4k_ntsc/vcs_standard_4k_ntsc.cfg" \
	  "$(CURDIR)/test/fixtures/all_five_181_unofficial/smoke.c26" \
	  -o "$(INSTALLCHECK_STAGING)/all_five_181_unofficial.bin"; \
	test `wc -c < "$(INSTALLCHECK_STAGING)/all_five_181_unofficial.bin"` -eq 4096; \
	test -f "$$stage_vcs/kernels/all_five_192/README.md"; \
	test -f "$$stage_vcs/kernels/all_five_192/all_five_192.c26"; \
	"$$stage_bin/vcsc" -I "$$stage_vcs" \
	  -T "$$stage_vcs/kernels/standard_4k_ntsc/vcs_standard_4k_ntsc.cfg" \
	  "$(CURDIR)/test/fixtures/all_five_192/smoke.c26" \
	  -o "$(INSTALLCHECK_STAGING)/all_five_192.bin"; \
	test `wc -c < "$(INSTALLCHECK_STAGING)/all_five_192.bin"` -eq 4096; \
	test -f "$$stage_vcs/kernels/player_color_181/README.md"; \
	test -f "$$stage_vcs/kernels/player_color_181/player_color_181.c26"; \
	"$$stage_bin/vcsc" -I "$$stage_vcs" \
	  -T "$$stage_vcs/kernels/standard_4k_ntsc/vcs_standard_4k_ntsc.cfg" \
	  "$(CURDIR)/test/fixtures/player_color_181/smoke.c26" \
	  -o "$(INSTALLCHECK_STAGING)/player_color_181.bin"; \
	test `wc -c < "$(INSTALLCHECK_STAGING)/player_color_181.bin"` -eq 4096; \
	test -f "$$stage_vcs/kernels/player_color_181_unofficial/README.md"; \
	test -f "$$stage_vcs/kernels/player_color_181_unofficial/player_color_181_unofficial.c26"; \
	"$$stage_bin/vcsc" -I "$$stage_vcs" -Wa,--illegals \
	  -T "$$stage_vcs/kernels/standard_4k_ntsc/vcs_standard_4k_ntsc.cfg" \
	  "$(CURDIR)/test/fixtures/player_color_181_unofficial/smoke.c26" \
	  -o "$(INSTALLCHECK_STAGING)/player_color_181_unofficial.bin"; \
	test `wc -c < "$(INSTALLCHECK_STAGING)/player_color_181_unofficial.bin"` -eq 4096; \
	test -f "$$stage_vcs/kernels/player_color_192/README.md"; \
	test -f "$$stage_vcs/kernels/player_color_192/player_color_192.c26"; \
	"$$stage_bin/vcsc" -I "$$stage_vcs" \
	  -T "$$stage_vcs/kernels/standard_4k_ntsc/vcs_standard_4k_ntsc.cfg" \
	  "$(CURDIR)/test/fixtures/player_color_192/smoke.c26" \
	  -o "$(INSTALLCHECK_STAGING)/player_color_192.bin"; \
	test `wc -c < "$(INSTALLCHECK_STAGING)/player_color_192.bin"` -eq 4096; \
	test -f "$$stage_vcs/kernels/poison_debug_score/README.md"; \
	test -f "$$stage_vcs/kernels/poison_debug_score/poison_debug_score.c26"; \
	"$$stage_bin/vcsc" -I "$$stage_vcs" \
	  "$(CURDIR)/test/fixtures/poison_debug_score/standalone.c26" \
	  -o "$(INSTALLCHECK_STAGING)/poison_debug_score.bin"; \
	test `wc -c < "$(INSTALLCHECK_STAGING)/poison_debug_score.bin"` -eq 4096; \
	for fixture in static_score_above static_score_below motion_score_above motion_score_below; do \
	  "$$stage_bin/vcsc" -I "$$stage_vcs" \
	    -T "$$stage_vcs/kernels/standard_4k_ntsc/vcs_standard_4k_ntsc.cfg" \
	    "$(CURDIR)/test/fixtures/player_color_181/$$fixture.c26" \
	    -o "$(INSTALLCHECK_STAGING)/player_color_$$fixture.bin"; \
	  test `wc -c < "$(INSTALLCHECK_STAGING)/player_color_$$fixture.bin"` -eq 4096; \
	done; \
	test -f "$$stage_vcs/kernels/standard_4k_ntsc/README.md"; \
	test -f "$$stage_vcs/kernels/standard_4k_ntsc/DCP_LEGALIZATION.md"; \
	test -f "$$stage_vcs/kernels/standard_4k_ntsc/UNOFFICIAL_OPCODES.md"; \
	test -f "$$stage_vcs/kernels/standard_4k_ntsc/standard_4k_ntsc.c26"; \
	test -f "$$stage_vcs/kernels/standard_4k_ntsc/standard_4k_ntsc_kernel.s26"; \
	test -f "$$stage_vcs/kernels/standard_4k_ntsc/standard_4k_ntsc_macros.inc"; \
	test -f "$$stage_vcs/kernels/standard_4k_ntsc/vcs_standard_4k_ntsc.cfg"; \
	test -f "$$stage_vcs/kernels/standard_4k_ntsc_playercolors/README.md"; \
	test -f "$$stage_vcs/kernels/standard_4k_ntsc_playercolors/standard_4k_ntsc_playercolors.c26"; \
	test -f "$$stage_vcs/kernels/standard_4k_ntsc_playercolors/standard_4k_ntsc_playercolors_kernel.s26"; \
	test -f "$$stage_vcs/kernels/standard_4k_ntsc_playercolors/standard_4k_ntsc_playercolors_macros.inc"; \
	test -f "$$stage_vcs/kernels/standard_4k_ntsc_playercolors/vcs_standard_4k_ntsc_playercolors.cfg"; \
	"$$stage_bin/vcsc-as" \
	  -I "$$stage_vcs/kernels/standard_4k_ntsc" \
	  --map="$(INSTALLCHECK_STAGING)/standard_4k_ntsc_kernel.map" \
	  -o "$(INSTALLCHECK_STAGING)/standard_4k_ntsc_kernel.o26" \
	  "$$stage_vcs/kernels/standard_4k_ntsc/standard_4k_ntsc_kernel.s26"; \
	test `wc -c < "$(INSTALLCHECK_STAGING)/standard_4k_ntsc_kernel.o26"` -gt 0; \
	test "$$(head -c 6 "$(INSTALLCHECK_STAGING)/standard_4k_ntsc_kernel.o26" | od -An -tx1 | tr -d ' \n')" = "01006f323602"; \
	if "$$stage_bin/vcsc" -I "$$stage_vcs" \
	  -T "$$stage_vcs/kernels/standard_4k_ntsc/vcs_standard_4k_ntsc.cfg" \
	  "$(CURDIR)/test/vcs_standard_kernel_contract_smoke.c26" \
	  "$$stage_vcs/kernels/standard_4k_ntsc/standard_4k_ntsc_kernel.s26" \
	  -o "$(INSTALLCHECK_STAGING)/standard_kernel_contract_smoke.bin" \
	  >"$(INSTALLCHECK_STAGING)/standard_kernel_contract_smoke.stdout" \
	  2>"$(INSTALLCHECK_STAGING)/standard_kernel_contract_smoke.stderr"; then \
	  echo "mutable standard-kernel playfield unexpectedly linked" >&2; exit 1; \
	fi; \
	test ! -s "$(INSTALLCHECK_STAGING)/standard_kernel_contract_smoke.stdout"; \
	grep -q "RAM overflow" "$(INSTALLCHECK_STAGING)/standard_kernel_contract_smoke.stderr"; \
	"$$stage_bin/vcsc" -I "$$stage_vcs" \
	  -T "$$stage_vcs/kernels/standard_4k_ntsc/vcs_standard_4k_ntsc.cfg" \
	  "$(CURDIR)/test/vcs_standard_kernel_contract_rom_smoke.c26" \
	  "$$stage_vcs/kernels/standard_4k_ntsc/standard_4k_ntsc_kernel.s26" \
	  -o "$(INSTALLCHECK_STAGING)/standard_kernel_contract_rom_smoke.bin"; \
	test `wc -c < "$(INSTALLCHECK_STAGING)/standard_kernel_contract_rom_smoke.bin"` -eq 4096; \
	for spec in \
	  05_multicolor_full_static/multicolor_full_static \
	  06_multicolor_score_above_static/multicolor_score_above_static \
	  07_multicolor_score_below_static/multicolor_score_below_static \
	  08_multicolor_full_dynamic_x_motion/multicolor_full_dynamic_x_motion \
	  09_multicolor_score_above_dynamic_x_motion/multicolor_score_above_dynamic_x_motion \
	  10_multicolor_score_below_dynamic_x_motion/multicolor_score_below_dynamic_x_motion \
	  11_multicolor_full_dynamic_x_and_y_motion/multicolor_full_dynamic_x_and_y_motion \
	  12_multicolor_score_above_dynamic_x_and_y_motion/multicolor_score_above_dynamic_x_and_y_motion \
	  13_multicolor_score_below_dynamic_x_and_y_motion/multicolor_score_below_dynamic_x_and_y_motion; do \
	  dir=$${spec%/*}; stem=$${spec#*/}; \
	  "$$stage_bin/vcsc" -I "$$stage_vcs" \
	    "$(CURDIR)/examples/$$dir/$$stem.c26" \
	    -o "$(INSTALLCHECK_STAGING)/$$stem.bin"; \
	  test `wc -c < "$(INSTALLCHECK_STAGING)/$$stem.bin"` -eq 4096; \
	done
	rm -rf $(INSTALLCHECK_STAGING)

tar:
	rm -f ../`basename $$(git rev-parse --show-toplevel)`.*.tar.gz
	git ls-files | tar -czv -T - -f /tmp/`basename $$(git rev-parse --show-toplevel)`.`date -u "+%Y%m%d_%H%M%S"`.tar.gz

unit: tools
	@$(MAKE) --no-print-directory -C ./test unit

sieve: tools
	./driver/vcsc -I test -T test/generic_6502.cfg test/sieve.c26 -o sieve.hex
	simulator/vcsc-sim sieve.hex | head

e2e: tools
	@$(MAKE) --no-print-directory -C ./test e2e

test: tools
	@$(MAKE) --no-print-directory -C ./test test

.PHONY: all tools install install-core install-data uninstall uninstall-data package installcheck tarball unit sieve e2e test docs
