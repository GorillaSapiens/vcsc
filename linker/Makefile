CC = gcc
CFLAGS = -std=c11 -Wall -Wextra -Werror -pedantic -O2
DEPFLAGS = -MMD -MP
LDFLAGS ?=
EXEEXT ?=
TARGET = vcsc-ld$(EXEEXT)

BINDIR ?= /opt/vcsc/bin
DESTDIR ?=
INSTALL ?= install
INSTALL_PROGRAM ?= $(INSTALL) -m 0755

OBJS = vcsc_ld.o vcsc_ld_input.o vcsc_ld_abi.o
DEPS = $(OBJS:.o=.d)
DOXYGEN ?= doxygen
PERL ?= perl
VCSC_AS ?= $(if $(ASM),$(ASM),../assembler/vcsc-as)
BANKCALL_TEMPLATE_SOURCE = ../libraries/vcs/inline_bankcall.s26
BANKCALL_TEMPLATE_GENERATOR = gen_inline_bankcall_template.pl
BANKCALL_TEMPLATE_HEADER = generic_bankcall_template.h

all: version.h $(TARGET)

.PHONY: version FORCE
version: version.h

version.h: FORCE
	perl ../gen_version_h.pl $@

$(TARGET): version.h $(OBJS)
	$(CC) $(CFLAGS) $(LDFLAGS) $(OBJS) -o $(TARGET)

../assembler/vcsc-as:
	$(MAKE) --no-print-directory -C ../assembler vcsc-as

$(BANKCALL_TEMPLATE_HEADER): $(BANKCALL_TEMPLATE_SOURCE) $(BANKCALL_TEMPLATE_GENERATOR) $(VCSC_AS)
	$(PERL) $(BANKCALL_TEMPLATE_GENERATOR) $(VCSC_AS) $(BANKCALL_TEMPLATE_SOURCE) $@

vcsc_ld.o: version.h $(BANKCALL_TEMPLATE_HEADER)

%.o: %.c
	$(CC) $(CFLAGS) $(DEPFLAGS) -c $< -o $@

docs:
	$(MAKE) --no-print-directory -C .. docs

install: $(TARGET)
	$(INSTALL) -d $(DESTDIR)$(BINDIR)
	$(INSTALL_PROGRAM) $(TARGET) $(DESTDIR)$(BINDIR)/$(TARGET)

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/$(TARGET)

clean:
	rm -f vcsc-ld vcsc-ld.exe $(OBJS) $(DEPS) version.h $(BANKCALL_TEMPLATE_HEADER)

-include $(DEPS)

.PHONY: docs
