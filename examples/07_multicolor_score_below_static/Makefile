ROOT ?= ../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs
PROFILE := $(VCS_DIR)/kernels/faithful_legacy_playercolors

TARGET := multicolor_score_below_static.bin
SOURCE := multicolor_score_below_static.c26

all: $(TARGET)

$(TARGET): $(SOURCE) $(VCS_DIR)/color_ntsc.c26 $(VCS_DIR)/playfield.c26 \
           $(PROFILE)/faithful_legacy_playercolors.c26 \
           $(PROFILE)/faithful_legacy_playercolors_macros.inc \
           $(PROFILE)/faithful_legacy_playercolors.cfg
	$(VCSC) -I $(VCS_DIR) -Wa,--illegals \
	  -T $(PROFILE)/faithful_legacy_playercolors.cfg \
	  -Map $(TARGET:.bin=.map) $(SOURCE) -o $@
	@test `wc -c < $@` -eq 4096

clean:
	rm -f $(TARGET) $(TARGET:.bin=.hex) $(TARGET:.bin=.map) $(TARGET:.bin=.s26) *.o26

.PHONY: all clean
