CXX ?= c++
CPPFLAGS += $(shell pkg-config --cflags libpng)
CXXFLAGS ?= -O2 -g
CXXFLAGS += -std=c++17 -Wall -Wextra -Wpedantic
LDLIBS += $(shell pkg-config --libs libpng)

all: rawstream2png

rawstream2png: main.cpp
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $(LDFLAGS) -o $@ $< $(LDLIBS)

clean:
	rm -f rawstream2png

.PHONY: all clean
