.NOTPARALLEL:

TEST_JOBS ?= 8
TEST_TIMINGS ?= test-times.tsv

unit:
	./test.pl --jobs $(TEST_JOBS) --timings "$(TEST_TIMINGS)" --compile-only

e2e:
	./test.pl --jobs $(TEST_JOBS) --timings "$(TEST_TIMINGS)" --e2e-only

test:
	rm -f "$(TEST_TIMINGS)"
	./test.pl --jobs $(TEST_JOBS) --timings "$(TEST_TIMINGS)" --compile-only
	./test.pl --jobs $(TEST_JOBS) --timings "$(TEST_TIMINGS)" --timings-append --e2e-only

.PHONY: all unit e2e test
