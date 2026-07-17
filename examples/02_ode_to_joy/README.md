# Ode to Joy sound example

This unbanked 4K Atari 2600/VCS cartridge plays the opening phrase of
Beethoven's **Ode to Joy** repeatedly on TIA audio channel 0.

The score is a const ROM array of `MusicStep` structs containing volume,
frequency, control, and timing. Two-frame silent score steps articulate
repeated notes. `music_tick()` runs once per television frame, advances a frame
counter, changes steps when the current timing expires, wraps at the end, and
writes `AUDV0`, `AUDF0`, and `AUDC0`.

The score and player are both implemented in `ode_to_joy.n`. The player keeps a
pointer to the current `MusicStep`, so the compiler computes the table location
once when advancing rather than multiplying an array index for every field.
The kernel starts `TIM64T`, calls the source-level player while the timer counts
down, waits for `INTIM` to reach zero, and uses two final `WSYNC`s before the
next VSYNC. Stella then reports a stable 262-line NTSC frame; the raw interval
between successive VSYNC assertions is 263 whole scanlines.

The note aliases in `libraries/vcs/sound_ntsc.n` use the NTSC lead voice
(`AUDC=12`). The TIA's scale is not equal-tempered, so the values are useful
hardware approximations rather than exact concert pitches.

Build after building the toolchain:

```sh
make
```

The result is `ode_to_joy.bin`, a raw 4096-byte cartridge image, plus
`ode_to_joy.map`.
