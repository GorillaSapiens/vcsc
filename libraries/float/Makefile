ASM ?= ../../assembler/n65asm
N65AR ?= ../../archiver/n65ar

REPO_ASM = ../../assembler/n65asm
REPO_AR = ../../archiver/n65ar

DESTDIR ?=
LIBDIR ?= /opt/n/lib
INCLUDEDIR ?= /opt/n/include
DATADIR ?= /opt/n/share
INSTALL ?= install
INSTALL_DATA ?= $(INSTALL) -m 0644

ASM_SOURCES := $(sort $(wildcard asm/*.s) $(wildcard asm/*.asm))
OBJECTS := $(patsubst asm/%,wrk/%,$(ASM_SOURCES:.s=.o65))
OBJECTS := $(OBJECTS:.asm=.o65)

all: float.a65

float.a65: $(ASM) $(N65AR) $(OBJECTS)
	$(N65AR) rcs $@ $(OBJECTS)

wrk:
	mkdir -p wrk

wrk/%.o65: asm/%.s | wrk
	$(ASM) -I ../nlib -o $@ $<

wrk/%.o65: asm/%.asm | wrk
	$(ASM) -I ../nlib -o $@ $<

$(REPO_ASM):
	$(MAKE) --no-print-directory -C ../../assembler n65asm

$(REPO_AR):
	$(MAKE) --no-print-directory -C ../../archiver n65ar

install: all
	$(INSTALL) -d $(DESTDIR)$(LIBDIR)
	$(INSTALL) -d $(DESTDIR)$(DATADIR)/float
	$(INSTALL_DATA) float.a65 $(DESTDIR)$(LIBDIR)/float.a65
	$(INSTALL_DATA) README.md $(DESTDIR)$(DATADIR)/float/README.md

uninstall:
	rm -f $(DESTDIR)$(LIBDIR)/float.a65
	rm -f $(DESTDIR)$(DATADIR)/float/README.md

clean:
	rm -rf wrk float.a65

.PHONY: all install uninstall clean
