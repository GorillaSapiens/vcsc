ROOT ?= ../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs

all: six_digit_score.bin

six_digit_score.bin: six_digit_score.vcsc score_font.s fonts/default.inc $(VCS_DIR)/vcs.vcsc $(VCS_DIR)/tia.vcsc $(VCS_DIR)/riot.vcsc $(VCS_DIR)/vcs_4k.cfg
	$(VCSC) -I $(VCS_DIR) -I . -Wa,--illegals -Map six_digit_score.map six_digit_score.vcsc score_font.s -o $@
	@test `wc -c < $@` -eq 4096

clean:
	rm -f six_digit_score.bin six_digit_score.hex six_digit_score.map

.PHONY: all clean
