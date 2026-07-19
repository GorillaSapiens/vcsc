PREFIX ?= /opt/n
DESTDIR ?=
BINDIR ?= $(PREFIX)/bin
LIBDIR ?= $(PREFIX)/lib
INCLUDEDIR ?= $(PREFIX)/include
DATADIR ?= $(PREFIX)/share
CFGDIR ?= $(DATADIR)/cfg
PACKAGE_PREFIX ?= /opt/n
PACKAGE_STAGING ?= $(CURDIR)/pkgroot
INSTALLCHECK_STAGING ?= $(CURDIR)/.installcheck-root
DOXYGEN ?= doxygen

all: test

.NOTPARALLEL:

compiler/n65c:
	@$(MAKE) --no-print-directory -C ./compiler n65c

assembler/n65asm:
	@$(MAKE) --no-print-directory -C ./assembler n65asm

archiver/n65ar:
	@$(MAKE) --no-print-directory -C ./archiver n65ar

tools: clean
	@$(MAKE) --no-print-directory -C ./assembler all
	@$(MAKE) --no-print-directory -C ./linker all
	@$(MAKE) --no-print-directory -C ./archiver all
	@$(MAKE) --no-print-directory -C ./libraries/nlib all
	@$(MAKE) --no-print-directory -C ./compiler n65c
	@$(MAKE) --no-print-directory -C ./simulator all
	@$(MAKE) --no-print-directory -C ./driver all

clean:
	@$(MAKE) --no-print-directory -C ./assembler clean
	@$(MAKE) --no-print-directory -C ./linker clean
	@$(MAKE) --no-print-directory -C ./archiver clean
	@$(MAKE) --no-print-directory -C ./libraries/nlib clean
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
	@$(MAKE) --no-print-directory -C ./libraries/nlib install DESTDIR="$(DESTDIR)" LIBDIR="$(LIBDIR)" INCLUDEDIR="$(INCLUDEDIR)" DATADIR="$(DATADIR)"
	@$(MAKE) --no-print-directory install-data DESTDIR="$(DESTDIR)" DATADIR="$(DATADIR)"

install-data:
	install -d $(DESTDIR)$(DATADIR)/vcs
	install -m 0644 libraries/vcs/README.md $(DESTDIR)$(DATADIR)/vcs/README.md
	install -m 0644 libraries/vcs/riot.n $(DESTDIR)$(DATADIR)/vcs/riot.n
	install -m 0644 libraries/vcs/tia.n $(DESTDIR)$(DATADIR)/vcs/tia.n
	install -m 0644 libraries/vcs/vcs.n $(DESTDIR)$(DATADIR)/vcs/vcs.n
	install -m 0644 libraries/vcs/vcs_4k.cfg $(DESTDIR)$(DATADIR)/vcs/vcs_4k.cfg
	install -d $(DESTDIR)$(DATADIR)/vcs/batari-basic
	install -m 0644 libraries/vcs/batari-basic/LICENSE.txt $(DESTDIR)$(DATADIR)/vcs/batari-basic/LICENSE.txt
	install -m 0644 libraries/vcs/batari-basic/OMITTED-UPSTREAM-ARTIFACTS.txt $(DESTDIR)$(DATADIR)/vcs/batari-basic/OMITTED-UPSTREAM-ARTIFACTS.txt
	install -m 0644 libraries/vcs/batari-basic/README.md $(DESTDIR)$(DATADIR)/vcs/batari-basic/README.md

uninstall:
	@$(MAKE) --no-print-directory uninstall-data DESTDIR="$(DESTDIR)" DATADIR="$(DATADIR)"
	@$(MAKE) --no-print-directory -C ./libraries/nlib uninstall DESTDIR="$(DESTDIR)" LIBDIR="$(LIBDIR)" INCLUDEDIR="$(INCLUDEDIR)" DATADIR="$(DATADIR)"
	@$(MAKE) --no-print-directory -C ./driver uninstall DESTDIR="$(DESTDIR)" BINDIR="$(BINDIR)"
	@$(MAKE) --no-print-directory -C ./simulator uninstall DESTDIR="$(DESTDIR)" BINDIR="$(BINDIR)"
	@$(MAKE) --no-print-directory -C ./compiler uninstall DESTDIR="$(DESTDIR)" BINDIR="$(BINDIR)"
	@$(MAKE) --no-print-directory -C ./archiver uninstall DESTDIR="$(DESTDIR)" BINDIR="$(BINDIR)"
	@$(MAKE) --no-print-directory -C ./linker uninstall DESTDIR="$(DESTDIR)" BINDIR="$(BINDIR)"
	@$(MAKE) --no-print-directory -C ./assembler uninstall DESTDIR="$(DESTDIR)" BINDIR="$(BINDIR)" CFGDIR="$(CFGDIR)"

uninstall-data:
	rm -f $(DESTDIR)$(DATADIR)/vcs/README.md
	rm -f $(DESTDIR)$(DATADIR)/vcs/riot.n
	rm -f $(DESTDIR)$(DATADIR)/vcs/tia.n
	rm -f $(DESTDIR)$(DATADIR)/vcs/vcs.n
	rm -f $(DESTDIR)$(DATADIR)/vcs/vcs_4k.cfg
	rm -f $(DESTDIR)$(DATADIR)/vcs/batari-basic/LICENSE.txt
	rm -f $(DESTDIR)$(DATADIR)/vcs/batari-basic/OMITTED-UPSTREAM-ARTIFACTS.txt
	rm -f $(DESTDIR)$(DATADIR)/vcs/batari-basic/README.md

package: tools
	rm -rf $(PACKAGE_STAGING)
	$(MAKE) --no-print-directory install-core DESTDIR="$(PACKAGE_STAGING)" PREFIX="$(PACKAGE_PREFIX)" BINDIR="$(PACKAGE_PREFIX)/bin" LIBDIR="$(PACKAGE_PREFIX)/lib" INCLUDEDIR="$(PACKAGE_PREFIX)/include" DATADIR="$(PACKAGE_PREFIX)/share" CFGDIR="$(PACKAGE_PREFIX)/share/cfg"
	tar -C $(PACKAGE_STAGING) -czf ./n.install.`date -u "+%Y-%m-%dT%H:%M:%SZ"`.tar.gz .

installcheck: tools
	rm -rf $(INSTALLCHECK_STAGING)
	$(MAKE) --no-print-directory install-core DESTDIR="$(INSTALLCHECK_STAGING)" PREFIX="/opt/n" BINDIR="/opt/n/bin" LIBDIR="/opt/n/lib" INCLUDEDIR="/opt/n/include" DATADIR="/opt/n/share" CFGDIR="/opt/n/share/cfg"
	stage_bin="$(INSTALLCHECK_STAGING)/opt/n/bin"; \
	"$$stage_bin/n65cc" -print-prog-name=cc1 >/dev/null; \
	"$$stage_bin/n65cc" -print-prog-name=as >/dev/null; \
	"$$stage_bin/n65cc" -I "$(CURDIR)/test" "$(CURDIR)/test/sieve.n" -o "$(INSTALLCHECK_STAGING)/sieve.hex"; \
	"$$stage_bin/n65sim" "$(INSTALLCHECK_STAGING)/sieve.hex" | head -n 1 >/dev/null

tar:
	rm -f ../`basename $$(git rev-parse --show-toplevel)`.*.tar.gz
	git ls-files | tar -czv -T - -f /tmp/`basename $$(git rev-parse --show-toplevel)`.`date "+%Y%m%d_%H%M%S"`.tar.gz

unit: tools
	@$(MAKE) --no-print-directory -C ./test unit

sieve: tools
	./driver/n65cc -I test test/sieve.n -o sieve.hex
	simulator/n65sim sieve.hex | head

e2e: tools
	@$(MAKE) --no-print-directory -C ./test e2e

test: tools
	@$(MAKE) --no-print-directory -C ./test test

.PHONY: all tools install install-core install-data uninstall uninstall-data package installcheck tarball unit sieve e2e test docs
