ROOT ?= ../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs

all: fingerprint.bin

fingerprint.bin: fingerprint.c26 $(VCS_DIR)/fonts/default_hex.c26 $(VCS_DIR)/six_glyph_display.c26 $(VCS_DIR)/vcs.c26 $(VCS_DIR)/tia.c26 $(VCS_DIR)/riot.c26 $(VCS_DIR)/vcs_4k.cfg
	$(VCSC) -I $(VCS_DIR) -Wa,--illegals -Map fingerprint.map fingerprint.c26 -o $@
	@test `wc -c < $@` -eq 4096

clean:
	rm -f fingerprint.bin fingerprint.hex fingerprint.map fingerprint.s

.PHONY: all clean
