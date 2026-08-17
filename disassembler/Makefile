CC ?= gcc
CXX ?= g++
CFLAGS ?= -std=c11 -Wall -Wextra -Werror -pedantic -O2
CXXFLAGS ?= -std=c++11 -Wall -Wextra -Werror -pedantic -O2 -DILLEGAL_OPCODES
DEPFLAGS = -MMD -MP
LDFLAGS ?=
EXEEXT ?=

TARGET = vcsc-disas$(EXEEXT)

OBJ = vcsc_disas.o dynamic_video_probe.o mos6502_probe.o
DEP = $(OBJ:.o=.d)

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

vcsc_disas.o: vcsc_disas.c version.h opcode_table.inc dynamic_video_probe.h
	$(CC) $(CFLAGS) $(DEPFLAGS) -c vcsc_disas.c -o $@

dynamic_video_probe.o: dynamic_video_probe.cpp dynamic_video_probe.h ../simulator/mos6502/mos6502.h
	$(CXX) $(CXXFLAGS) $(DEPFLAGS) -c dynamic_video_probe.cpp -o $@

mos6502_probe.o: ../simulator/mos6502/mos6502.cpp ../simulator/mos6502/mos6502.h
	$(CXX) $(CXXFLAGS) $(DEPFLAGS) -c ../simulator/mos6502/mos6502.cpp -o $@

$(TARGET): $(OBJ)
	$(CXX) $(LDFLAGS) $(OBJ) -o $(TARGET)

docs:
	$(MAKE) --no-print-directory -C .. docs

install: $(TARGET)
	$(INSTALL) -d $(DESTDIR)$(BINDIR)
	$(INSTALL_PROGRAM) $(TARGET) $(DESTDIR)$(BINDIR)/$(TARGET)

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/vcsc-disas $(DESTDIR)$(BINDIR)/vcsc-disas.exe

clean:
	rm -f vcsc-disas vcsc-disas.exe $(OBJ) $(DEP) version.h opcode_table.inc opcode_table.inc.tmp

-include $(DEP)

.PHONY: docs clean install uninstall
