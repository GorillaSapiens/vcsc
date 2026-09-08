# This file is covered under CC0-1.0. See libraries/LICENSE.txt.

ASM ?= ../../assembler/vcsc-as
VCSC_AR ?= ../../archiver/vcsc-ar
JOBS ?= 8

REPO_ASM = ../../assembler/vcsc-as
REPO_AR = ../../archiver/vcsc-ar

DESTDIR ?=
RUNTIMEDIR ?= /opt/vcsc/libraries/runtime
INSTALL ?= install
INSTALL_DATA ?= $(INSTALL) -m 0644
DOXYGEN ?= doxygen

ZP_SOURCES = \
	vcsc-zp-arg0.s26 vcsc-zp-arg1.s26 \
	vcsc-zp-ptr0.s26 vcsc-zp-ptr1.s26 vcsc-zp-ptr2.s26

all: $(ASM) $(VCSC_AR)
	rm -rf wrk libvcsc.l26
	mkdir wrk
	./unbundle.pl
	cp *.s26 wrk
	set -e; find wrk -name '*.s26' -print0 | sort -z | xargs -0 -n 1 -P $(JOBS) sh -c 'each="$$1"; stem=`basename "$$each" .s26`; echo ===== "$$each"; $(ASM) -o "wrk/$$stem.o26" "$$each"' sh
	$(VCSC_AR) rcs libvcsc.l26 wrk/*.o26

$(REPO_ASM):
	$(MAKE) --no-print-directory -C ../../assembler vcsc-as

$(REPO_AR):
	$(MAKE) --no-print-directory -C ../../archiver vcsc-ar

docs:
	$(MAKE) --no-print-directory -C ../.. docs

install: all
	$(INSTALL) -d $(DESTDIR)$(RUNTIMEDIR)
	$(INSTALL_DATA) libvcsc.l26 vcsc-runtime.inc vcsc-rt0.s26 vcsc-rt1-data.s26 vcsc-rt1-simple.s26 $(ZP_SOURCES) README.md $(DESTDIR)$(RUNTIMEDIR)/

uninstall:
	rm -f $(addprefix $(DESTDIR)$(RUNTIMEDIR)/,libvcsc.l26 vcsc-runtime.inc vcsc-rt0.s26 vcsc-rt1-data.s26 vcsc-rt1-simple.s26 $(ZP_SOURCES) README.md)

clean:
	rm -f libvcsc.l26
	rm -rf wrk

.PHONY: docs
