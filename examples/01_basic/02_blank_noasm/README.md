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
expressed entirely in VCSC source, with no inline assembly.

VSYNC and the 192-line visible region still demonstrate explicit scanline
countdowns where the beam itself sets the deadline:

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

VBLANK and overscan are different: those are the normal places to run game
logic. The example therefore starts the RIOT interval timer instead of wasting
every blanked scanline on `WSYNC`:

```c
VBLANK := 2;
TIM64T := 42;

// Read controls, move objects, test collisions, prepare display state, ...

while (!(TIMINT & 0x80)) {
}
WSYNC := _;
VBLANK := 0;
```

The timer runs while the program does useful work. Once that work is done, the
program waits only for the unused part of the budget. `TIMINT.7` becomes set
when the interval expires, so the wait also terminates if the game logic has
already consumed the deadline instead of accidentally waiting for an `INTIM`
wraparound. A single `WSYNC` then aligns the phase transition.

For this source-level NTSC frame layout, `TIM64T=42` is calibrated for the
37-line VBLANK budget and `TIM64T=34` for the 30-line overscan budget. After the
overscan timer expires, three blanked `WSYNC` boundaries complete the calibrated
Stella frame boundary. These are fixed phase/frame-boundary alignment, not a
per-scanline blanking loop. Code added inside either timer budget must still
finish before the next beam-critical phase; a timer makes the available time
usable, not infinite.

Build from this directory after building the toolchain:

```sh
make
```

The result is `blank_noasm.bin`, a raw 4096-byte cartridge image mapped at
`$F000-$FFFF`, plus `blank_noasm.map`. The maintained source-only example uses
505 ROM bytes and 18 RAM bytes. The display uses a medium blue background
(`COLUBK=$84`). The frame remains exactly 262 scanlines: 3 VSYNC, 37 vertical
blank, 192 visible, and 30 overscan.
