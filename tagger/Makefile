CC = gcc
CFLAGS = -std=c11 -Wall -Wextra -Werror -pedantic -O2

BINDIR ?= /opt/vcsc/bin
DESTDIR ?=
INSTALL ?= install
INSTALL_PROGRAM ?= $(INSTALL) -m 0755
DOXYGEN ?= doxygen

all: version.h vcsc-tag

.PHONY: version FORCE
version: version.h

version.h: FORCE
	perl ../gen_version_h.pl $@

vcsc-tag: tagger.c version.h
	$(CC) $(CFLAGS) tagger.c -o vcsc-tag

docs:
	$(MAKE) --no-print-directory -C .. docs

install: vcsc-tag
	$(INSTALL) -d $(DESTDIR)$(BINDIR)
	$(INSTALL_PROGRAM) vcsc-tag $(DESTDIR)$(BINDIR)/vcsc-tag

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/vcsc-tag

clean:
	rm -f vcsc-tag version.h

.PHONY: docs
