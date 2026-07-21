ASM ?= ../../assembler/vcsc-as
VCSC_AR ?= ../../archiver/vcsc-ar
JOBS ?= 8

REPO_ASM = ../../assembler/vcsc-as
REPO_AR = ../../archiver/vcsc-ar

DESTDIR ?=
LIBDIR ?= /opt/vcsc/lib
INCLUDEDIR ?= /opt/vcsc/include
DATADIR ?= /opt/vcsc/share
INSTALL ?= install
INSTALL_DATA ?= $(INSTALL) -m 0644
DOXYGEN ?= doxygen

ZP_SOURCES = \
	vcsc-zp-arg0.s vcsc-zp-arg1.s \
	vcsc-zp-ptr0.s vcsc-zp-ptr1.s vcsc-zp-ptr2.s vcsc-zp-ptr3.s \
	vcsc-zp-tmp0.s vcsc-zp-tmp1.s vcsc-zp-tmp2.s \
	vcsc-zp-tmp3.s vcsc-zp-tmp4.s vcsc-zp-tmp5.s

all: $(ASM) $(VCSC_AR)
	rm -rf wrk libvcsc.a libvcsc.l26
	mkdir wrk
	./unbundle.pl
	cp *.s wrk
	set -e; find wrk -name '*.s' -print0 | sort -z | xargs -0 -n 1 -P $(JOBS) sh -c 'each="$$1"; stem=`basename "$$each" .s`; echo ===== "$$each"; $(ASM) -o "wrk/$$stem.o26" "$$each"' sh
	$(VCSC_AR) rcs libvcsc.l26 wrk/*.o26

$(REPO_ASM):
	$(MAKE) --no-print-directory -C ../../assembler vcsc-as

$(REPO_AR):
	$(MAKE) --no-print-directory -C ../../archiver vcsc-ar

docs:
	$(MAKE) --no-print-directory -C ../.. docs

install: all
	$(INSTALL) -d $(DESTDIR)$(LIBDIR)
	$(INSTALL) -d $(DESTDIR)$(INCLUDEDIR)
	$(INSTALL) -d $(DESTDIR)$(DATADIR)/runtime
	$(INSTALL_DATA) libvcsc.l26 $(DESTDIR)$(LIBDIR)/libvcsc.l26
	$(INSTALL_DATA) vcsc-runtime.inc $(DESTDIR)$(INCLUDEDIR)/vcsc-runtime.inc
	$(INSTALL_DATA) vcsc-rt0.s $(DESTDIR)$(DATADIR)/runtime/vcsc-rt0.s
	$(INSTALL_DATA) $(ZP_SOURCES) $(DESTDIR)$(DATADIR)/runtime/
	$(INSTALL_DATA) README.md $(DESTDIR)$(DATADIR)/runtime/README.md
	$(INSTALL_DATA) LICENSE $(DESTDIR)$(DATADIR)/runtime/LICENSE

uninstall:
	rm -f $(DESTDIR)$(LIBDIR)/libvcsc.l26
	rm -f $(DESTDIR)$(INCLUDEDIR)/vcsc-runtime.inc
	rm -f $(DESTDIR)$(DATADIR)/runtime/vcsc-rt0.s
	rm -f $(addprefix $(DESTDIR)$(DATADIR)/runtime/,$(ZP_SOURCES))
	rm -f $(DESTDIR)$(DATADIR)/runtime/README.md
	rm -f $(DESTDIR)$(DATADIR)/runtime/LICENSE

clean:
	rm -f *.o *.bin tests libvcsc.a libvcsc.l26 wrk/*

.PHONY: docs
