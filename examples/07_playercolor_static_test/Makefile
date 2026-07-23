VCSC ?= ../../driver/vcsc
VCS_DIR ?= ../../libraries/vcs
PROFILE := $(VCS_DIR)/kernels/standard_4k_ntsc_playercolors

all: playercolor_static_test.bin

playercolor_static_test.bin: playercolor_static_test.c26 $(PROFILE)/standard_4k_ntsc_playercolors.c26 \
               $(PROFILE)/standard_4k_ntsc_playercolors_kernel.s26 \
               $(PROFILE)/standard_4k_ntsc_playercolors_macros.inc \
               $(PROFILE)/vcs_standard_4k_ntsc_playercolors.cfg
	$(VCSC) -I $(VCS_DIR) -T $(PROFILE)/vcs_standard_4k_ntsc_playercolors.cfg \
	  playercolor_static_test.c26 $(PROFILE)/standard_4k_ntsc_playercolors_kernel.s26 -o $@

test: playercolor_static_test.bin
	test `wc -c < playercolor_static_test.bin` -eq 4096

clean:
	rm -f playercolor_static_test.bin *.o26 *.map

.PHONY: all test clean
