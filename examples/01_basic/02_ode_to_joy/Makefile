ROOT ?= ../../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs

all: ode_to_joy.bin

ode_to_joy.bin: ode_to_joy.c26 $(VCS_DIR)/vcs.c26 $(VCS_DIR)/tia.c26 $(VCS_DIR)/riot.c26 $(VCS_DIR)/sound_ntsc.c26 $(VCS_DIR)/vcs_4k.cfg
	$(VCSC) -I $(VCS_DIR) -Map ode_to_joy.map ode_to_joy.c26 -o $@
	@test `wc -c < $@` -eq 4096

clean:
	rm -f ode_to_joy.bin ode_to_joy.hex ode_to_joy.map

.PHONY: all clean
