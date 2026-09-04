```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See libraries/LICENSE.txt. -->

# 3E cartridge RAM (`swapram`)

3E keeps the final 2K of ROM permanently visible at `$1800-$1FFF`.  Writing a
ROM-bank number to TIA `$3F` maps that 2K ROM bank at `$1000-$17FF`.  Writing a
RAM-bank number to `$3E` replaces the lower window with cartridge RAM: reads are
at `$1000-$13FF` and writes are through the alias at `$1400-$17FF`.

Because RAM replaces the executable lower ROM window, code that touches mapped
RAM must execute from the fixed/startup bank.  VCSC hides that mechanism behind
`$swapram` storage.  Application code declares and uses ordinary objects:

```c
instantiate "3E/mapper.c26" as mapper (VCS_3E_BANKS:=4)

swapram uint16_t score;
swapram uint8_t history[64];

bank0 void update(void) {
   uint16_t s := score;
   score := s + 1;
   ++history[3];
}
```

The programmer does not choose a RAM bank or maintain a current-bank variable.
The linker places each `swapram` object and the compiler routes each 1-, 2-, 3-,
or 4-byte load/store through the mapper helper code. Signed, unsigned, and BCD
objects retain their normal language types; the mapper helper only moves bytes.
File-scope/static zero initialization is also automatic. Large zeroed objects use
a private startup helper rather than expanding into hundreds of scalar writes.

## ROM banks and automatic calls

`VCS_3E_BANKS` is the number of physical 2K ROM chunks, from 3 through 256.
Every chunk except the final one is selectable in the lower `$1000-$17FF`
window; the final chunk is permanently visible at `$1800-$1FFF` and owns
startup/vectors.  For example, 16K ROM uses `VCS_3E_BANKS:=8`.

VCSC uses the same descriptor bank-call contract as 3F: lower ROM descriptors
are the values written to `$3F`, while the fixed bank uses `$FF` as the
no-switch sentinel.  Ordinary C26 calls across these ROM regions are automatic;
application code does not write `$3F` around function calls.  Same-bank calls
remain ordinary `JSR`s.  The mapper-owned trampoline lives in `3E/bankcall.s26`,
and `3E/entry.s26` is intentionally empty because the fixed final bank is always
visible at reset.

## Capacity and placement

VCSC's 3E profile exposes the full value range of the 8-bit `$3E` selector:
**256 banks x 1K = 256K of swap RAM**.  The logical pool is therefore `$00000`
through `$3FFFF`.

Each allocated object must fit wholly inside one 1K bank.  Objects may be
arrays or structures and may use runtime indexing, but a single object may not
cross a bank boundary.  The map file reports each object's logical address,
RAM-bank number, and in-bank offset.

The O26 object format still has a 64K packed namespace per segment, so one
translation unit cannot itself contribute more than 64K of swap-RAM BSS.
Projects can use the full 256K by splitting very large swap-RAM declarations
across source files; final placement is global at link time.

An ordinary 6507 pointer cannot encode a swap-RAM bank plus offset.  VCSC
therefore does not permit ordinary address-taking, pointer decay, or `ref`
binding of a `swapram` object.  Normal lvalue operations are the interface.

## Emulator and cartridge compatibility

The original/common 3E convention is substantially more conservative than the
full 8-bit selector permits. Current Stella documents and implements its `3E`
mapper as **32 banks x 1K = 32K RAM**. Stella also has a distinct `3EX` mapper
with **256 banks x 1K = 256K RAM**. The older 512-byte-bank wording came from a
Stella development discussion and does not describe the implemented 3EX mapper.

Consequently:

* A VCSC 3E program using only RAM banks 0-31 is compatible with Stella's `3E`
  RAM limit (subject, of course, to the rest of the cartridge behaving as 3E).
* A VCSC 3E program using RAM banks 32-255 requires hardware/emulation that
  decodes the full 8-bit `$3E` value as a 1K-bank selector. Stella's `3E`
  mapper does not currently do that.
* For Stella-compatible 256K RAM, use VCSC's dedicated `3EX` profile rather
  than relabeling a 3E image. 3EX carries its own ROM metadata/detector contract
  even though its implemented RAM selector geometry is the same 256 x 1K shape.

If Stella 3E compatibility matters, inspect the VCSC map and keep every reported
`swapram-bank` at 31 or below. For larger Stella-compatible RAM, build as 3EX.

## Implementation boundary

The mapper-owned fixed-bank helpers live in `libraries/vcs/3E/swapram.s26`.
`vcsc` automatically assembles and links that file when a 3E link references
swap-RAM access helpers, so application builds do not add it manually. The
entry points are named by byte count:

```
swapram_read1   swapram_write1
swapram_read2   swapram_write2
swapram_read3   swapram_write3
swapram_read4   swapram_write4
```

`swapram_zero` is an additional **private startup-only** helper used to implement
zero-initialized swapram objects efficiently. It is not a programmer-facing
block RAM API.

All code executed while RAM is selected must remain in the `$startup`/fixed
bank.  Lower-ROM callers reach these helpers through the ordinary 3E bank-call
path; returning restores the caller's ROM bank with `$3F`.
