CC ?= gcc
CFLAGS ?= -std=c11 -Wall -Wextra -Werror -pedantic -O2
LDFLAGS ?=
EXEEXT ?=

TARGET = vcsc-disas$(EXEEXT)

BINDIR ?= /opt/vcsc/bin
DESTDIR ?=
INSTALL ?= install
INSTALL_PROGRAM ?= $(INSTALL) -m 0755
DOXYGEN ?= doxygen

all: version.h opcode_table.inc $(TARGET)

.PHONY: version FORCE
version: version.h

version.h: FORCE
	perl ../gen_version_h.pl $@

opcode_table.inc: gen_opcode_table.pl ../assembler/default.cfg
	perl ./gen_opcode_table.pl ../assembler/default.cfg > $@.tmp
	mv $@.tmp $@

$(TARGET): vcsc_disas.c version.h opcode_table.inc
	$(CC) $(CFLAGS) $(LDFLAGS) vcsc_disas.c -o $(TARGET)

docs:
	$(MAKE) --no-print-directory -C .. docs

install: $(TARGET)
	$(INSTALL) -d $(DESTDIR)$(BINDIR)
	$(INSTALL_PROGRAM) $(TARGET) $(DESTDIR)$(BINDIR)/$(TARGET)

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/vcsc-disas $(DESTDIR)$(BINDIR)/vcsc-disas.exe

clean:
	rm -f vcsc-disas vcsc-disas.exe version.h opcode_table.inc opcode_table.inc.tmp

.PHONY: docs clean install uninstall
