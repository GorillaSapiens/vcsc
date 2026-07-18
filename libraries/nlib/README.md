# nlib

`nlib` is the default runtime/support library for N programs.
It is the library you link when you want the normal startup code, the compiler's helper routines, and the zero-page workspace that the generated code expects.
If you are not replacing the runtime yourself, this is the library you use.

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
- `nrt0_noint.s`
  - exports weak `__nmi` and `__irqbrk` stubs that just `rti`
  - these are fallback interrupt entries when nothing stronger is linked
- `nlib_zeropage.s`
  - exports the zero-page runtime workspace used by startup code and many helper routines
  - current symbols are `_nl_fp`, `_nl_arg0`, `_nl_arg1`, `_nl_ptr0`..`_nl_ptr3`, `_nl_tmp0`..`_nl_tmp5`
- `asm/handler.asm`
  - default `_handle_nmi` and `_handle_irq`
  - both are do-nothing `rts` handlers meant to be overridden by application code if needed

### Code-generation helper routines

These are mostly small assembly helpers that the compiler can target directly:

- arithmetic: `mul`, `div`, `rem` (one- and two-byte add/subtract are emitted inline; division owns a private two-byte BSS workspace that is archive-selected with `_divNle`)
- comparisons: `eq`, `lt`, `le`
- bitwise ops: `and`, `or`, `xor`, `not`
- shifts: logical/arithmetic, by 1, by 8, and by arbitrary counts
- buffer/frame helpers: `cpyN`, `setN`, `zeroN`, `copyzxN`, `copysxN`, `swapN`, `comp2N`, `fp2ptr*`

The generic 6502 machine definition is in `machine_6502.n`, the assembler include glue is in `nlib.inc`, the assembly sources are in `asm/`, and the built archive members are in `wrk/` after `make`. Weak operator helpers, floating-point support, big-endian helpers, and obsolete wide add/subtract/increment helpers have been removed.

### Dynamic allocation

The stock runtime does not provide `sbrk`, `malloc`, `free`, or a heap. Programs that need dynamic allocation must supply their own allocator and storage policy.

## What it requires

### Toolchain/runtime assumptions

`nlib` assumes the rest of this toolchain and its linker conventions.
In practice that means:

- the program is linked with `n65ld`
- the linker provides `__copy_table`, `__zero_table`, `__init_table`, and `__stack_start`
- the linker config defines the standard runtime segments the startup code expects

At minimum, the project's linker expects the usual core segments (`CODE`, `DATA`, `BSS`, `ZEROPAGE`).
For the stock runtime layout used by `nlib/n.cfg`, you also want `STARTUP` and a vector area.

### Machine assumptions

- 6502-family target
- hardware stack at page `$01xx`
- `_nl_fp` receives a deterministic baseline from `__stack_start`
- zero page is available for the runtime workspace exported by `nlib_zeropage.s`

### Link-time roots

`nlib` supplies `__reset`, and weak fallbacks for `__nmi` and `__irqbrk`.
Those are the root symbols the linker starts from when selecting code.

## When to use it

Use `nlib` when:

- you are building a normal N program for this toolchain
- you want the stock startup sequence
- you want the helper routines the compiler expects
- you are fine with weak no-op interrupt entries unless something stronger overrides them

Do **not** use `nlib` by itself when:

- you want a custom reset/startup path and are replacing the runtime completely
- you need dynamic allocation and are not providing your own allocator
- you need real IRQ/NMI entry wrappers that preserve registers... in that case add `nint` too

## Relationship to `nint`

`nlib` and `nint` are not substitutes.
`nlib` is the base runtime.
`nint` is the optional interrupt-entry addon.

If you link only `nlib`, interrupts and BRK fall back to weak `rti` stubs.
If you link `nlib` and `nint`, `nint` supplies strong `__nmi`/`__irqbrk` entry points and `nlib` provides the actual `_handle_nmi`/`_handle_irq` defaults unless your program overrides them.

## Building

From `libraries/nlib`:

```sh
make clean
make
```

That builds `nlib.a65`.

## License

This library directory is licensed under BSD-2-Clause.
See the local `LICENSE` file for the full text.
