.NOTPARALLEL:

TEST_JOBS ?= 8
TEST_TIMINGS ?= test-times.tsv
TEST_SLOWEST ?= 20
STELLA ?= $(if $(VCSC_STELLA),$(VCSC_STELLA),stella)
XVFB ?= $(if $(VCSC_XVFB),$(VCSC_XVFB),Xvfb)

unit:
	./test.pl --jobs $(TEST_JOBS) --timings "$(TEST_TIMINGS)" --compile-only

e2e: stella-deps
	VCSC_STELLA="$(STELLA)" VCSC_XVFB="$(XVFB)" ./test.pl --jobs $(TEST_JOBS) --timings "$(TEST_TIMINGS)" --e2e-only

test: stella-deps
	rm -f "$(TEST_TIMINGS)"
	VCSC_STELLA="$(STELLA)" VCSC_XVFB="$(XVFB)" ./test.pl --jobs $(TEST_JOBS) --timings "$(TEST_TIMINGS)" --compile-only
	VCSC_STELLA="$(STELLA)" VCSC_XVFB="$(XVFB)" ./test.pl --jobs $(TEST_JOBS) --timings "$(TEST_TIMINGS)" --timings-append --e2e-only

stella-deps:
	@command -v "$(STELLA)" >/dev/null 2>&1 || { echo "required Stella executable not found: $(STELLA)" >&2; exit 1; }
	@command -v "$(XVFB)" >/dev/null 2>&1 || { echo "required Xvfb executable not found: $(XVFB)" >&2; exit 1; }

slow-tests:
	@test -s "$(TEST_TIMINGS)" || { echo "missing timing report: $(TEST_TIMINGS)" >&2; exit 1; }
	@printf 'seconds\tstatus\tphase\ttest\n'
	@tail -n +2 "$(TEST_TIMINGS)" | sort -nr | head -n $(TEST_SLOWEST)

.PHONY: all unit e2e test stella-deps slow-tests
