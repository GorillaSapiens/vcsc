.NOTPARALLEL:

GENERATED_FLOAT_ARCHIVE_FIXTURES = \
	$(wildcard generated_float_archive_gf32_*.n) \
	$(wildcard generated_float_archive_gf3be_*.n) \
	$(wildcard generated_float_archive_gf10_*.n)

all: test

generated_float_archive_fixtures:
	tmpdir=$$(mktemp -d); \
	trap 'rm -rf "$$tmpdir"' 0 1 2 3 15; \
	perl ../libraries/float/n65_gen_float.pl --build "$$tmpdir/gf32" gf32 little 4 8; \
	for f in "$$tmpdir/gf32"/gf32_*.n; do \
		cp "$$f" "generated_float_archive_$$(basename "$$f")"; \
	done; \
	perl ../libraries/float/n65_gen_float.pl --build "$$tmpdir/gf3be" gf3be big 3 7; \
	for f in "$$tmpdir/gf3be"/gf3be_*.n; do \
		cp "$$f" "generated_float_archive_$$(basename "$$f")"; \
	done; \
	perl ../libraries/float/n65_gen_float.pl --build "$$tmpdir/gf10" gf10 little 10 12; \
	for f in "$$tmpdir/gf10"/gf10_*.n; do \
		cp "$$f" "generated_float_archive_$$(basename "$$f")"; \
	done

unit: generated_float_archive_fixtures
	./test.pl --compile-only

e2e: generated_float_archive_fixtures
	./test.pl --e2e-only

test: unit e2e

.PHONY: all generated_float_archive_fixtures unit e2e test
