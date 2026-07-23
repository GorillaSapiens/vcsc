VCSC ?= ../../driver/vcsc
VCS_DIR ?= ../../libraries/vcs
PROFILE := $(VCS_DIR)/kernels/standard_4k_ntsc_playercolors

all: playercolor_motion_test.bin

playercolor_motion_test.bin: playercolor_motion_test.c26 $(PROFILE)/standard_4k_ntsc_playercolors.c26 \
               $(PROFILE)/standard_4k_ntsc_playercolors_kernel.s26 \
               $(PROFILE)/standard_4k_ntsc_playercolors_macros.inc \
               $(PROFILE)/vcs_standard_4k_ntsc_playercolors.cfg
	$(VCSC) -I $(VCS_DIR) -T $(PROFILE)/vcs_standard_4k_ntsc_playercolors.cfg \
	  playercolor_motion_test.c26 $(PROFILE)/standard_4k_ntsc_playercolors_kernel.s26 -o $@

test: playercolor_motion_test.bin
	test `wc -c < playercolor_motion_test.bin` -eq 4096

clean:
	rm -f playercolor_motion_test.bin *.o26 *.map

.PHONY: all test clean
