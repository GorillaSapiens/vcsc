PREFIX ?= /opt/vcsc
DESTDIR ?=
BINDIR ?= $(PREFIX)/bin
LIBDIR ?= $(PREFIX)/lib
INCLUDEDIR ?= $(PREFIX)/include
DATADIR ?= $(PREFIX)/share
CFGDIR ?= $(DATADIR)/cfg
EXAMPLESDIR ?= $(PREFIX)/examples
PACKAGE_PREFIX ?= /opt/vcsc
PACKAGE_STAGING ?= $(CURDIR)/pkgroot
INSTALLCHECK_STAGING ?= $(CURDIR)/.installcheck-root
DOXYGEN ?= doxygen
STELLA ?= stella
TEST_JOBS ?= 8
TEST_TIMINGS ?= $(CURDIR)/test-times.tsv
TEST_SLOWEST ?= 20
PERL ?= perl
FONT_ASCII_SOURCES := $(sort $(wildcard libraries/vcs/fonts/*_ascii.c26))

STELLA_BANK_TEST_TMP ?= $(CURDIR)/.stella-bank-test
STELLA_RENDERER_BANK_TEST_TMP ?= $(CURDIR)/.stella-renderer-bank-test
STELLA_WIDE_SCORE_TEST_TMP ?= $(CURDIR)/.stella-wide-score-test
STELLA_THREE_PLUS_THREE_SCORE_TEST_TMP ?= $(CURDIR)/.stella-three-plus-three-score-test
STELLA_PLAYER_COLOR_192_TEST_TMP ?= $(CURDIR)/.stella-player-color-192-test
STELLA_ALL_FIVE_PLAYER_COLOR_192_TEST_TMP ?= $(CURDIR)/.stella-all-five-player-color-192-test
STELLA_ALL_FIVE_PLAYER_COLOR_181_TEST_TMP ?= $(CURDIR)/.stella-all-five-player-color-181-test
STELLA_FAITHFUL_MULTISPRITE_TEST_TMP ?= $(CURDIR)/.stella-faithful-multisprite-test
STELLA_MULTISPRITE_TEST_TMP ?= $(CURDIR)/.stella-multisprite-test
STELLA_50HZ_TEST_TMP ?= $(CURDIR)/.stella-50hz-test
STELLA_DIAGNOSTIC_TEST_TMP ?= $(CURDIR)/.stella-diagnostic-test
WINDOWS_TRIPLET ?= x86_64-w64-mingw32
WINDOWS_HOST_CC ?= cc
WINDOWS_CC ?= $(WINDOWS_TRIPLET)-gcc
WINDOWS_CXX ?= $(WINDOWS_TRIPLET)-g++
WINDOWS_STRIP ?= $(WINDOWS_TRIPLET)-strip
WINDOWS_OBJDUMP ?= $(WINDOWS_TRIPLET)-objdump
WINDOWS_ZIP ?= zip
WINDOWS_LDFLAGS ?= -static
WINDOWS_STAGING ?= $(CURDIR)/.windows-package
WINDOWS_HOST_TOOLS ?= $(CURDIR)/.windows-host-tools
WINDOWS_PACKAGE_DIR ?= vcsc
LINUX_CC ?= cc
LINUX_CXX ?= c++
LINUX_STRIP ?= strip
LINUX_READELF ?= readelf
LINUX_TAR ?= tar
LINUX_LDFLAGS ?= -static
LINUX_STAGING ?= $(CURDIR)/.linux-package
LINUX_PACKAGE_DIR ?= vcsc

all: test

.NOTPARALLEL:

compiler/vcsc-cc1:
	@$(MAKE) --no-print-directory -C ./compiler vcsc-cc1$(EXEEXT)

assembler/vcsc-as:
	@$(MAKE) --no-print-directory -C ./assembler vcsc-as

archiver/vcsc-ar:
	@$(MAKE) --no-print-directory -C ./archiver vcsc-ar

disassembler/vcsc-disas:
	@$(MAKE) --no-print-directory -C ./disassembler vcsc-disas$(EXEEXT)

tools:
	@$(MAKE) --no-print-directory -C ./assembler all
	@$(MAKE) --no-print-directory -C ./linker all
	@$(MAKE) --no-print-directory -C ./archiver all
	@$(MAKE) --no-print-directory -C ./libraries/runtime all
	@$(MAKE) --no-print-directory -C ./compiler vcsc-cc1$(EXEEXT)
	@$(MAKE) --no-print-directory -C ./simulator all
	@$(MAKE) --no-print-directory -C ./driver all
	@$(MAKE) --no-print-directory -C ./disassembler all

rebuild: clean tools

.PHONY: exam exbs

fonts:
	@set -e; \
	for font in $(FONT_ASCII_SOURCES); do \
		echo ==== $$font; \
		$(PERL) libraries/vcs/fonts/make_font_subsets.pl "$$font"; \
	done; \
	for makefile in $$(find examples -type f -name Makefile | sort); do \
		if grep -q '^fonts:' "$$makefile"; then \
			dir=$${makefile%/Makefile}; \
			echo ==== $$dir; \
			$(MAKE) --no-print-directory -C "$$dir" fonts PERL="$(PERL)"; \
		fi; \
	done

exam:
	@for each in $$(find examples -type f -name Makefile \
		| sed 's|/Makefile$$||' \
		| sort); do \
		echo ==== $$each; \
		$(MAKE) -C "$$each" clean && \
		$(MAKE) -C "$$each" && \
		$(MAKE) -C "$$each" play ; \
	done
#	stella test/oracles/pristine_basic_v1.9_playercolors/faithful_legacy_playercolors.bin

exbs:
	@for each in $$(find examples/*_bankswitching -type f -name Makefile \
		| sed 's|/Makefile$$||' \
		| sort); do \
		echo ==== $$each; \
		$(MAKE) -C "$$each" clean && \
		$(MAKE) -C "$$each" && \
		$(MAKE) -C "$$each" play ; \
	done

clean:
	rm -rf $(STELLA_BANK_TEST_TMP) $(STELLA_RENDERER_BANK_TEST_TMP) $(STELLA_WIDE_SCORE_TEST_TMP) $(STELLA_THREE_PLUS_THREE_SCORE_TEST_TMP) $(STELLA_PLAYER_COLOR_192_TEST_TMP) $(STELLA_ALL_FIVE_PLAYER_COLOR_192_TEST_TMP) $(STELLA_ALL_FIVE_PLAYER_COLOR_181_TEST_TMP) $(STELLA_FAITHFUL_MULTISPRITE_TEST_TMP) $(STELLA_MULTISPRITE_TEST_TMP) $(STELLA_50HZ_TEST_TMP) $(STELLA_DIAGNOSTIC_TEST_TMP)
	rm -f test-times.tsv
	@$(MAKE) --no-print-directory -C ./assembler clean
	@$(MAKE) --no-print-directory -C ./linker clean
	@$(MAKE) --no-print-directory -C ./archiver clean
	@$(MAKE) --no-print-directory -C ./libraries/runtime clean
	@$(MAKE) --no-print-directory -C ./compiler clean
	@$(MAKE) --no-print-directory -C ./simulator clean
	@$(MAKE) --no-print-directory -C ./driver clean
	@$(MAKE) --no-print-directory -C ./disassembler clean

docs:
	mkdir -p doxygen
	$(DOXYGEN) Doxyfile

install: tools install-core install-examples

install-core:
	@$(MAKE) --no-print-directory -C ./assembler install DESTDIR="$(DESTDIR)" BINDIR="$(BINDIR)" CFGDIR="$(CFGDIR)"
	@$(MAKE) --no-print-directory -C ./linker install DESTDIR="$(DESTDIR)" BINDIR="$(BINDIR)"
	@$(MAKE) --no-print-directory -C ./archiver install DESTDIR="$(DESTDIR)" BINDIR="$(BINDIR)"
	@$(MAKE) --no-print-directory -C ./compiler install DESTDIR="$(DESTDIR)" BINDIR="$(BINDIR)"
	@$(MAKE) --no-print-directory -C ./simulator install DESTDIR="$(DESTDIR)" BINDIR="$(BINDIR)"
	@$(MAKE) --no-print-directory -C ./driver install DESTDIR="$(DESTDIR)" BINDIR="$(BINDIR)"
	@$(MAKE) --no-print-directory -C ./disassembler install DESTDIR="$(DESTDIR)" BINDIR="$(BINDIR)" EXEEXT="$(EXEEXT)"
	install -d $(DESTDIR)$(BINDIR)
	@$(MAKE) --no-print-directory -C ./libraries/runtime install DESTDIR="$(DESTDIR)" LIBDIR="$(LIBDIR)" INCLUDEDIR="$(INCLUDEDIR)" DATADIR="$(DATADIR)"
	@$(MAKE) --no-print-directory install-data DESTDIR="$(DESTDIR)" DATADIR="$(DATADIR)"

install-examples:
	$(PERL) packaging/install_manifest.pl install \
	  --manifest packaging/install.manifest --scope examples \
	  --source-root "$(CURDIR)" --dest-root "$(DESTDIR)$(EXAMPLESDIR)" \
	  --vcsc-name "vcsc$(EXEEXT)"

install-data:
	$(PERL) packaging/install_manifest.pl install \
	  --manifest packaging/install.manifest --scope data \
	  --source-root "$(CURDIR)" --dest-root "$(DESTDIR)$(DATADIR)"

uninstall:
	@$(MAKE) --no-print-directory uninstall-examples DESTDIR="$(DESTDIR)" EXAMPLESDIR="$(EXAMPLESDIR)"
	@$(MAKE) --no-print-directory uninstall-data DESTDIR="$(DESTDIR)" DATADIR="$(DATADIR)"
	@$(MAKE) --no-print-directory -C ./libraries/runtime uninstall DESTDIR="$(DESTDIR)" LIBDIR="$(LIBDIR)" INCLUDEDIR="$(INCLUDEDIR)" DATADIR="$(DATADIR)"
	@$(MAKE) --no-print-directory -C ./driver uninstall DESTDIR="$(DESTDIR)" BINDIR="$(BINDIR)"
	@$(MAKE) --no-print-directory -C ./disassembler uninstall DESTDIR="$(DESTDIR)" BINDIR="$(BINDIR)"
	@$(MAKE) --no-print-directory -C ./simulator uninstall DESTDIR="$(DESTDIR)" BINDIR="$(BINDIR)"
	@$(MAKE) --no-print-directory -C ./compiler uninstall DESTDIR="$(DESTDIR)" BINDIR="$(BINDIR)"
	@$(MAKE) --no-print-directory -C ./archiver uninstall DESTDIR="$(DESTDIR)" BINDIR="$(BINDIR)"
	@$(MAKE) --no-print-directory -C ./linker uninstall DESTDIR="$(DESTDIR)" BINDIR="$(BINDIR)"
	@$(MAKE) --no-print-directory -C ./assembler uninstall DESTDIR="$(DESTDIR)" BINDIR="$(BINDIR)" CFGDIR="$(CFGDIR)"

uninstall-examples:
	$(PERL) packaging/install_manifest.pl uninstall \
	  --manifest packaging/install.manifest --scope examples \
	  --source-root "$(CURDIR)" --dest-root "$(DESTDIR)$(EXAMPLESDIR)"

uninstall-data:
	$(PERL) packaging/install_manifest.pl uninstall \
	  --manifest packaging/install.manifest --scope data \
	  --source-root "$(CURDIR)" --dest-root "$(DESTDIR)$(DATADIR)"

package: tools
	rm -rf $(PACKAGE_STAGING)
	$(MAKE) --no-print-directory install-core DESTDIR="$(PACKAGE_STAGING)" PREFIX="$(PACKAGE_PREFIX)" BINDIR="$(PACKAGE_PREFIX)/bin" LIBDIR="$(PACKAGE_PREFIX)/lib" INCLUDEDIR="$(PACKAGE_PREFIX)/include" DATADIR="$(PACKAGE_PREFIX)/share" CFGDIR="$(PACKAGE_PREFIX)/share/cfg"
	$(MAKE) --no-print-directory install-examples DESTDIR="$(PACKAGE_STAGING)" PREFIX="$(PACKAGE_PREFIX)" EXAMPLESDIR="$(PACKAGE_PREFIX)/examples"
	tar -C $(PACKAGE_STAGING) -czf ./vcsc.install.`date -u "+%Y%m%d_%H%M%S"`.tar.gz .

stage-release-payload:
	@test -n "$(RELEASE_STAGING)" -a -n "$(RELEASE_PACKAGE_DIR)" -a -n "$(RELEASE_PLATFORM)" || \
	  { echo "stage-release-payload requires RELEASE_STAGING, RELEASE_PACKAGE_DIR, and RELEASE_PLATFORM" >&2; exit 1; }
	$(MAKE) --no-print-directory install-examples \
	  DESTDIR="$(RELEASE_STAGING)" EXAMPLESDIR="/$(RELEASE_PACKAGE_DIR)/examples" EXEEXT="$(RELEASE_EXEEXT)"
	$(PERL) packaging/install_manifest.pl install \
	  --manifest packaging/install.manifest --scope package-common --scope package-$(RELEASE_PLATFORM) \
	  --source-root "$(CURDIR)" --dest-root "$(RELEASE_STAGING)/$(RELEASE_PACKAGE_DIR)"
	$(PERL) packaging/install_manifest.pl verify \
	  --manifest packaging/install.manifest --scope data \
	  --source-root "$(CURDIR)" --dest-root "$(RELEASE_STAGING)/$(RELEASE_PACKAGE_DIR)/share"
	$(PERL) packaging/install_manifest.pl verify \
	  --manifest packaging/install.manifest --scope examples \
	  --source-root "$(CURDIR)" --dest-root "$(RELEASE_STAGING)/$(RELEASE_PACKAGE_DIR)/examples" \
	  --vcsc-name "vcsc$(RELEASE_EXEEXT)"
	$(PERL) packaging/install_manifest.pl verify \
	  --manifest packaging/install.manifest --scope package-common --scope package-$(RELEASE_PLATFORM) \
	  --source-root "$(CURDIR)" --dest-root "$(RELEASE_STAGING)/$(RELEASE_PACKAGE_DIR)"

windows:
	@command -v "$(WINDOWS_HOST_CC)" >/dev/null || { echo "missing native C compiler: $(WINDOWS_HOST_CC)" >&2; exit 1; }
	@command -v "$(WINDOWS_CC)" >/dev/null || { echo "missing Windows cross compiler: $(WINDOWS_CC)" >&2; exit 1; }
	@command -v "$(WINDOWS_CXX)" >/dev/null || { echo "missing Windows C++ cross compiler: $(WINDOWS_CXX)" >&2; exit 1; }
	@command -v "$(WINDOWS_STRIP)" >/dev/null || { echo "missing Windows strip tool: $(WINDOWS_STRIP)" >&2; exit 1; }
	@command -v "$(WINDOWS_OBJDUMP)" >/dev/null || { echo "missing Windows objdump tool: $(WINDOWS_OBJDUMP)" >&2; exit 1; }
	@command -v "$(WINDOWS_ZIP)" >/dev/null || { echo "missing zip tool: $(WINDOWS_ZIP)" >&2; exit 1; }
	@command -v bison >/dev/null || { echo "missing build tool: bison" >&2; exit 1; }
	@command -v flex >/dev/null || { echo "missing build tool: flex" >&2; exit 1; }
	rm -rf $(WINDOWS_STAGING) $(WINDOWS_HOST_TOOLS)
	$(MAKE) --no-print-directory -C ./assembler clean all CC="$(WINDOWS_HOST_CC)" EXEEXT= LDFLAGS=
	$(MAKE) --no-print-directory -C ./archiver clean all CC="$(WINDOWS_HOST_CC)" EXEEXT= LDFLAGS=
	mkdir -p $(WINDOWS_HOST_TOOLS)
	cp assembler/vcsc-as $(WINDOWS_HOST_TOOLS)/vcsc-as
	cp assembler/default.cfg assembler/illegals.cfg $(WINDOWS_HOST_TOOLS)/
	cp archiver/vcsc-ar $(WINDOWS_HOST_TOOLS)/vcsc-ar
	$(MAKE) --no-print-directory clean
	$(MAKE) --no-print-directory tools \
	  CC="$(WINDOWS_CC)" CXX="$(WINDOWS_CXX)" EXEEXT=.exe LDFLAGS="$(WINDOWS_LDFLAGS)" \
	  ASM="$(WINDOWS_HOST_TOOLS)/vcsc-as" VCSC_AR="$(WINDOWS_HOST_TOOLS)/vcsc-ar"
	$(MAKE) --no-print-directory install-core \
	  CC="$(WINDOWS_CC)" CXX="$(WINDOWS_CXX)" EXEEXT=.exe LDFLAGS="$(WINDOWS_LDFLAGS)" \
	  ASM="$(WINDOWS_HOST_TOOLS)/vcsc-as" VCSC_AR="$(WINDOWS_HOST_TOOLS)/vcsc-ar" \
	  DESTDIR="$(WINDOWS_STAGING)" \
	  BINDIR="/$(WINDOWS_PACKAGE_DIR)/bin" LIBDIR="/$(WINDOWS_PACKAGE_DIR)/lib" \
	  INCLUDEDIR="/$(WINDOWS_PACKAGE_DIR)/include" DATADIR="/$(WINDOWS_PACKAGE_DIR)/share" \
	  CFGDIR="/$(WINDOWS_PACKAGE_DIR)/share/cfg"
	$(WINDOWS_STRIP) \
	  $(WINDOWS_STAGING)/$(WINDOWS_PACKAGE_DIR)/bin/vcsc.exe \
	  $(WINDOWS_STAGING)/$(WINDOWS_PACKAGE_DIR)/bin/vcsc-cc1.exe \
	  $(WINDOWS_STAGING)/$(WINDOWS_PACKAGE_DIR)/bin/vcsc-as.exe \
	  $(WINDOWS_STAGING)/$(WINDOWS_PACKAGE_DIR)/bin/vcsc-ld.exe \
	  $(WINDOWS_STAGING)/$(WINDOWS_PACKAGE_DIR)/bin/vcsc-ar.exe \
	  $(WINDOWS_STAGING)/$(WINDOWS_PACKAGE_DIR)/bin/vcsc-sim.exe \
	  $(WINDOWS_STAGING)/$(WINDOWS_PACKAGE_DIR)/bin/vcsc-disas.exe
	$(MAKE) --no-print-directory stage-release-payload \
	  RELEASE_STAGING="$(WINDOWS_STAGING)" RELEASE_PACKAGE_DIR="$(WINDOWS_PACKAGE_DIR)" \
	  RELEASE_PLATFORM=windows RELEASE_EXEEXT=.exe
	@set -e; \
	for exe in vcsc.exe vcsc-cc1.exe vcsc-as.exe vcsc-ld.exe vcsc-ar.exe vcsc-sim.exe vcsc-disas.exe; do \
	  path="$(WINDOWS_STAGING)/$(WINDOWS_PACKAGE_DIR)/bin/$$exe"; \
	  test -f "$$path"; \
	  if "$(WINDOWS_OBJDUMP)" -p "$$path" | grep -Eiq 'DLL Name: (libgcc|libstdc\+\+|libwinpthread)[^ ]*\.dll'; then \
	    echo "$$exe still depends on a MinGW runtime DLL" >&2; \
	    "$(WINDOWS_OBJDUMP)" -p "$$path" | grep -i 'DLL Name:' >&2; \
	    exit 1; \
	  fi; \
	done
	@set -e; \
	stamp=$$(date -u "+%Y%m%d_%H%M%S"); \
	out="$(CURDIR)/vcsc.windows.$$stamp.zip"; \
	cd "$(WINDOWS_STAGING)"; \
	"$(WINDOWS_ZIP)" -qr "$$out" "$(WINDOWS_PACKAGE_DIR)"; \
	echo "created $$out"
	@rm -rf $(WINDOWS_HOST_TOOLS) $(WINDOWS_STAGING)
	@$(MAKE) --no-print-directory clean
	@cd compiler && ./coverage.pl > coverage_map.h

linux:
	@command -v "$(LINUX_CC)" >/dev/null || { echo "missing Linux C compiler: $(LINUX_CC)" >&2; exit 1; }
	@command -v "$(LINUX_CXX)" >/dev/null || { echo "missing Linux C++ compiler: $(LINUX_CXX)" >&2; exit 1; }
	@command -v "$(LINUX_STRIP)" >/dev/null || { echo "missing Linux strip tool: $(LINUX_STRIP)" >&2; exit 1; }
	@command -v "$(LINUX_READELF)" >/dev/null || { echo "missing Linux readelf tool: $(LINUX_READELF)" >&2; exit 1; }
	@command -v "$(LINUX_TAR)" >/dev/null || { echo "missing tar tool: $(LINUX_TAR)" >&2; exit 1; }
	@command -v bison >/dev/null || { echo "missing build tool: bison" >&2; exit 1; }
	@command -v flex >/dev/null || { echo "missing build tool: flex" >&2; exit 1; }
	rm -rf $(LINUX_STAGING)
	$(MAKE) --no-print-directory clean
	$(MAKE) --no-print-directory tools \
	  CC="$(LINUX_CC)" CXX="$(LINUX_CXX)" EXEEXT= LDFLAGS="$(LINUX_LDFLAGS)"
	$(MAKE) --no-print-directory install-core \
	  CC="$(LINUX_CC)" CXX="$(LINUX_CXX)" EXEEXT= LDFLAGS="$(LINUX_LDFLAGS)" \
	  DESTDIR="$(LINUX_STAGING)" \
	  BINDIR="/$(LINUX_PACKAGE_DIR)/bin" LIBDIR="/$(LINUX_PACKAGE_DIR)/lib" \
	  INCLUDEDIR="/$(LINUX_PACKAGE_DIR)/include" DATADIR="/$(LINUX_PACKAGE_DIR)/share" \
	  CFGDIR="/$(LINUX_PACKAGE_DIR)/share/cfg"
	$(LINUX_STRIP) \
	  $(LINUX_STAGING)/$(LINUX_PACKAGE_DIR)/bin/vcsc \
	  $(LINUX_STAGING)/$(LINUX_PACKAGE_DIR)/bin/vcsc-cc1 \
	  $(LINUX_STAGING)/$(LINUX_PACKAGE_DIR)/bin/vcsc-as \
	  $(LINUX_STAGING)/$(LINUX_PACKAGE_DIR)/bin/vcsc-ld \
	  $(LINUX_STAGING)/$(LINUX_PACKAGE_DIR)/bin/vcsc-ar \
	  $(LINUX_STAGING)/$(LINUX_PACKAGE_DIR)/bin/vcsc-sim \
	  $(LINUX_STAGING)/$(LINUX_PACKAGE_DIR)/bin/vcsc-disas
	$(MAKE) --no-print-directory stage-release-payload \
	  RELEASE_STAGING="$(LINUX_STAGING)" RELEASE_PACKAGE_DIR="$(LINUX_PACKAGE_DIR)" \
	  RELEASE_PLATFORM=linux RELEASE_EXEEXT=
	@set -e; \
	for exe in vcsc vcsc-cc1 vcsc-as vcsc-ld vcsc-ar vcsc-sim vcsc-disas; do \
	  path="$(LINUX_STAGING)/$(LINUX_PACKAGE_DIR)/bin/$$exe"; \
	  test -x "$$path"; \
	  if "$(LINUX_READELF)" -l "$$path" 2>/dev/null | grep -q 'Requesting program interpreter'; then \
	    echo "$$exe is dynamically linked (ELF interpreter present)" >&2; \
	    exit 1; \
	  fi; \
	  if "$(LINUX_READELF)" -d "$$path" 2>/dev/null | grep -q '(NEEDED)'; then \
	    echo "$$exe is dynamically linked (shared-library dependency present)" >&2; \
	    "$(LINUX_READELF)" -d "$$path" | grep '(NEEDED)' >&2; \
	    exit 1; \
	  fi; \
	done
	@set -e; \
	package="$(LINUX_STAGING)/$(LINUX_PACKAGE_DIR)"; \
	"$$package/bin/vcsc" -V >/dev/null; \
	"$$package/bin/vcsc-disas" -V >/dev/null; \
	cd "$$package"; \
	./bin/vcsc -I share/vcs examples/01_basic/01_blank_screen/blank_screen.c26 -o linux-package-smoke.bin; \
	test `wc -c < linux-package-smoke.bin` -eq 4096; \
	rm -f linux-package-smoke.bin linux-package-smoke.hex linux-package-smoke.map \
	  linux-package-smoke.sym linux-package-smoke.lst linux-package-smoke.cfg
	@set -e; \
	stamp=$$(date -u "+%Y%m%d_%H%M%S"); \
	out="$(CURDIR)/vcsc.linux.$$stamp.tar.gz"; \
	cd "$(LINUX_STAGING)"; \
	"$(LINUX_TAR)" -czf "$$out" "$(LINUX_PACKAGE_DIR)"; \
	echo "created $$out"
	@rm -rf $(LINUX_STAGING)
	@$(MAKE) --no-print-directory clean
	@cd compiler && ./coverage.pl > coverage_map.h

installcheck: tools
	rm -rf $(INSTALLCHECK_STAGING)
	$(MAKE) --no-print-directory install-core DESTDIR="$(INSTALLCHECK_STAGING)" PREFIX="/opt/vcsc" BINDIR="/opt/vcsc/bin" LIBDIR="/opt/vcsc/lib" INCLUDEDIR="/opt/vcsc/include" DATADIR="/opt/vcsc/share" CFGDIR="/opt/vcsc/share/cfg"
	$(MAKE) --no-print-directory install-examples DESTDIR="$(INSTALLCHECK_STAGING)" PREFIX="/opt/vcsc" EXAMPLESDIR="/opt/vcsc/examples"
	$(PERL) packaging/install_manifest.pl verify \
	  --manifest packaging/install.manifest --scope data \
	  --source-root "$(CURDIR)" --dest-root "$(INSTALLCHECK_STAGING)/opt/vcsc/share"
	$(PERL) packaging/install_manifest.pl verify \
	  --manifest packaging/install.manifest --scope examples \
	  --source-root "$(CURDIR)" --dest-root "$(INSTALLCHECK_STAGING)/opt/vcsc/examples" \
	  --vcsc-name vcsc
	@set -e; \
	stage="$(INSTALLCHECK_STAGING)/opt/vcsc"; \
	for exe in vcsc vcsc-cc1 vcsc-as vcsc-ld vcsc-ar vcsc-sim vcsc-disas; do test -x "$$stage/bin/$$exe"; done; \
	"$$stage/bin/vcsc" -V >/dev/null; \
	"$$stage/bin/vcsc-disas" -V >/dev/null; \
	$(MAKE) --no-print-directory -C "$$stage/examples/01_basic/01_blank_screen" clean all; \
	test `wc -c < "$$stage/examples/01_basic/01_blank_screen/blank_screen.bin"` -eq 4096; \
	$(MAKE) --no-print-directory -C "$$stage/examples/09_bankswitching/01_f864" clean f8.bin; \
	test `wc -c < "$$stage/examples/09_bankswitching/01_f864/f8.bin"` -eq 8192
	rm -rf $(INSTALLCHECK_STAGING)

tar:
	@set -eu; \
	out=/tmp/vcsc.`date -u "+%Y%m%d_%H%M%S"`.tar.gz; \
	if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then \
	  git ls-files -z | tar --null -czv -T - -f "$$out"; \
	else \
	  tmp=`mktemp -d`; \
	  trap 'rm -rf "$$tmp"' EXIT HUP INT TERM; \
	  git init -q "$$tmp"; \
	  GIT_DIR="$$tmp/.git" GIT_WORK_TREE="$(CURDIR)" git add -A; \
	  GIT_DIR="$$tmp/.git" GIT_WORK_TREE="$(CURDIR)" git ls-files -z | \
	    tar --null -C "$(CURDIR)" -czv -T - -f "$$out"; \
	fi; \
	echo "$$out"

patch:
	rm -f ../`basename $$(git rev-parse --show-toplevel)`.*.patch
	git diff > /tmp/`basename $$(git rev-parse --show-toplevel)`.`date -u "+%Y%m%d_%H%M%S"`.patch

unit: tools
	@$(MAKE) --no-print-directory -C ./test unit TEST_JOBS=$(TEST_JOBS) TEST_TIMINGS="$(TEST_TIMINGS)"



e2e: tools
	@$(MAKE) --no-print-directory -C ./test e2e TEST_JOBS=$(TEST_JOBS) TEST_TIMINGS="$(TEST_TIMINGS)"

test: tools
	@$(MAKE) --no-print-directory -C ./test test TEST_JOBS=$(TEST_JOBS) TEST_TIMINGS="$(TEST_TIMINGS)"

slow-tests:
	@$(MAKE) --no-print-directory -C ./test slow-tests TEST_TIMINGS="$(TEST_TIMINGS)" TEST_SLOWEST=$(TEST_SLOWEST)

stella-50hz-test: tools
	rm -rf $(STELLA_50HZ_TEST_TMP)
	VCSC_STELLA="$(STELLA)" perl test/vcs_frame_50hz_stella.pl \
	  "$(CURDIR)" "$(STELLA_50HZ_TEST_TMP)/frames"
	VCSC_STELLA="$(STELLA)" perl test/vcs_video_standard_examples_stella.pl \
	  "$(CURDIR)" "$(STELLA_50HZ_TEST_TMP)/examples"
	rm -rf $(STELLA_50HZ_TEST_TMP)

stella-diagnostic-test: tools
	rm -rf $(STELLA_DIAGNOSTIC_TEST_TMP)
	VCSC_STELLA="$(STELLA)" perl test/vcs_diagnostic_cartridge_stella.pl \
	  "$(CURDIR)" "$(STELLA_DIAGNOSTIC_TEST_TMP)"
	rm -rf $(STELLA_DIAGNOSTIC_TEST_TMP)

stella-bank-test: tools
	rm -rf $(STELLA_BANK_TEST_TMP)
	VCSC_STELLA="$(STELLA)" perl test/vcs_bankswitching_diagnostic.pl \
	  "$(CURDIR)" "$(STELLA_BANK_TEST_TMP)" --stella
	VCSC_STELLA="$(STELLA)" perl test/vcs_e0.pl \
	  "$(CURDIR)" "$(STELLA_BANK_TEST_TMP)/e0" --stella
	VCSC_STELLA="$(STELLA)" perl test/vcs_fe.pl \
	  "$(CURDIR)" "$(STELLA_BANK_TEST_TMP)/fe" --stella
	VCSC_STELLA="$(STELLA)" perl test/vcs_3f_3e.pl \
	  "$(CURDIR)" "$(STELLA_BANK_TEST_TMP)/3f3e" --stella
	VCSC_STELLA="$(STELLA)" perl test/vcs_wd.pl \
	  "$(CURDIR)" "$(STELLA_BANK_TEST_TMP)/wd" --stella
	VCSC_STELLA="$(STELLA)" perl test/vcs_dpc.pl \
	  "$(CURDIR)" "$(STELLA_BANK_TEST_TMP)/dpc" --stella
	VCSC_STELLA="$(STELLA)" perl test/vcs_fa2.pl \
	  "$(CURDIR)" "$(STELLA_BANK_TEST_TMP)/fa2" --stella
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

stella-three-plus-three-score-test: tools
	rm -rf $(STELLA_THREE_PLUS_THREE_SCORE_TEST_TMP)
	VCSC_STELLA="$(STELLA)" perl test/vcs_three_plus_three_score_stella.pl \
	  "$(CURDIR)" "$(STELLA_THREE_PLUS_THREE_SCORE_TEST_TMP)"
	rm -rf $(STELLA_THREE_PLUS_THREE_SCORE_TEST_TMP)

stella-player-color-192-test: tools
	rm -rf $(STELLA_PLAYER_COLOR_192_TEST_TMP)
	VCSC_STELLA="$(STELLA)" perl test/vcs_player_color_192_stella.pl \
	  "$(CURDIR)" "$(STELLA_PLAYER_COLOR_192_TEST_TMP)"
	rm -rf $(STELLA_PLAYER_COLOR_192_TEST_TMP)

stella-all-five-player-color-192-test: tools
	rm -rf $(STELLA_ALL_FIVE_PLAYER_COLOR_192_TEST_TMP)
	VCSC_STELLA="$(STELLA)" perl test/vcs_all_five_player_color_192_stella.pl \
	  "$(CURDIR)" "$(STELLA_ALL_FIVE_PLAYER_COLOR_192_TEST_TMP)"
	rm -rf $(STELLA_ALL_FIVE_PLAYER_COLOR_192_TEST_TMP)

stella-all-five-player-color-181-test: tools
	rm -rf $(STELLA_ALL_FIVE_PLAYER_COLOR_181_TEST_TMP)
	VCSC_STELLA="$(STELLA)" perl test/vcs_all_five_player_color_181_stella.pl \
	  "$(CURDIR)" "$(STELLA_ALL_FIVE_PLAYER_COLOR_181_TEST_TMP)"
	rm -rf $(STELLA_ALL_FIVE_PLAYER_COLOR_181_TEST_TMP)

stella-faithful-multisprite-test: tools
	rm -rf $(STELLA_FAITHFUL_MULTISPRITE_TEST_TMP)
	VCSC_STELLA="$(STELLA)" perl test/vcs_faithful_legacy_multisprite_stella.pl \
	  "$(CURDIR)" "$(STELLA_FAITHFUL_MULTISPRITE_TEST_TMP)"
	rm -rf $(STELLA_FAITHFUL_MULTISPRITE_TEST_TMP)

stella-multisprite-test: tools
	rm -rf $(STELLA_MULTISPRITE_TEST_TMP)
	VCSC_STELLA="$(STELLA)" perl test/vcs_multisprite_stella.pl \
	  "$(CURDIR)" "$(STELLA_MULTISPRITE_TEST_TMP)"
	rm -rf $(STELLA_MULTISPRITE_TEST_TMP)


.PHONY: all tools rebuild fonts install stage-release-payload install-core install-examples install-data uninstall uninstall-examples uninstall-data package windows installcheck tarball unit e2e test stella-50hz-test stella-bank-test stella-renderer-bank-test stella-wide-score-test stella-three-plus-three-score-test stella-player-color-192-test stella-all-five-player-color-192-test stella-all-five-player-color-181-test stella-faithful-multisprite-test stella-multisprite-test stella-diagnostic-test docs
