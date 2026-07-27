ROOT ?= ../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs

all: blank_screen.bin

blank_screen.bin: blank_screen.c26 $(VCS_DIR)/vcs.c26 $(VCS_DIR)/tia.c26 $(VCS_DIR)/riot.c26 $(VCS_DIR)/vcs_4k.cfg
	$(VCSC) -I $(VCS_DIR) -Map blank_screen.map blank_screen.c26 -o $@
	@test `wc -c < $@` -eq 4096

clean:
	rm -f blank_screen.bin blank_screen.hex blank_screen.map

.PHONY: all clean
