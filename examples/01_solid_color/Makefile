ROOT ?= ../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs

all: solid_color.bin

solid_color.bin: solid_color.c26 $(VCS_DIR)/vcs.c26 $(VCS_DIR)/tia.c26 $(VCS_DIR)/riot.c26 $(VCS_DIR)/vcs_4k.cfg
	$(VCSC) -I $(VCS_DIR) -Map solid_color.map solid_color.c26 -o $@
	@test `wc -c < $@` -eq 4096

clean:
	rm -f solid_color.bin solid_color.hex solid_color.map

.PHONY: all clean
