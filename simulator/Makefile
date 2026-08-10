CXX = g++
CFLAGS = -Wall -Wextra -Werror -pedantic -MMD -MP
LDFLAGS ?=
EXEEXT ?=

# for debugging
CFLAGS += -g

# enable illegal opcodes
CFLAGS += -DILLEGAL_OPCODES

# for optimization
#CFLAGS += -O2

TARGET = vcsc-sim$(EXEEXT)

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
	$(CXX) $(CFLAGS) $(LDFLAGS) -o $(TARGET) $(OBJ)

.PHONY: version FORCE
version: version.h

version.h: FORCE
	perl ../gen_version_h.pl $@

main.o: version.h

%.o: %.cpp
	$(CXX) -c $(CFLAGS) $< -o $@

docs:
	$(MAKE) --no-print-directory -C .. docs

install: $(TARGET)
	$(INSTALL) -d $(DESTDIR)$(BINDIR)
	$(INSTALL_PROGRAM) $(TARGET) $(DESTDIR)$(BINDIR)/$(TARGET)

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/$(TARGET)

clean:
	rm -f vcsc-sim vcsc-sim.exe $(OBJ) $(DEP) version.h

-include $(DEP)


.PHONY: docs
