LEX = flex
YACC = bison -Werror=conflicts-sr,conflicts-rr
CC = gcc
CFLAGS = -Wall -Wextra -Werror -pedantic
DEPFLAGS = -MMD -MP

# for debugging
CFLAGS += -g

# for yacc debugging
#CFLAGS += -DYYDEBUG

# for optimization
#CFLAGS += -O2

EXEEXT ?=
LDFLAGS ?=
TARGET = vcsc-as$(EXEEXT)

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
	perl ../gen_version_h.pl $@

$(TARGET): version.h $(GENHDR) $(GENSRC) $(OBJ)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $(TARGET) $(OBJ)

vcsc_as.o: version.h

%.o: %.c
	$(CC) -c $(CFLAGS) $(DEPFLAGS) $< -o $@

parser.tab.c parser.tab.h: parser.y
	$(YACC) -v -d -W --report=all parser.y

lex.yy.c: lexer.l
	$(LEX) lexer.l

tidy:
	rm -f vcsc-as vcsc-as.exe $(OBJ) $(DEP) *.o *.d
	
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
