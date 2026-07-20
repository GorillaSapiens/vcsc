```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Ode to Joy sound example

This unbanked 4K Atari 2600/VCS cartridge plays the opening phrase of
Beethoven's **Ode to Joy** repeatedly on TIA audio channel 0.

The score is a const ROM array of `MusicStep` structs containing volume,
frequency, control, and timing. Two-frame silent score steps articulate
repeated notes. `music_tick()` runs once per television frame, advances a frame
counter, changes steps when the current timing expires, wraps at the end, and
writes `AUDV0`, `AUDF0`, and `AUDC0`.

The score and player are both implemented in `ode_to_joy.vcsc`. The player uses
the natural indexed form `music[music_index].field`. For an ordinary `uint8_t`
index and this four-byte struct, the compiler now scales the index inline in
compiler-owned zero-page scratch; it does not allocate per-expression BSS or
call the generic multiplication helper.
The kernel starts `TIM64T`, calls the source-level player while the timer counts
down, waits for `INTIM` to reach zero, and uses two final `WSYNC`s before the
next VSYNC. Stella then reports a stable 262-line NTSC frame; the raw interval
between successive VSYNC assertions is 263 whole scanlines.

The note aliases in `libraries/vcs/sound_ntsc.vcsc` use the NTSC lead voice
(`AUDC=12`). The TIA's scale is not equal-tempered, so the values are useful
hardware approximations rather than exact concert pitches.

Build after building the toolchain:

```sh
make
```

The display uses a medium blue background (`COLUBK=$84`). The result is
`ode_to_joy.bin`, a raw 4096-byte cartridge image, plus `ode_to_joy.map`.
