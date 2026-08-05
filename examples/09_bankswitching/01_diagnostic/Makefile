ROOT ?= ../../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs
SOURCE := bankswitching_diagnostic.c26

all: ordinary superchip poisoned

ordinary: f8.bin f6.bin f4.bin

superchip: f8sc.bin f6sc.bin f4sc.bin

poisoned: poisoned.bin

f8.bin: $(SOURCE)
	$(VCSC) -I $(VCS_DIR) -DVCS_NO_DEFAULT_ROM -DMAPPER_BANKS=2 \
		-T $(VCS_DIR)/vcs_8k_f8.cfg -Map f8.map $(SOURCE) -o $@

f6.bin: $(SOURCE)
	$(VCSC) -I $(VCS_DIR) -DVCS_NO_DEFAULT_ROM -DMAPPER_BANKS=4 \
		-T $(VCS_DIR)/vcs_16k_f6.cfg -Map f6.map $(SOURCE) -o $@

f4.bin: $(SOURCE)
	$(VCSC) -I $(VCS_DIR) -DVCS_NO_DEFAULT_ROM -DMAPPER_BANKS=8 \
		-T $(VCS_DIR)/vcs_32k_f4.cfg -Map f4.map $(SOURCE) -o $@

f8sc.bin: $(SOURCE)
	$(VCSC) -I $(VCS_DIR) -DVCS_NO_DEFAULT_ROM -DMAPPER_BANKS=2 -DSUPERCHIP_TEST \
		-T $(VCS_DIR)/vcs_8k_f8sc.cfg -Map f8sc.map $(SOURCE) -o $@

f6sc.bin: $(SOURCE)
	$(VCSC) -I $(VCS_DIR) -DVCS_NO_DEFAULT_ROM -DMAPPER_BANKS=4 -DSUPERCHIP_TEST \
		-T $(VCS_DIR)/vcs_16k_f6sc.cfg -Map f6sc.map $(SOURCE) -o $@

f4sc.bin: $(SOURCE)
	$(VCSC) -I $(VCS_DIR) -DVCS_NO_DEFAULT_ROM -DMAPPER_BANKS=8 -DSUPERCHIP_TEST \
		-T $(VCS_DIR)/vcs_32k_f4sc.cfg -Map f4sc.map $(SOURCE) -o $@

poisoned.bin: $(SOURCE)
	$(VCSC) -I $(VCS_DIR) -DVCS_NO_DEFAULT_ROM -DMAPPER_BANKS=2 -DSUPERCHIP_TEST -DPOISONED_RESULT \
		-T $(VCS_DIR)/vcs_8k_f8sc.cfg -Map poisoned.map $(SOURCE) -o $@

clean:
	rm -f f8.* f6.* f4.* f8sc.* f6sc.* f4sc.* poisoned.* \
		.bin .hex .map .sym .lst .cfg

.PHONY: all ordinary superchip poisoned clean
