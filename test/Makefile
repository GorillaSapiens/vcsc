.NOTPARALLEL:

TEST_JOBS ?= 8
TEST_TIMINGS ?= test-times.tsv
TEST_SLOWEST ?= 20

unit:
	./test.pl --jobs $(TEST_JOBS) --timings "$(TEST_TIMINGS)" --compile-only

e2e:
	./test.pl --jobs $(TEST_JOBS) --timings "$(TEST_TIMINGS)" --e2e-only

test:
	rm -f "$(TEST_TIMINGS)"
	./test.pl --jobs $(TEST_JOBS) --timings "$(TEST_TIMINGS)" --compile-only
	./test.pl --jobs $(TEST_JOBS) --timings "$(TEST_TIMINGS)" --timings-append --e2e-only

slow-tests:
	@test -s "$(TEST_TIMINGS)" || { echo "missing timing report: $(TEST_TIMINGS)" >&2; exit 1; }
	@printf 'seconds\tstatus\tphase\ttest\n'
	@tail -n +2 "$(TEST_TIMINGS)" | sort -nr | head -n $(TEST_SLOWEST)

.PHONY: all unit e2e test slow-tests
