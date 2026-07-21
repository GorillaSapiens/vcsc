```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# runtime

`runtime` is the default runtime/support library for the reduced 6502 toolchain.
It provides the stock startup path, compiler helper routines, and zero-page
workspace expected by generated code.

## What it contains

### Startup/runtime pieces

- `vcsc-rt0.s`
  - exports `__reset`
  - initializes the 6502 hardware stack
  - copies `DATA` from ROM to RAM using `__copy_table`
  - zeros `BSS` using `__zero_table`
  - walks the linker-generated `__init_table`
  - calls `main`
  - supplies weak `__nmi` and `__irqbrk` vector fillers that execute `rti`
- `vcsc-zp-*.s`
  - each file exports one independently selectable zero-page cell
  - `_vcsc_arg0`, `_vcsc_arg1`, and `_vcsc_tmp0` through `_vcsc_tmp5` are one byte each
  - `_vcsc_ptr0` through `_vcsc_ptr3` are two bytes each
  - startup selects `arg0`, `arg1`, and `ptr0` through `ptr2`, an eight-byte baseline
  - the full 16-byte set is linked only when an operation such as generic
    multiplication needs every cell

The VCS 6507 has no connected hardware IRQ or NMI inputs. The stock runtime
therefore has no compiled interrupt-handler ABI or interrupt-entry library.
The two vector targets remain because every 6502 image still needs addresses at
`$FFFA` and `$FFFE`; a completely custom runtime may replace the weak fillers.

### Code-generation support

VCSC emits one- through four-byte scalar copies, fills, extensions, negation,
comparisons, and bitwise operations directly. Add and subtract are also inline.
These operations no longer select inherited arbitrary-width runtime helpers.

Runtime helpers remain where compact shared code is still useful:

- `_shl8` through `_shl32`, `_shr8` through `_shr32`, and `_sar8` through
  `_sar32` implement variable-count shifts at the four supported scalar widths;
- `_copy_bytes`, `_fill_bytes`, and `_zero_bytes` support objects wider than
  four bytes;
- `_mulNle`, `_divNle`, and `_remNle` remain temporarily for multiplication,
  division, and remainder. Division owns a private four-byte BSS workspace.

The fixed-width shift helpers use `ptr0` as source, `ptr1` as destination, and
`arg1` as the low-byte count. They preserve both pointers, clobber A/X/Y, and
produce zero or sign fill when the runtime count is at least the operand width.

Assembler include glue is in `vcsc-runtime.inc`. It defines the short `arg0`,
`ptr0`, and `tmp0` spellings but deliberately imports no workspace symbols.
Compiler output, including inline assembly, and each generated helper member
declare their own exact zero-page imports, allowing the archive linker to select
only the required `vcsc-zp-*.o26` members. Helper sources are in `asm/`, and
generated archive members appear in `wrk/` after `make`. Machine definitions and
linker layouts are platform-owned; the stock project target lives under
`libraries/vcs/`.

### Dynamic allocation

The stock runtime does not provide `sbrk`, `malloc`, `free`, or a heap. Programs
that need dynamic allocation must supply their own allocator and storage policy.

## What it requires

`runtime` assumes this linker and its startup conventions. The linker must provide
`__copy_table`, `__zero_table`, and `__init_table`, and its configuration must define the normal `CODE`, `DATA`, `BSS`, `ZEROPAGE`,
`STARTUP`, and vector regions.

Machine assumptions:

- 6502-family target
- hardware stack at page `$01xx`
- zero page is available for the selected `vcsc-zp-*.s` workspace members

The linker selects the startup archive member through `__reset`, `__nmi`, and
`__irqbrk`.

## When to use it

Use `runtime` for the normal compiler-generated program and stock startup sequence.
Do not use it when supplying a completely custom reset/vector/runtime setup; in
that case link with `-nostdlib` and provide every required symbol yourself.

## Building

From `libraries/runtime`:

```sh
make clean
make
```

That builds `libvcsc.l26`.

## License

This library directory is licensed under BSD-2-Clause. See `LICENSE` for the
full text.
