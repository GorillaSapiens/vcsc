ROOT ?= ../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs
PROFILE_DIR ?= $(VCS_DIR)/kernels/standard_4k_ntsc

all: object_motion_test.bin

object_motion_test.bin: object_motion_test.c26 $(PROFILE_DIR)/standard_4k_ntsc.c26 $(PROFILE_DIR)/standard_4k_ntsc_kernel.s $(PROFILE_DIR)/standard_4k_ntsc_macros.inc $(PROFILE_DIR)/vcs_standard_4k_ntsc.cfg
	$(VCSC) -I $(VCS_DIR) -Wa,--illegals -T $(PROFILE_DIR)/vcs_standard_4k_ntsc.cfg -Map object_motion_test.map object_motion_test.c26 $(PROFILE_DIR)/standard_4k_ntsc_kernel.s -o $@
	@test `wc -c < $@` -eq 4096

clean:
	rm -f object_motion_test.bin object_motion_test.hex object_motion_test.map object_motion_test.s

.PHONY: all clean
