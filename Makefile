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
	install -m 0644 libraries/vcs/riot.c26 $(DESTDIR)$(DATADIR)/vcs/riot.c26
	install -m 0644 libraries/vcs/six_glyph_display.c26 $(DESTDIR)$(DATADIR)/vcs/six_glyph_display.c26
	install -m 0644 libraries/vcs/tia.c26 $(DESTDIR)$(DATADIR)/vcs/tia.c26
	install -m 0644 libraries/vcs/vcs.c26 $(DESTDIR)$(DATADIR)/vcs/vcs.c26
	install -m 0644 libraries/vcs/vcs_4k.cfg $(DESTDIR)$(DATADIR)/vcs/vcs_4k.cfg
	install -d $(DESTDIR)$(DATADIR)/vcs/kernels/standard_4k_ntsc
	install -m 0644 libraries/vcs/kernels/standard_4k_ntsc/README.md \
	  libraries/vcs/kernels/standard_4k_ntsc/DCP_LEGALIZATION.md \
	  libraries/vcs/kernels/standard_4k_ntsc/UNOFFICIAL_OPCODES.md \
	  libraries/vcs/kernels/standard_4k_ntsc/standard_4k_ntsc_unofficial_opcodes.tsv \
	  libraries/vcs/kernels/standard_4k_ntsc/standard_4k_ntsc.c26 \
	  libraries/vcs/kernels/standard_4k_ntsc/standard_4k_ntsc_kernel.s26 \
	  libraries/vcs/kernels/standard_4k_ntsc/standard_4k_ntsc_macros.inc \
	  libraries/vcs/kernels/standard_4k_ntsc/vcs_standard_4k_ntsc.cfg \
	  $(DESTDIR)$(DATADIR)/vcs/kernels/standard_4k_ntsc/
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
	rm -f $(DESTDIR)$(DATADIR)/vcs/riot.c26
	rm -f $(DESTDIR)$(DATADIR)/vcs/six_glyph_display.c26
	rm -f $(DESTDIR)$(DATADIR)/vcs/tia.c26
	rm -f $(DESTDIR)$(DATADIR)/vcs/vcs.c26
	rm -f $(DESTDIR)$(DATADIR)/vcs/vcs_4k.cfg
	rm -f $(DESTDIR)$(DATADIR)/vcs/kernels/standard_4k_ntsc/README.md
	rm -f $(DESTDIR)$(DATADIR)/vcs/kernels/standard_4k_ntsc/DCP_LEGALIZATION.md
	rm -f $(DESTDIR)$(DATADIR)/vcs/kernels/standard_4k_ntsc/UNOFFICIAL_OPCODES.md
	rm -f $(DESTDIR)$(DATADIR)/vcs/kernels/standard_4k_ntsc/standard_4k_ntsc_unofficial_opcodes.tsv
	rm -f $(DESTDIR)$(DATADIR)/vcs/kernels/standard_4k_ntsc/standard_4k_ntsc.c26
	rm -f $(DESTDIR)$(DATADIR)/vcs/kernels/standard_4k_ntsc/standard_4k_ntsc_kernel.s26
	rm -f $(DESTDIR)$(DATADIR)/vcs/kernels/standard_4k_ntsc/standard_4k_ntsc_macros.inc
	rm -f $(DESTDIR)$(DATADIR)/vcs/kernels/standard_4k_ntsc/vcs_standard_4k_ntsc.cfg
	rmdir $(DESTDIR)$(DATADIR)/vcs/kernels/standard_4k_ntsc 2>/dev/null || true
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
	tar -C $(PACKAGE_STAGING) -czf ./vcsc.install.`date -u "+%Y-%m-%dT%H:%M:%SZ"`.tar.gz .

installcheck: tools
	rm -rf $(INSTALLCHECK_STAGING)
	$(MAKE) --no-print-directory install-core DESTDIR="$(INSTALLCHECK_STAGING)" PREFIX="/opt/vcsc" BINDIR="/opt/vcsc/bin" LIBDIR="/opt/vcsc/lib" INCLUDEDIR="/opt/vcsc/include" DATADIR="/opt/vcsc/share" CFGDIR="/opt/vcsc/share/cfg"
	stage_bin="$(INSTALLCHECK_STAGING)/opt/vcsc/bin"; \
	stage_vcs="$(INSTALLCHECK_STAGING)/opt/vcsc/share/vcs"; \
	"$$stage_bin/vcsc" -print-prog-name=cc1 >/dev/null; \
	"$$stage_bin/vcsc" -print-prog-name=as >/dev/null; \
	"$$stage_bin/vcsc" -I "$$stage_vcs" "$(CURDIR)/examples/01_solid_color/solid_color.c26" -o "$(INSTALLCHECK_STAGING)/solid_color.bin"; \
	test `wc -c < "$(INSTALLCHECK_STAGING)/solid_color.bin"` -eq 4096; \
	"$$stage_bin/vcsc" -I "$$stage_vcs" "$(CURDIR)/test/vcs_headers_smoke_test.c26" -o "$(INSTALLCHECK_STAGING)/vcs_headers_smoke.bin"; \
	test `wc -c < "$(INSTALLCHECK_STAGING)/vcs_headers_smoke.bin"` -eq 4096; \
	"$$stage_bin/vcsc" -I "$$stage_vcs" -I "$(CURDIR)/examples/03_six_digit_score" \
	  "$(CURDIR)/examples/03_six_digit_score/six_digit_score.c26" \
	  -o "$(INSTALLCHECK_STAGING)/six_digit_score.bin"; \
	test `wc -c < "$(INSTALLCHECK_STAGING)/six_digit_score.bin"` -eq 4096; \
	"$$stage_bin/vcsc" -I "$$stage_vcs" -Wa,--illegals \
	  "$(CURDIR)/examples/04_fingerprint/fingerprint.c26" \
	  -o "$(INSTALLCHECK_STAGING)/fingerprint.bin"; \
	test `wc -c < "$(INSTALLCHECK_STAGING)/fingerprint.bin"` -eq 4096; \
	test -f "$$stage_vcs/kernels/standard_4k_ntsc/README.md"; \
	test -f "$$stage_vcs/kernels/standard_4k_ntsc/DCP_LEGALIZATION.md"; \
	test -f "$$stage_vcs/kernels/standard_4k_ntsc/UNOFFICIAL_OPCODES.md"; \
	test -f "$$stage_vcs/kernels/standard_4k_ntsc/standard_4k_ntsc_unofficial_opcodes.tsv"; \
	test -f "$$stage_vcs/kernels/standard_4k_ntsc/standard_4k_ntsc.c26"; \
	test -f "$$stage_vcs/kernels/standard_4k_ntsc/standard_4k_ntsc_kernel.s26"; \
	test -f "$$stage_vcs/kernels/standard_4k_ntsc/standard_4k_ntsc_macros.inc"; \
	test -f "$$stage_vcs/kernels/standard_4k_ntsc/vcs_standard_4k_ntsc.cfg"; \
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
	"$$stage_bin/vcsc" -I "$$stage_vcs" \
	  -T "$$stage_vcs/kernels/standard_4k_ntsc/vcs_standard_4k_ntsc.cfg" \
	  "$(CURDIR)/examples/05_static_kernel_test/static_kernel_test.c26" \
	  "$$stage_vcs/kernels/standard_4k_ntsc/standard_4k_ntsc_kernel.s26" \
	  -o "$(INSTALLCHECK_STAGING)/static_kernel_test.bin"; \
	test `wc -c < "$(INSTALLCHECK_STAGING)/static_kernel_test.bin"` -eq 4096; \
	"$$stage_bin/vcsc" -I "$$stage_vcs" \
	  -T "$$stage_vcs/kernels/standard_4k_ntsc/vcs_standard_4k_ntsc.cfg" \
	  "$(CURDIR)/examples/06_object_motion_test/object_motion_test.c26" \
	  "$$stage_vcs/kernels/standard_4k_ntsc/standard_4k_ntsc_kernel.s26" \
	  -o "$(INSTALLCHECK_STAGING)/object_motion_test.bin"; \
	test `wc -c < "$(INSTALLCHECK_STAGING)/object_motion_test.bin"` -eq 4096

tar:
	rm -f ../`basename $$(git rev-parse --show-toplevel)`.*.tar.gz
	git ls-files | tar -czv -T - -f /tmp/`basename $$(git rev-parse --show-toplevel)`.`date "+%Y%m%d_%H%M%S"`.tar.gz

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
