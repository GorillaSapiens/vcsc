ROOT ?= ../../../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs

TARGET := player_color_181_left_justified_score_above_interactive.bin
SOURCE := player_color_181_left_justified_score_above_interactive.c26

all: $(TARGET)

$(TARGET): $(SOURCE) $(VCS_DIR)/color_ntsc.c26 \
           $(VCS_DIR)/frame_ntsc.c26 \
           $(VCS_DIR)/playfield.c26 \
           $(VCS_DIR)/six_glyph_left_component.c26 \
           $(VCS_DIR)/renderers/player_color_181/player_color_181.c26 \
           $(ROOT)/examples/common/fixed_six_digit_controls.c26 \
           $(ROOT)/examples/common/player_color_181_interactive_common.c26 \
           $(VCS_DIR)/fonts/default_decimal.c26
	$(VCSC) -I $(VCS_DIR) -Map $(TARGET:.bin=.map) $(SOURCE) -o $@
	@test `wc -c < $@` -eq 4096

clean:
	rm -f $(TARGET) $(TARGET:.bin=.hex) $(TARGET:.bin=.map) $(TARGET:.bin=.s26) *.o26 $(TARGET:.bin=.sym) $(TARGET:.bin=.lst) $(TARGET:.bin=.cfg)

.PHONY: all clean
