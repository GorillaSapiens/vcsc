```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# VCSC Bankswitching ABI

This document defines VCSC's public contract for selector-controlled cartridge
banks and automatic cross-bank C calls. Mapper-specific hardware details remain
in `libraries/vcs/<MAPPER>/`, but the call-site and return-frame rules below are
shared ABI.

## Status

The descriptor ABI in this document is the public ABI for `$bankcall`.
The compiler, assembler, and linker emit the three-byte `.banktarget` field.
F8/F8SC/F6/F6SC/F4/F4SC, FA, DPC, FA2-24/28, JANE, 0840, UA, UASW,
0FA0, WD, 3F, 3E, 3EX, FC, and F0 are fully migrated: their bank-local trampolines consume the
destination descriptor directly and carry a baked source descriptor on the
hardware stack.

No new mapper should be designed around the old PC-derived form.

## Bank identity is not an address

A CPU address identifies where code executes, not which physical cartridge bank
contains it. Small existing cartridges sometimes give each logical bank a
distinct linker address, but that stops scaling once multiple physical banks are
linked for the same CPU window.

The bank-call ABI therefore never infers source or destination bank identity
from a target address or return PC.

The linker already knows the placement bank of both caller and callee. Each bank
participating in `$bankcall` also has a one-byte **bank-call descriptor**.
That descriptor is opaque outside the mapper-specific bank-call implementation.
It may be, for example:

- the low byte of a selector hotspot;
- the byte that must be written to a selector register;
- an indexed-selector offset;
- a logical/physical bank ID used by a stateful mapper; or
- any other one-byte value that lets that mapper select or restore the bank.

The generic linker must carry the descriptor; it must not interpret it.

## Direct-call encoding

A same-bank direct call remains an ordinary three-byte 6507 `JSR`.

A cross-bank direct call occupies six linked bytes:

```asm
    JSR __bankcall
    .word target
    .byte destination_descriptor
```

VCSC source/assembler output may continue to spell the three bytes following the
`JSR` as a linker-owned `.banktarget target` field. Under this ABI,
`.banktarget` occupies **three bytes**: the 16-bit target CPU address followed by
the destination bank-call descriptor supplied by the linker.

The 16-bit word answers **where in the selected bank** to enter. The descriptor
answers **which mapper state/bank must be selected**. The two facts are
independent, and several physical banks may legitimately contain the same target
CPU address.

The six-byte sequence is indivisible function layout. It may cross an ordinary
256-byte page, but it may not be split across allocation regions or banks.

## Source descriptor and trampoline instances

The source descriptor is not stored at the call site. Each replicated
mapper-specific bank-call trampoline instance has the descriptor for its owning
source bank baked into that instance.

This is intentional. Repeating the source descriptor at every call site wastes
ROM and would require decoding two values when the trampoline already knows
which bank copy is executing.

A mapper's trampoline copies may therefore differ at explicit source-descriptor
patch bytes. Any instruction bytes fetched while a bank switch is taking effect
must still be identical at the same CPU addresses in the old and new mappings.
Mapper implementations are responsible for arranging descriptor-specific bytes
only where they are consumed before the corresponding switch, or otherwise
cannot corrupt post-switch instruction fetch.

## Cross-bank call frame

On entry, the trampoline must read the complete inline target word and
destination descriptor **before switching away from the caller bank**. It then
advances the caller's real stacked JSR return PC by three bytes so the final
`RTS` resumes after the inline payload. The adjustment is full 16-bit arithmetic
and must handle page carry correctly.

Before selecting the destination, the trampoline pushes its baked-in source
bank-call descriptor onto the 6507 hardware stack. It then arranges a synthetic
return to the mapper's bank-return path and transfers control to the destination
target.

Conceptually, while the callee is running, the relevant stack nesting is:

```text
caller real JSR return
source bank-call descriptor
synthetic return to __bankreturn
```

The callee uses an ordinary `RTS`. That consumes the synthetic return address,
leaving the source descriptor immediately available to the bank-return path.
The return path consumes that descriptor, restores the source mapper state, and
then performs the final ordinary `RTS` to the caller's unchanged logical
continuation PC.

Nested cross-bank calls compose naturally because each invocation carries its
own source descriptor in LIFO order.

The implementation must preserve the normal VCSC A:X return-value contract.
Hardware-stack sizing must include the extra one-byte source descriptor carried
by each active cross-bank call, in addition to the synthetic return machinery.

## Mapper contract

A mapper may opt into `$bankcall` only when one byte is sufficient to
identify the mapper state needed to enter and later restore each participating
compiled-code bank under VCSC's supported topology.

For each participating bank, the mapper profile must provide a one-byte
bank-call descriptor using `$bankcall_descriptor:<byte>`. The ABI requirement is
the mapper-defined value; generic linker code carries it without interpreting its
meaning.

The mapper-specific `bankcall.s26` owns the interpretation of the byte.

The mapper-specific `entry.s26` owns reset-entry normalization for migrated
descriptor-ABI mappers. The fragment is variable length and may be empty when
hardware already guarantees the startup mapping, as with 3F/3E/3EX/FC/F0. When selector
normalization is required, the linker replicates the maintained entry bytes ahead
of the ordinary vector handler so reset reaches the runtime only after the
canonical startup bank/state is visible. Selector-read entries spell the
absolute-NOP access as raw `op0C`, avoiding any dependency on assembler
`--illegal` mode.

Examples of useful descriptor choices include:

- F8/F6/F4, FA, FA2, DPC and JANE: selector-hotspot low byte;
- 0840: `$00` or `$40`, suitable as an offset from `$0800`;
- UA/UASW: `$20` or `$40`, suitable as an offset from the mapper's selector
  base;
- 0FA0: `$A0` or `$C0`, suitable for the canonical selector aliases;
- WD: `1` or `2`, selecting the two relocation-safe compiler arrangements via
  raw `op1C` absolute-X reads from `$0038` (`$39` / `$3A`);
- 3EX: lower selectable ROM bank number `$00-$FE`; `$FF` identifies the fixed
  final bank and is handled as the no-switch sentinel by the mapper trampoline;
- FC: physical bank number `$00-$FF`; the mapper stages `descriptor & 3` at
  `$1FF8`, `descriptor >> 2` at `$1FF9`, then accesses `$1FFC` to commit;
- a write-selected mapper: the exact selector value to write; and
- F0: physical bank ID `$00-$0F`; the mapper-specific trampoline computes
  `(destination-source)&15` `$1FF0` advances on call and the inverse advance on
  return. Hardware powers up in physical bank 15.

Dynamic read-selected mappers use raw undocumented `op1C` absolute-X NOP reads, with the descriptor carried in X. This preserves A and flags and avoids an assembler `--illegal` dependency. Mapper profiles must keep every selector-base-plus-descriptor address within one 256-byte page so the indexed access cannot take a page-cross path.

These are mapper choices, not generic ABI encodings. Code outside the mapper's
bank-call implementation must never assume that a descriptor is a hotspot byte,
offset, bank number, or bit field.

For an incremental mapper such as F0, the destination descriptor identifies the
target bank. The source descriptor pushed by the caller identifies the bank to
restore. The bank-return code executes in the destination bank's trampoline
copy, whose own baked descriptor identifies the current bank, so the mapper can
compute the reverse transition without inferring anything from the return PC.

F0 reserves 96 bytes (`$060`) at `$FF00-$FF5F` in every bank for this
replicated transition. Ordinary code is capped below `$FEE0` so no allocated
function can execute through CPU `$FFF0`, whose cartridge bus address `$1FF0`
would itself advance the mapper.

If a mapper needs more state than one descriptor byte can represent, it does not
fit this ABI as written. It must use a mapper-specific calling contract or a
future explicitly wider ABI rather than overloading the 16-bit code address.

## Linker responsibilities

For an explicitly cross-bank direct call, the linker must:

1. identify caller and callee placement banks from relocation/layout metadata;
2. reject the call if the selected mapper does not support automatic bank calls;
3. emit/fill the callee's one-byte destination descriptor in the inline payload;
4. redirect the `JSR` to the caller bank's fixed mapper-specific bank-call entry;
5. ensure that trampoline instance carries the caller bank's baked source
   descriptor; and
6. account for the six-byte indivisible call bundle and the additional hardware
   stack byte.

A call whose caller and callee resolve to the same bank remains an ordinary
`JSR`; it must not pay the bank-call overhead merely because the mapper supports
bankswitching.

Cross-bank JMPs are a separate ABI and are not changed by this document.

## Manual mapper changes

Automatic bank calls assume that execution enters a trampoline instance while
its owning bank/mapping is actually active. Handwritten code that changes mapper
state behind the compiler/linker's back is responsible for restoring a state
consistent with the executing compiled-code region before using automatic
cross-bank calls.

This rule is especially important for stateful or segmented mappers. Hardware
may permit many more mappings than are useful for ordinary compiled 6507 code;
VCSC only needs to support mapper states that preserve the link address assigned
to compiled code.
