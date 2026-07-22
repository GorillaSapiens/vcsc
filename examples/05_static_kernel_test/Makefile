ROOT ?= ../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs
PROFILE_DIR ?= $(VCS_DIR)/kernels/standard_4k_ntsc

all: static_kernel_test.bin

static_kernel_test.bin: static_kernel_test.c26 static_kernel_playfield.s $(PROFILE_DIR)/standard_4k_ntsc.c26 $(PROFILE_DIR)/standard_4k_ntsc_kernel.s $(PROFILE_DIR)/standard_4k_ntsc_macros.inc $(PROFILE_DIR)/vcs_standard_4k_ntsc.cfg
	$(VCSC) -I $(VCS_DIR) -Wa,--illegals -T $(PROFILE_DIR)/vcs_standard_4k_ntsc.cfg -Map static_kernel_test.map static_kernel_playfield.s static_kernel_test.c26 $(PROFILE_DIR)/standard_4k_ntsc_kernel.s -o $@
	@test `wc -c < $@` -eq 4096

clean:
	rm -f static_kernel_test.bin static_kernel_test.hex static_kernel_test.map static_kernel_test.s

.PHONY: all clean
