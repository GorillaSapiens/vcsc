CC ?= cc
CFLAGS ?= -O2
WARNINGS = -Wall -Wextra -Werror -pedantic
DEPFLAGS = -MMD -MP
LDFLAGS ?=
EXEEXT ?=
TARGET = vcsc-ar$(EXEEXT)

OBJ = vcsc_ar.o
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
	$(CC) $(CFLAGS) $(WARNINGS) $(LDFLAGS) -o $@ $(OBJ)

vcsc_ar.o: version.h

%.o: %.c
	$(CC) $(CFLAGS) $(WARNINGS) $(DEPFLAGS) -c $< -o $@

docs:
	$(MAKE) --no-print-directory -C .. docs

install: $(TARGET)
	$(INSTALL) -d $(DESTDIR)$(BINDIR)
	$(INSTALL_PROGRAM) $(TARGET) $(DESTDIR)$(BINDIR)/$(TARGET)

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/$(TARGET)

clean:
	rm -f vcsc-ar vcsc-ar.exe $(OBJ) $(DEP) version.h

-include $(DEP)

.PHONY: docs
