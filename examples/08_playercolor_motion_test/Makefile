ROOT ?= ../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs

TARGET := playercolor_motion_test.bin
SOURCE := playercolor_motion_test.c26

all: $(TARGET)

$(TARGET): $(SOURCE)
	$(VCSC) -I $(VCS_DIR) -Map $(TARGET:.bin=.map) $(SOURCE) -o $@
	@test `wc -c < $@` -eq 4096

clean:
	rm -f $(TARGET) $(TARGET:.bin=.hex) $(TARGET:.bin=.map) $(TARGET:.bin=.s26) *.o26

.PHONY: all clean
