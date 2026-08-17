# This file is covered under CC0-1.0. See examples/LICENSE.txt.
ROOT ?= ../../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs
TARGETS := ua_diagnostic.bin uasw_diagnostic.bin

all: $(TARGETS)

ua_diagnostic.bin: ua_diagnostic.c26 ../../common/ua_diagnostic_common.c26
	$(VCSC) -I $(VCS_DIR) -T $(VCS_DIR)/vcs.cfg -Map ua_diagnostic.map ua_diagnostic.c26 -o $@

uasw_diagnostic.bin: uasw_diagnostic.c26 ../../common/ua_diagnostic_common.c26
	$(VCSC) -I $(VCS_DIR) -T $(VCS_DIR)/vcs.cfg -Map uasw_diagnostic.map uasw_diagnostic.c26 -o $@

clean:
	rm -f ua_diagnostic.bin ua_diagnostic.map ua_diagnostic.hex ua_diagnostic.sym ua_diagnostic.lst ua_diagnostic.cfg
	rm -f uasw_diagnostic.bin uasw_diagnostic.map uasw_diagnostic.hex uasw_diagnostic.sym uasw_diagnostic.lst uasw_diagnostic.cfg

play-ua: ua_diagnostic.bin
	stella -bs UA ua_diagnostic.bin

play-uasw: uasw_diagnostic.bin
	stella -bs UASW uasw_diagnostic.bin

.PHONY: all clean play-ua play-uasw
