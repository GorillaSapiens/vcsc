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
  - initializes the N argument stack from `__stack_start`
  - walks the linker-generated `__init_table`
  - calls `main`
- `nrt0_noint.s`
  - exports weak `__nmi` and `__irqbrk` stubs that just `rti`
  - these are fallback interrupt entries when nothing stronger is linked
- `nlib_zeropage.s`
  - exports the zero-page runtime workspace used by startup code and many helper routines
  - current symbols are `_nl_sp`, `_nl_fp`, `_nl_arg0`, `_nl_arg1`, `_nl_ptr0`..`_nl_ptr3`, `_nl_tmp0`..`_nl_tmp5`, `_nl_sbrk`
- `asm/handler.asm`
  - default `_handle_nmi` and `_handle_irq`
  - both are do-nothing `rts` handlers meant to be overridden by application code if needed

### Code-generation helper routines

These are mostly small assembly helpers that the compiler can target directly:

- arithmetic: `mul`, `div`, `rem` (one- and two-byte add/subtract are emitted inline)
- comparisons: `eq`, `lt`, `le`
- bitwise ops: `and`, `or`, `xor`, `not`
- shifts: logical/arithmetic, by 1, by 8, and by arbitrary counts
- stack/frame helpers: `pushN`, `popN`, `cpyN`, `setN`, `zeroN`, `copyzxN`, `copysxN`, `swapN`, `comp2N`, `fp2ptr*`, `sp2ptr*`

The generic 6502 machine definition is in `machine_6502.n`, the assembler include glue is in `nlib.inc`, the assembly sources are in `asm/`, and the built archive members are in `wrk/` after `make`. Weak operator helpers, floating-point support, big-endian helpers, and obsolete wide add/subtract/increment helpers have been removed.

### Memory allocation

This tree uses `asm/sbrk.asm` for simple dynamic allocation support.
It exports `_sbrk` and adds the zero-page heap pointer `_nl_sbrk`.
At startup, `__init_sbrk` seeds that pointer from linker symbol `__stack_top`, which is the top free byte of the RAM arena left over after `DATA` and `BSS` placement.

The N argument stack grows upward from `__stack_start`.
The `sbrk` pointer grows downward from `__stack_top`, so both share the same free RAM arena from opposite ends.
`_sbrk` prevents a heap allocation from crossing the **current** argument-stack top and returns `0` on failure.
A size-0 request returns the current heap pointer without changing it.

This is a very small runtime allocator interface, not a full malloc/free system.
Most other low-level helper wrappers can stay frame-free and address argument-stack data straight from `sp` via `sp2ptr*`; `_sbrk` is the notable ABI-facing exception that mirrors `sp` into `fp`.
There is no free list, no block reuse, and no protection against later argument-stack growth colliding with already allocated heap memory.

## What it requires

### Toolchain/runtime assumptions

`nlib` assumes the rest of this toolchain and its linker conventions.
In practice that means:

- the program is linked with `n65ld`
- the linker provides `__copy_table`, `__zero_table`, `__init_table`, `__stack_start`, and `__stack_top`
- the linker config defines the standard runtime segments the startup code expects

At minimum, the project's linker expects the usual core segments (`CODE`, `DATA`, `BSS`, `ZEROPAGE`).
For the stock runtime layout used by `nlib/n.cfg`, you also want `STARTUP`, `ARGSTACK`, and a vector area.

### Machine assumptions

- 6502-family target
- hardware stack at page `$01xx`
- argument stack grows upward from `__stack_start` while the `sbrk` heap pointer grows downward from `__stack_top`
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
- you need a real allocator and are not providing one
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
