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
- `vcsc-zeropage.s`
  - exports the zero-page runtime workspace used by startup code and helper routines
  - current symbols are `_vcsc_arg0`, `_vcsc_arg1`, `_vcsc_ptr0`..`_vcsc_ptr3`, and `_vcsc_tmp0`..`_vcsc_tmp5`
  - the complete stock zero-page workspace is 16 bytes

The VCS 6507 has no connected hardware IRQ or NMI inputs. The stock runtime
therefore has no compiled interrupt-handler ABI or interrupt-entry library.
The two vector targets remain because every 6502 image still needs addresses at
`$FFFA` and `$FFFE`; a completely custom runtime may replace the weak fillers.

### Code-generation helper routines

These are small assembly helpers that the compiler targets directly:

- arithmetic: `mul`, `div`, `rem` (one- through four-byte add/subtract are emitted inline; division owns a private four-byte BSS workspace selected with `_divNle`)
- comparisons: `eq`, `lt`, `le`
- bitwise operations: `and`, `or`, `xor`, `not`
- shifts: logical/arithmetic, by 1, by 8, and by arbitrary counts
- buffer/frame helpers: `cpyN`, `setN`, `zeroN`, `copyzxN`, `copysxN`, `swapN`, `comp2N`

Assembler include glue is in `vcsc-runtime.inc`, assembly sources are in `asm/`, and
built archive members appear in `wrk/` after `make`. Machine definitions and
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
- zero page is available for the runtime workspace exported by `vcsc-zeropage.s`

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
