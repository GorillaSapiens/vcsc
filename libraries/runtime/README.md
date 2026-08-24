```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See libraries/LICENSE.txt. -->

# runtime

`runtime` is the default runtime/support library for the reduced 6502 toolchain.
It provides the stock startup path, compiler helper routines, and zero-page
workspace expected by generated code.

## What it contains

### Startup/runtime pieces

- `vcsc-rt0.s26` is the full stock startup. It initializes the hardware stack,
  copies `DATA` through `__copy_table`, zeros `BSS` through `__zero_table`, walks
  `__init_table`, and tail-jumps to `main`.
- `vcsc-rt1-simple.s26` is the compact stock startup. It clears all 128 bytes of
  ordinary RIOT RAM plus TIA registers and tail-jumps to `main`; it needs no
  linker startup tables or runtime pointer workspace. The linker selects it only
  when there is no DATA copy, runtime initializer, or startup-zero requirement
  outside ordinary RIOT RAM.
- Both stock startups export `__reset` and supply weak `__nmi` and `__irqbrk`
  vector fillers that execute `rti`.
- `vcsc-zp-*.s26`
  - each file exports one independently selectable zero-page cell
  - `_vcsc_arg0` and `_vcsc_arg1` are one byte each
  - `_vcsc_ptr0` through `_vcsc_ptr2` are two bytes each
  - stock startup selects only `_vcsc_ptr0` and `_vcsc_ptr1`, for four bytes
    of permanent zero-page workspace; it reconstructs copy/zero source and
    destination pointers from linker records and trades reset-time cycles/ROM
    for four recovered RAM bytes
  - archive members remain demand-selected: helpers pull `_vcsc_ptr2`,
    `_vcsc_arg0`, or `_vcsc_arg1` only when their generated code actually
    imports those cells

The selected startup sequence runs after every entry through `__reset`, not only
at cartridge power-on. The full startup performs object-by-object initialization;
the compact startup's blanket RIOT-RAM clear has the same reset semantics for
programs that qualify for it. For a split-address region such as Superchip RAM, table
records contain the write-window address, so DATA copies and BSS clearing never
read from or write through the wrong alias. A reset deliberately restores all
allocated persistent BSS/DATA objects to their declared startup state; ordinary
bank switches do not invoke startup and preserve them.

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
- `_mul8` through `_mul32` compute the low-width product in compiler-owned
  expression scratch;
- `_div8` through `_div32` compute quotient and remainder into one adjacent
  compiler-owned result block.

The fixed multiplication helpers destructively shift their dead scratch
operands. The fixed division helpers destructively shift the dividend, preserve
the divisor, and place the remainder immediately after the quotient. Neither
family owns BSS or selects extra zero-page cells.

The fixed-width shift helpers use `ptr0` as source, `ptr1` as destination, and
`arg1` as the low-byte count. They preserve both pointers, clobber A/X/Y, and
produce zero or sign fill when the runtime count is at least the operand width.

Assembler include glue is in `vcsc-runtime.inc`. It defines the short `arg0`,
`arg1`, and `ptr0` through `ptr2` spellings but deliberately imports no
workspace symbols.
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

`runtime` assumes this linker and its startup conventions. The full startup
requires `__copy_table`, `__zero_table`, and `__init_table`; the compact startup
does not generate or import those tables. The linker configuration must define
the normal `CODE`, `DATA`, `BSS`, `ZEROPAGE`, `STARTUP`, and vector regions.

Machine assumptions:

- 6502-family target
- hardware stack at page `$01xx`
- zero page is available for the selected `vcsc-zp-*.s26` workspace members

The linker first resolves the ordinary stock reset provider, then automatically
reselects the compact stock provider when the selected program is safe for the
blanket RIOT-RAM clear. Custom reset providers are not replaced.

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

Everything under `libraries/`, including this runtime, is covered under
CC0-1.0. See `libraries/LICENSE.txt`.
