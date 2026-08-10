CC = gcc
CFLAGS = -std=c11 -Wall -Wextra -Werror -pedantic -O2
LDFLAGS ?=
EXEEXT ?=
TARGET = vcsc$(EXEEXT)

BINDIR ?= /opt/vcsc/bin
DESTDIR ?=
INSTALL ?= install
INSTALL_PROGRAM ?= $(INSTALL) -m 0755
DOXYGEN ?= doxygen

all: version.h $(TARGET)

.PHONY: version FORCE
version: version.h

version.h: FORCE
	perl ../gen_version_h.pl $@

$(TARGET): vcsc.c version.h
	$(CC) $(CFLAGS) $(LDFLAGS) vcsc.c -o $(TARGET)

docs:
	$(MAKE) --no-print-directory -C .. docs

install: $(TARGET)
	$(INSTALL) -d $(DESTDIR)$(BINDIR)
	$(INSTALL_PROGRAM) $(TARGET) $(DESTDIR)$(BINDIR)/$(TARGET)

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/$(TARGET)

clean:
	rm -f vcsc vcsc.exe version.h

.PHONY: docs
