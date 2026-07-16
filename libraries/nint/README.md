# nint

`nint` is the interrupt-entry library.
It is tiny on purpose.
It does **not** provide a whole runtime, reset code, zero-page workspace, or compiler helper routines.
It only provides proper `__nmi` and `__irqbrk` entry points.

## What it contains

`nint.a65` is built from one file: `nrt0_int.s`.
That file exports:

- `__nmi`
- `__irqbrk`

Both entry points:

- save processor state needed by the C/N-side handler path (`P`, `A`, `X`, `Y`)
- call a normal subroutine handler
- restore the saved state
- return with `rti`

Dispatch is:

- `__nmi` -> `_handle_nmi`
- `__irqbrk` -> `_handle_irq`

So `nint` is the interrupt veneer, not the handler implementation.

## What it requires

### You almost always use it with `nlib`

`nint` imports `_handle_nmi` and `_handle_irq`.
Those defaults live in `nlib`.
So the normal setup is:

- link `nlib.a65`
- also link `nint.a65` if you want real interrupt/BRK entry code

Your program may override `_handle_nmi` and `_handle_irq` with its own implementations.
If it does not, `nlib`'s defaults are harmless do-nothing handlers.

### What `nint` does not provide

`nint` does **not** provide:

- `__reset`
- startup/data/bss initialization
- zero-page runtime symbols
- compiler arithmetic/helper routines
- vector placement logic

That is why `nint` is an addon, not a standalone runtime.

## When to use it

Use `nint` when:

- your target actually uses NMI, IRQ, or BRK
- you want entry code that preserves registers before calling `_handle_nmi`/`_handle_irq`
- you want to replace `nlib`'s weak `rti` interrupt stubs with real wrappers

Do **not** bother with `nint` when:

- interrupts are unused
- a bare `rti` fallback is enough
- you are writing a completely custom interrupt/vector/runtime setup and do not want this library's ABI

## Relationship to `nlib`

`nlib` provides weak fallback `__nmi` and `__irqbrk` symbols that simply `rti`.
`nint` provides strong versions of those same symbols.
Because the linker prefers strong definitions over weak fallbacks, linking `nint` causes the real wrappers to win.

That gives you a clean split:

- `nlib` = base runtime
- `nint` = optional interrupt entry layer

## Important limitation

`nint` only saves/restores the CPU-visible register state (`P`, `A`, `X`, `Y`) before calling the handler.
It does **not** switch to a separate interrupt runtime context, and it does **not** save/restore the normal N runtime's frame pointer, argument stack pointer, or scratch workspace.

That means interrupt handlers must **not** assume they can safely run arbitrary normal compiled code.
An interrupt can arrive between ordinary instructions while the mainline code is in the middle of updating runtime state such as `fp`, `sp`, or zero-page scratch values.
If the handler then re-enters the normal runtime conventions, it can observe or clobber a half-updated context.

In practice, handlers should stay tiny and assembly-oriented.
Good handlers are things like:

- setting a flag
- incrementing a counter
- acknowledging hardware
- copying a byte into a ring buffer

Bad handlers are monsters that walk stack frames, call deep compiled code, allocate runtime temporaries, or otherwise muck with the shared runtime context.

If you need heavyweight interrupt-side work, do the minimum in the interrupt handler, set a flag, and let the mainline code handle the real work later.

## Building

From `libraries/nint`:

```sh
make clean
make
```

That builds `nint.a65`.

## License

This library directory is licensed under BSD-2-Clause.
See the local `LICENSE` file for the full text.
