CC = gcc
CFLAGS = -std=c11 -Wall -Wextra -Werror -pedantic -O2

BINDIR ?= /opt/vcsc/bin
DESTDIR ?=
INSTALL ?= install
INSTALL_PROGRAM ?= $(INSTALL) -m 0755

OBJS = vcsc_ld.o vcsc_ld_input.o vcsc_ld_abi.o
DEPS = $(OBJS:.o=.d)
DOXYGEN ?= doxygen

all: version.h vcsc-ld

.PHONY: version FORCE
version: version.h

version.h: FORCE
	@if git rev-parse --is-inside-work-tree >/dev/null 2>&1 && \
	   git rev-parse --verify HEAD >/dev/null 2>&1; then \
	   branch=$$(git branch --show-current); \
	   [ -n "$$branch" ] || branch=detached; \
	   printf '#define VERSION "%s %s %s %s"\n' \
	      "$$(date -u -d "@$$(git show -s --format=%ct HEAD)" +'%Y-%m-%d %H:%M:%SZ')" \
	      "$$branch" \
	      "$$(git rev-parse --short=12 HEAD)" \
	      "$$([ -n "$$(git status --porcelain -uno)" ] && echo modified || echo clean)" \
	      > version.h; \
	else \
	   host=$$(hostname); \
	   domain=$$(dnsdomainname 2>/dev/null || true); \
	   if [ -z "$$domain" ]; then \
	      domain=$$(awk '/^(search|domain)[[:space:]]+/ { print $$2; exit }' /etc/resolv.conf 2>/dev/null); \
	   fi; \
	   fqdn=$$host; \
	   case "$$fqdn" in *.*) ;; *) [ -n "$$domain" ] && fqdn="$$host.$$domain";; esac; \
	   printf '#define VERSION "%s nogit %s@%s clean"\n' \
	      "$$(date -u +'%Y-%m-%d %H:%M:%SZ')" \
	      "$$(whoami)" \
	      "$$fqdn" \
	      > version.h; \
	fi

vcsc-ld: version.h $(OBJS)
	$(CC) $(CFLAGS) $(OBJS) -o vcsc-ld

vcsc_ld.o: version.h

%.o: %.c
	$(CC) $(CFLAGS) -MMD -MP -c $< -o $@

docs:
	$(MAKE) --no-print-directory -C .. docs

install: vcsc-ld
	$(INSTALL) -d $(DESTDIR)$(BINDIR)
	$(INSTALL_PROGRAM) vcsc-ld $(DESTDIR)$(BINDIR)/vcsc-ld

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/vcsc-ld

clean:
	rm -f vcsc-ld $(OBJS) $(DEPS) version.h

-include $(DEPS)

.PHONY: docs
