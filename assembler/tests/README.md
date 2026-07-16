# n65asm fixture sources

This directory contains source fixtures for the assembler tests.  They are not
standalone test runner scripts; `test/assembler_fixture_suite.test` runs them
through `test/assembler_fixture_suite.pl` and checks the expected success or
failure behavior.

Some files are intentionally invalid.  Those fixtures verify diagnostics for
bad addressing modes, duplicate symbols, unresolved final-output imports, and
parser errors.

`op_namespace.s` specifically verifies that compiler-generated `?@op_...`
operator symbols are linker-visible, while ordinary `@local` labels remain
local/scoped assembler labels.
