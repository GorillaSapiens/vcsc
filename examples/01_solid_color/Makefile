ROOT ?= ../..
N65CC ?= $(ROOT)/driver/n65cc
VCS_DIR ?= $(ROOT)/libraries/vcs

all: solid_color.bin

solid_color.bin: solid_color.n $(VCS_DIR)/vcs.n $(VCS_DIR)/tia.n $(VCS_DIR)/riot.n $(VCS_DIR)/vcs_4k.cfg
	$(N65CC) -I $(VCS_DIR) -Map solid_color.map solid_color.n -o $@
	@test `wc -c < $@` -eq 4096

clean:
	rm -f solid_color.bin solid_color.hex solid_color.map

.PHONY: all clean
