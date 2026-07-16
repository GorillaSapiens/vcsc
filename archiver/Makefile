CC ?= cc
CFLAGS ?= -O2
WARNINGS = -Wall -Wextra -Werror -pedantic

BINDIR ?= /opt/n/bin
DESTDIR ?=
INSTALL ?= install
INSTALL_PROGRAM ?= $(INSTALL) -m 0755
DOXYGEN ?= doxygen

all: version.h n65ar

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

n65ar: n65ar.c version.h
	$(CC) $(CFLAGS) $(WARNINGS) -o $@ n65ar.c

docs:
	$(MAKE) --no-print-directory -C .. docs

install: n65ar
	$(INSTALL) -d $(DESTDIR)$(BINDIR)
	$(INSTALL_PROGRAM) n65ar $(DESTDIR)$(BINDIR)/n65ar

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/n65ar

clean:
	rm -f n65ar version.h

.PHONY: docs
