ROOT ?= ../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs

all: fingerprint.bin

fingerprint.bin: fingerprint.vcsc $(VCS_DIR)/fonts/hexadecimal_hex.vcsc $(VCS_DIR)/vcs.vcsc $(VCS_DIR)/tia.vcsc $(VCS_DIR)/riot.vcsc $(VCS_DIR)/vcs_4k.cfg
	$(VCSC) -I $(VCS_DIR) -Map fingerprint.map fingerprint.vcsc -o $@
	@test `wc -c < $@` -eq 4096

clean:
	rm -f fingerprint.bin fingerprint.hex fingerprint.map fingerprint.s

.PHONY: all clean
