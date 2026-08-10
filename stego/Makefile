CC = gcc
CFLAGS = -std=c11 -Wall -Wextra -Werror -pedantic -O2

BINDIR ?= /opt/vcsc/bin
DESTDIR ?=
INSTALL ?= install
INSTALL_PROGRAM ?= $(INSTALL) -m 0755
DOXYGEN ?= doxygen

all: version.h stego

.PHONY: version FORCE
version: version.h

version.h: FORCE
	perl ../gen_version_h.pl $@

stego: stego.c version.h
	$(CC) $(CFLAGS) stego.c -o stego

docs:
	$(MAKE) --no-print-directory -C .. docs

install: stego
	$(INSTALL) -d $(DESTDIR)$(BINDIR)
	$(INSTALL_PROGRAM) stego $(DESTDIR)$(BINDIR)/stego

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/stego

clean:
	rm -f stego version.h

.PHONY: docs
