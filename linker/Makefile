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

all: version.h $(TARGET)

.PHONY: version FORCE
version: version.h

version.h: FORCE
	perl ../gen_version_h.pl $@

$(TARGET): version.h $(OBJS)
	$(CC) $(CFLAGS) $(LDFLAGS) $(OBJS) -o $(TARGET)

vcsc_ld.o: version.h

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
	rm -f vcsc-ld vcsc-ld.exe $(OBJS) $(DEPS) version.h

-include $(DEPS)

.PHONY: docs
