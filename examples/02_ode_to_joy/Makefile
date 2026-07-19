ROOT ?= ../..
VCSC ?= $(ROOT)/driver/n65cc
VCS_DIR ?= $(ROOT)/libraries/vcs

all: ode_to_joy.bin

ode_to_joy.bin: ode_to_joy.n $(VCS_DIR)/vcs.n $(VCS_DIR)/tia.n $(VCS_DIR)/riot.n $(VCS_DIR)/sound_ntsc.n $(VCS_DIR)/vcs_4k.cfg
	$(VCSC) -I $(VCS_DIR) -Map ode_to_joy.map ode_to_joy.n -o $@
	@test `wc -c < $@` -eq 4096

clean:
	rm -f ode_to_joy.bin ode_to_joy.hex ode_to_joy.map

.PHONY: all clean
