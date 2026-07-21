ROOT ?= ../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs

all: six_digit_score.bin

six_digit_score.bin: six_digit_score.c26 $(VCS_DIR)/fonts/default_decimal.c26 $(VCS_DIR)/six_glyph_display.c26 $(VCS_DIR)/vcs.c26 $(VCS_DIR)/tia.c26 $(VCS_DIR)/riot.c26 $(VCS_DIR)/vcs_4k.cfg
	$(VCSC) -I $(VCS_DIR) -I . -Map six_digit_score.map six_digit_score.c26 -o $@
	@test `wc -c < $@` -eq 4096

clean:
	rm -f six_digit_score.bin six_digit_score.hex six_digit_score.map six_digit_score.s

.PHONY: all clean
