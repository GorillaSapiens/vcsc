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

TARGET = vcsc-cc1

BINDIR ?= /opt/vcsc/bin
DESTDIR ?=
INSTALL ?= install
INSTALL_PROGRAM ?= $(INSTALL) -m 0755
DOXYGEN ?= doxygen
INSTALL_DATA ?= $(INSTALL) -m 0644
TEST   = test

GENSRC = parser.tab.c lex.yy.c
GENHDR = parser.tab.h delexer.h

SRCSRC = \
   abi_meta.c \
   ast.c \
   compile.c \
   compile_call.c \
   compile_declarator.c \
   compile_expr.c \
   compile_expr_slot.c \
   compile_expr_ops.c \
   compile_expr_flow.c \
   compile_expr_info.c \
   compile_function.c \
   compile_init.c \
   compile_lvalue.c \
   compile_literal.c \
   compile_function_registry.c \
   compile_stmt.c \
   compile_support.c \
   compile_toplevel.c \
   compile_type.c \
   coverage.c \
   emit.c \
   enumname.c \
   expropt.c \
   integer.c \
   md5.c \
   md5seen.c \
   memname.c \
   messages.c \
   pair.c \
   set.c \
   typename.c \
   xform.c \
   xray.c \
   vcsc_cc1.c

SRC = $(SRCSRC) $(GENSRC)
OBJ = $(SRC:.c=.o)
DEP = $(OBJ:.o=.d)

all:
	@make --no-print-directory $(TARGET)
	@make --no-print-directory $(TEST)

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

part:
	@make --no-print-directory clean
	@make --no-print-directory $(TARGET)

test:
	(cd ../test; ./test.pl --compile-only)

$(TARGET): version.h coverage_map.h $(GENHDR) $(GENSRC) $(OBJ)
	$(CC) $(CFLAGS) -o $(TARGET) $(OBJ)

vcsc_cc1.o: version.h

%.o: %.c
	$(CC) -c $(CFLAGS) $< -o $@

parser.tab.c parser.tab.h: parser.y
	./check_parser.pl parser.y
	$(YACC) -v -d -W --report=all parser.y

lex.yy.c: lexer.l
	$(LEX) lexer.l

delexer.h: lexer.l delexer.pl
	./delexer.pl > delexer.h

coverage_map.h: parser.y coverage.pl
	./coverage.pl > coverage_map.h

docs:
	$(MAKE) --no-print-directory -C .. docs

install: $(TARGET)
	$(INSTALL) -d $(DESTDIR)$(BINDIR)
	$(INSTALL_PROGRAM) $(TARGET) $(DESTDIR)$(BINDIR)/$(TARGET)

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/$(TARGET)

clean:
	rm -f $(TARGET) $(OBJ) $(DEP)
	rm -f $(GENSRC) $(GENHDR) parser.output version.h

-include $(DEP)


.PHONY: docs
