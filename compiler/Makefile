LEX = flex
YACC = bison -Werror=conflicts-sr,conflicts-rr
CC = gcc
CFLAGS = -Wall -Wextra -Werror -pedantic
DEPFLAGS = -MMD -MP
LDFLAGS ?=
EXEEXT ?=

# for debugging
CFLAGS += -g

# for yacc debugging
#CFLAGS += -DYYDEBUG

# for optimization
#CFLAGS += -O2

TARGET = vcsc-cc1$(EXEEXT)

BINDIR ?= /opt/vcsc/bin
DESTDIR ?=
INSTALL ?= install
INSTALL_PROGRAM ?= $(INSTALL) -m 0755
DOXYGEN ?= doxygen
INSTALL_DATA ?= $(INSTALL) -m 0644
TEST   = test

GENSRC = parser.tab.c lex.yy.c
GENHDR = parser.tab.h delexer.h coverage_map.h

SRCSRC = \
   abi_meta.c \
   ast.c \
   builtin.c \
   builtin_rgb.c \
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
   compile_inline_analysis.c \
   compile_inline_prepass.c \
   compile_inline_inliner.c \
   compile_inline_identity.c \
   compile_inline_legality.c \
   compile_inline_specialize.c \
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
	perl ../gen_version_h.pl $@

part:
	@make --no-print-directory clean
	@make --no-print-directory $(TARGET)

test:
	(cd ../test; ./test.pl --compile-only)

$(TARGET): version.h $(GENHDR) $(GENSRC) $(OBJ)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $(TARGET) $(OBJ)

vcsc_cc1.o: version.h

%.o: %.c
	$(CC) -c $(CFLAGS) $(DEPFLAGS) $< -o $@

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
	rm -f vcsc-cc1 vcsc-cc1.exe $(OBJ) $(DEP)
	rm -f $(GENSRC) $(GENHDR) parser.output version.h

-include $(DEP)


.PHONY: docs
