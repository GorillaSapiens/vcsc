ASM ?= ../../assembler/n65asm
N65AR ?= ../../archiver/n65ar
JOBS ?= 8

REPO_ASM = ../../assembler/n65asm
REPO_AR = ../../archiver/n65ar

DESTDIR ?=
LIBDIR ?= /opt/n/lib
INCLUDEDIR ?= /opt/n/include
DATADIR ?= /opt/n/share
INSTALL ?= install
INSTALL_DATA ?= $(INSTALL) -m 0644
DOXYGEN ?= doxygen

all: $(ASM) $(N65AR)
	rm -rf wrk nlib.a nlib.a65
	mkdir wrk
	./unbundle.pl
	cp *.s wrk
	set -e; find wrk -name '*.s' -print0 | sort -z | xargs -0 -n 1 -P $(JOBS) sh -c 'each="$$1"; stem=`basename "$$each" .s`; echo ===== "$$each"; $(ASM) -o "wrk/$$stem.o65" "$$each"' sh
	$(N65AR) rcs nlib.a65 wrk/*.o65

$(REPO_ASM):
	$(MAKE) --no-print-directory -C ../../assembler n65asm

$(REPO_AR):
	$(MAKE) --no-print-directory -C ../../archiver n65ar

docs:
	$(MAKE) --no-print-directory -C ../.. docs

install: all
	$(INSTALL) -d $(DESTDIR)$(LIBDIR)
	$(INSTALL) -d $(DESTDIR)$(INCLUDEDIR)
	$(INSTALL) -d $(DESTDIR)$(DATADIR)/nlib
	$(INSTALL_DATA) nlib.a65 $(DESTDIR)$(LIBDIR)/nlib.a65
	$(INSTALL_DATA) nlib.inc $(DESTDIR)$(INCLUDEDIR)/nlib.inc
	$(INSTALL_DATA) nrt0.s $(DESTDIR)$(DATADIR)/nlib/nrt0.s
	$(INSTALL_DATA) nlib_zeropage.s $(DESTDIR)$(DATADIR)/nlib/nlib_zeropage.s
	$(INSTALL_DATA) README.md $(DESTDIR)$(DATADIR)/nlib/README.md
	$(INSTALL_DATA) LICENSE $(DESTDIR)$(DATADIR)/nlib/LICENSE

uninstall:
	rm -f $(DESTDIR)$(LIBDIR)/nlib.a65
	rm -f $(DESTDIR)$(INCLUDEDIR)/nlib.inc
	rm -f $(DESTDIR)$(DATADIR)/nlib/nrt0.s
	rm -f $(DESTDIR)$(DATADIR)/nlib/nlib_zeropage.s
	rm -f $(DESTDIR)$(DATADIR)/nlib/README.md
	rm -f $(DESTDIR)$(DATADIR)/nlib/LICENSE

clean:
	rm -f *.o *.bin tests nlib.a nlib.a65 wrk/*

.PHONY: docs
