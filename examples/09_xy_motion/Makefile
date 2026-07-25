ROOT ?= ../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs

all: xy_motion.bin

xy_motion.bin: xy_motion.c26
	$(VCSC) -I $(VCS_DIR) -Map xy_motion.map xy_motion.c26 -o $@
	@test `wc -c < $@` -eq 4096

clean:
	rm -f xy_motion.bin xy_motion.hex xy_motion.map xy_motion.s26 *.o26

.PHONY: all clean
