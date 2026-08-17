CC = gcc
CFLAGS = -std=c11 -Wall -Wextra -Werror -pedantic -O2
DEPFLAGS = -MMD -MP
LDFLAGS ?=
EXEEXT ?=
TARGET = vcsc$(EXEEXT)

SRC = vcsc.c inline_profit.c
OBJ = $(SRC:.c=.o)
DEP = $(OBJ:.o=.d)

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

$(TARGET): version.h $(OBJ)
	$(CC) $(CFLAGS) $(LDFLAGS) $(OBJ) -o $(TARGET)

vcsc.o: version.h

%.o: %.c
	$(CC) $(CFLAGS) $(DEPFLAGS) -c $< -o $@

docs:
	$(MAKE) --no-print-directory -C .. docs

install: $(TARGET)
	$(INSTALL) -d $(DESTDIR)$(BINDIR)
	$(INSTALL_PROGRAM) $(TARGET) $(DESTDIR)$(BINDIR)/$(TARGET)

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/$(TARGET)

clean:
	rm -f vcsc vcsc.exe $(OBJ) $(DEP) version.h

-include $(DEP)

.PHONY: docs
