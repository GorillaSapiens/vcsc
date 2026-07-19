ROOT ?= ../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs

all: solid_color.bin

solid_color.bin: solid_color.vcsc $(VCS_DIR)/vcs.vcsc $(VCS_DIR)/tia.vcsc $(VCS_DIR)/riot.vcsc $(VCS_DIR)/vcs_4k.cfg
	$(VCSC) -I $(VCS_DIR) -Map solid_color.map solid_color.vcsc -o $@
	@test `wc -c < $@` -eq 4096

clean:
	rm -f solid_color.bin solid_color.hex solid_color.map

.PHONY: all clean
