ASM=../../assembler/n65asm
AR=../../archiver/n65ar

DESTDIR ?=
LIBDIR ?= /opt/n/lib
DATADIR ?= /opt/n/share
INSTALL ?= install
INSTALL_DATA ?= $(INSTALL) -m 0644

all:
	$(ASM) -o nrt0_int.o65 nrt0_int.s
	$(AR) rcs nint.a65 nrt0_int.o65

install: all
	$(INSTALL) -d $(DESTDIR)$(LIBDIR)
	$(INSTALL) -d $(DESTDIR)$(DATADIR)/nint
	$(INSTALL_DATA) nint.a65 $(DESTDIR)$(LIBDIR)/nint.a65
	$(INSTALL_DATA) nrt0_int.s $(DESTDIR)$(DATADIR)/nint/nrt0_int.s
	$(INSTALL_DATA) README.md $(DESTDIR)$(DATADIR)/nint/README.md
	$(INSTALL_DATA) LICENSE $(DESTDIR)$(DATADIR)/nint/LICENSE

uninstall:
	rm -f $(DESTDIR)$(LIBDIR)/nint.a65
	rm -f $(DESTDIR)$(DATADIR)/nint/nrt0_int.s
	rm -f $(DESTDIR)$(DATADIR)/nint/README.md
	rm -f $(DESTDIR)$(DATADIR)/nint/LICENSE

clean:
	rm -f nint.a65 nrt0_int.o65
