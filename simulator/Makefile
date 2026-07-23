CC = g++
CFLAGS = -Wall -Wextra -Werror -pedantic -MMD -MP

# for debugging
CFLAGS += -g

# enable illegal opcodes
CFLAGS += -DILLEGAL_OPCODES

# for optimization
#CFLAGS += -O2

TARGET = vcsc-sim

BINDIR ?= /opt/vcsc/bin
DESTDIR ?=
INSTALL ?= install
INSTALL_PROGRAM ?= $(INSTALL) -m 0755
DOXYGEN ?= doxygen

SRCSRC = \
   mos6502/mos6502.cpp \
   main.cpp

SRC = $(SRCSRC) $(GENSRC)
OBJ = $(SRC:.cpp=.o)
DEP = $(OBJ:.o=.d)

all:
	@make --no-print-directory $(TARGET)

$(TARGET): version.h $(OBJ)
	$(CC) $(CFLAGS) -o $(TARGET) $(OBJ)

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

main.o: version.h

%.o: %.cpp
	$(CC) -c $(CFLAGS) $< -o $@

docs:
	$(MAKE) --no-print-directory -C .. docs

install: $(TARGET)
	$(INSTALL) -d $(DESTDIR)$(BINDIR)
	$(INSTALL_PROGRAM) $(TARGET) $(DESTDIR)$(BINDIR)/$(TARGET)

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/$(TARGET)

clean:
	rm -f $(TARGET) $(OBJ) $(DEP) version.h

-include $(DEP)


.PHONY: docs
