LEX = flex
YACC = bison -Werror=conflicts-sr,conflicts-rr
CC = gcc
CFLAGS = -Wall -Wextra -Werror -pedantic -MMD -MP

# for debugging
CFLAGS += -g

# for yacc debugging
#CFLAGS += -DYYDEBUG

# for optimization
#CFLAGS += -O2

TARGET = vcsc-as

BINDIR ?= /opt/vcsc/bin
DESTDIR ?=
CFGDIR ?= /opt/vcsc/share/cfg
INSTALL ?= install
INSTALL_PROGRAM ?= $(INSTALL) -m 0755
DOXYGEN ?= doxygen
INSTALL_DATA ?= $(INSTALL) -m 0644

GENSRC = parser.tab.c lex.yy.c
GENHDR = parser.tab.h

SRCSRC = \
   asm_pass.c \
   asm_state.c \
   directive.c \
   expr.c \
   ihex.c \
   ir.c \
   listing.c \
   o26.c \
   opcode.c \
   source_loader.c \
   symtab.c \
   util.c \
   xray.c \
   vcsc_as.c

SRC = $(SRCSRC) $(GENSRC)
OBJ = $(SRC:.c=.o)
DEP = $(OBJ:.o=.d)

all:
	@make --no-print-directory $(TARGET)

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

$(TARGET): version.h $(GENHDR) $(GENSRC) $(OBJ)
	$(CC) $(CFLAGS) -o $(TARGET) $(OBJ)

vcsc_as.o: version.h

%.o: %.c
	$(CC) -c $(CFLAGS) $< -o $@

parser.tab.c parser.tab.h: parser.y
	$(YACC) -v -d -W --report=all parser.y

lex.yy.c: lexer.l
	$(LEX) lexer.l

tidy:
	rm -f $(TARGET) $(OBJ) $(DEP) *.o *.d
	
docs:
	$(MAKE) --no-print-directory -C .. docs

install: $(TARGET)
	$(INSTALL) -d $(DESTDIR)$(BINDIR)
	$(INSTALL) -d $(DESTDIR)$(CFGDIR)
	$(INSTALL_PROGRAM) $(TARGET) $(DESTDIR)$(BINDIR)/$(TARGET)
	$(INSTALL_DATA) default.cfg $(DESTDIR)$(CFGDIR)/default.cfg
	$(INSTALL_DATA) illegals.cfg $(DESTDIR)$(CFGDIR)/illegals.cfg

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/$(TARGET)
	rm -f $(DESTDIR)$(CFGDIR)/default.cfg
	rm -f $(DESTDIR)$(CFGDIR)/illegals.cfg

clean: tidy
	rm -f $(GENSRC) $(GENHDR) parser.output version.h

-include $(DEP)


.PHONY: docs
