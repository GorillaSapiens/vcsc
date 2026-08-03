ROOT ?= ../../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs
SOURCE := bankswitching_diagnostic.c26

# The default set tests every source bank's JSR transitions and one representative
# direct-JMP destination.  `make full` emits every ordered JMP pair too.
all: representative superchip

representative:
	@set -e; \
	for spec in F8:2:vcs_8k_f8.cfg F6:4:vcs_16k_f6.cfg F4:8:vcs_32k_f4.cfg; do \
		mapper=$${spec%%:*}; rest=$${spec#*:}; banks=$${rest%%:*}; cfg=$${rest#*:}; \
		s=0; while test $$s -lt $$banks; do \
			mapper_lc=$$(printf '%s' "$$mapper" | tr '[:upper:]' '[:lower:]'); \
			stem=$$(printf '%s_source%d_to0' "$$mapper_lc" "$$s"); \
			$(VCSC) -I $(VCS_DIR) -DMAPPER_BANKS=$$banks -DSOURCE_BANK=$$s -DJUMP_DEST=0 \
				-T $(VCS_DIR)/$$cfg -Map $$stem.map $(SOURCE) -o $$stem.bin; \
			s=$$((s+1)); \
		done; \
	done

superchip:
	@set -e; \
	for spec in F8SC:2:vcs_8k_f8sc.cfg F6SC:4:vcs_16k_f6sc.cfg F4SC:8:vcs_32k_f4sc.cfg; do \
		mapper=$${spec%%:*}; rest=$${spec#*:}; banks=$${rest%%:*}; cfg=$${rest#*:}; \
		s=0; while test $$s -lt $$banks; do \
			mapper_lc=$$(printf '%s' "$$mapper" | tr '[:upper:]' '[:lower:]'); \
			stem=$$(printf '%s_source%d_to0' "$$mapper_lc" "$$s"); \
			$(VCSC) -I $(VCS_DIR) -DMAPPER_BANKS=$$banks -DSOURCE_BANK=$$s -DJUMP_DEST=0 -DSUPERCHIP_TEST \
				-T $(VCS_DIR)/$$cfg -Map $$stem.map $(SOURCE) -o $$stem.bin; \
			s=$$((s+1)); \
		done; \
	done

full:
	@set -e; \
	for spec in F8:2:vcs_8k_f8.cfg F6:4:vcs_16k_f6.cfg F4:8:vcs_32k_f4.cfg; do \
		mapper=$${spec%%:*}; rest=$${spec#*:}; banks=$${rest%%:*}; cfg=$${rest#*:}; \
		s=0; while test $$s -lt $$banks; do \
			d=0; while test $$d -lt $$banks; do \
				mapper_lc=$$(printf '%s' "$$mapper" | tr '[:upper:]' '[:lower:]'); \
				stem=$$(printf '%s_source%d_to%d' "$$mapper_lc" "$$s" "$$d"); \
				$(VCSC) -I $(VCS_DIR) -DMAPPER_BANKS=$$banks -DSOURCE_BANK=$$s -DJUMP_DEST=$$d \
					-T $(VCS_DIR)/$$cfg -Map $$stem.map $(SOURCE) -o $$stem.bin; \
				d=$$((d+1)); \
			done; \
			s=$$((s+1)); \
		done; \
	done

clean:
	rm -f f8_source* f6_source* f4_source* *.bin *.hex *.map *.sym *.lst *.cfg \
		.bin .hex .map .sym .lst .cfg

.PHONY: all representative superchip full clean
