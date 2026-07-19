# nlib

`nlib` is the default runtime/support library for the reduced 6502 toolchain.
It provides the stock startup path, compiler helper routines, and zero-page
workspace expected by generated code.

## What it contains

### Startup/runtime pieces

- `nrt0.s`
  - exports `__reset`
  - initializes the 6502 hardware stack
  - copies `DATA` from ROM to RAM using `__copy_table`
  - zeros `BSS` using `__zero_table`
  - initializes the pooled-scratch frame pointer from `__stack_start`
  - walks the linker-generated `__init_table`
  - calls `main`
  - supplies weak `__nmi` and `__irqbrk` vector fillers that execute `rti`
- `nlib_zeropage.s`
  - exports the zero-page runtime workspace used by startup code and helper routines
  - current symbols are `_nl_fp`, `_nl_arg0`, `_nl_arg1`, `_nl_ptr0`..`_nl_ptr3`, `_nl_tmp0`..`_nl_tmp5`

The VCS 6507 has no connected hardware IRQ or NMI inputs. The stock runtime
therefore has no compiled interrupt-handler ABI or interrupt-entry library.
The two vector targets remain because every 6502 image still needs addresses at
`$FFFA` and `$FFFE`; a completely custom runtime may replace the weak fillers.

### Code-generation helper routines

These are small assembly helpers that the compiler targets directly:

- arithmetic: `mul`, `div`, `rem` (one- and two-byte add/subtract are emitted inline; division owns a private two-byte BSS workspace selected with `_divNle`)
- comparisons: `eq`, `lt`, `le`
- bitwise operations: `and`, `or`, `xor`, `not`
- shifts: logical/arithmetic, by 1, by 8, and by arbitrary counts
- buffer/frame helpers: `cpyN`, `setN`, `zeroN`, `copyzxN`, `copysxN`, `swapN`, `comp2N`, `fp2ptr*`

The generic 6502 machine definition is in `machine_6502.n`, assembler include
glue is in `nlib.inc`, assembly sources are in `asm/`, and built archive members
appear in `wrk/` after `make`.

### Dynamic allocation

The stock runtime does not provide `sbrk`, `malloc`, `free`, or a heap. Programs
that need dynamic allocation must supply their own allocator and storage policy.

## What it requires

`nlib` assumes this linker and its startup conventions. The linker must provide
`__copy_table`, `__zero_table`, `__init_table`, and `__stack_start`, and its
configuration must define the normal `CODE`, `DATA`, `BSS`, `ZEROPAGE`,
`STARTUP`, and vector regions.

Machine assumptions:

- 6502-family target
- hardware stack at page `$01xx`
- `_nl_fp` receives a deterministic baseline from `__stack_start`
- zero page is available for the runtime workspace exported by `nlib_zeropage.s`

The linker selects the startup archive member through `__reset`, `__nmi`, and
`__irqbrk`.

## When to use it

Use `nlib` for the normal compiler-generated program and stock startup sequence.
Do not use it when supplying a completely custom reset/vector/runtime setup; in
that case link with `-nostdlib` and provide every required symbol yourself.

## Building

From `libraries/nlib`:

```sh
make clean
make
```

That builds `nlib.a65`.

## License

This library directory is licensed under BSD-2-Clause. See `LICENSE` for the
full text.
