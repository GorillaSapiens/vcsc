```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Blank screen without assembly

`blank_noasm.c26` is the second complete unbanked 4K Atari 2600/VCS cartridge
produced by this reduced compiler.

It calls `choose_background()` using VCSC's fixed-symbol function model: the
parameter and named local storage are statically allocated, while the local
initializer runs when control reaches its declaration. The television frame is
expressed entirely in VCSC source. Each fixed nonzero scanline count uses a
source-level countdown such as:

```c
for (uint8_t i := 192; i; i--) {
   WSYNC := _;
}
```

The compiler proves that this straight-line loop cannot clobber X, keeps `i`
entirely in X, and lowers the loop to `LDX` / `STA WSYNC` / `DEX` / `BNE`.
`WSYNC := _` is the ordinary discard-store form: it stores the accumulator that
is already live without manufacturing a source value. No RAM byte is allocated
for the lexical loop index.

Build from this directory after building the toolchain:

```sh
make
```

The result is `blank_noasm.bin`, a raw 4096-byte cartridge image mapped at
`$F000-$FFFF`, plus `blank_noasm.map`. In the maintained baseline the source-only
example uses 445 ROM bytes and 22 RAM bytes, versus 449 ROM / 22 RAM for the
inline-assembly blank-screen example. The display uses a medium blue background
(`COLUBK=$84`). The frame consists of 262 scanlines: 3 VSYNC, 37 vertical blank,
192 visible, and 30 overscan.
