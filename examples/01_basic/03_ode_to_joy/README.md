```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Ode to Joy sound example

This unbanked 4K Atari 2600/VCS cartridge plays the opening phrase of
Beethoven's **Ode to Joy** repeatedly on TIA audio channel 0.

The score is a const ROM array of `MusicStep` structs containing volume,
frequency, control, and timing. Two-frame silent score steps articulate
repeated notes. `music_tick()` runs once per television frame, advances a frame
counter, changes steps when the current timing expires, and wraps at the end.
The cartridge starts both channels silent. The first note begins during the
first synchronized overscan rather than during reset-time setup. Every score
transition first writes zero to `AUDV0`, then writes `AUDC0` and `AUDF0`, and
finally writes the new `AUDV0`. This is required even for silent gap steps:
retuning a still-audible preceding note creates a short wrong-pitch chirp.

The score and player are both implemented in `ode_to_joy.c26`. The player uses
the natural indexed form `music[music_index].field`. For an ordinary `uint8_t`
index and this four-byte struct, the compiler now scales the index inline in
compiler-owned zero-page scratch; it does not allocate per-expression BSS or
call the generic multiplication helper.
The complete frame scheduler is written in VCSC source with no inline assembly.
As in `02_blank_noasm`, VBLANK and overscan are RIOT-timer-owned CPU budgets
rather than per-scanline `WSYNC` loops. `music_tick()` runs once per frame while
the overscan timer counts down. Because the short and note-transition paths
through `music_tick()` take different numbers of cycles, Ode uses a separately
calibrated overscan preload of `TIM64T=35`. One `WSYNC` after `music_tick()`
normalizes the polling phase, the program waits out the remaining timer budget,
and two final `WSYNC` boundaries align the following VSYNC. The VBLANK path
uses the simpler `blank_noasm` deadline form because this example has no
variable VBLANK work. This exact source-only schedule reports a stable 262-line
NTSC frame in Stella. A dynamic regression also verifies
that audio is silent before the first frame boundary and that the first audible
note uses the same overscan phase and register order as every later transition.

The note aliases in `libraries/vcs/sound_ntsc.c26` use the NTSC lead voice
(`AUDC=12`). The TIA's scale is not equal-tempered, so the values are useful
hardware approximations rather than exact concert pitches.

Build after building the toolchain:

```sh
make
```

The display uses a medium blue background (`COLUBK=$84`). The result is
`ode_to_joy.bin`, a raw 4096-byte cartridge image, plus `ode_to_joy.map`.
