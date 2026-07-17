# Ode to Joy sound example

This unbanked 4K Atari 2600/VCS cartridge plays the opening phrase of
Beethoven's **Ode to Joy** repeatedly on TIA audio channel 0.

The score is a const ROM array of `MusicStep` structs containing volume,
frequency, control, and timing. Two-frame silent score steps articulate
repeated notes. `music_tick()` runs once per television frame, advances a frame
counter, changes steps when the current timing expires, wraps at the end, and
writes `AUDV0`, `AUDF0`, and `AUDC0`.

The score remains C-like data in `ode_to_joy.n`. The cycle-critical player is
implemented in `music_player.s`, because the compiler's current general indexed
struct lowering is far too expensive for a fixed 30-scanline overscan budget.
The kernel starts `TIM64T`, calls the player while the timer counts down, waits
for `INTIM` to reach zero, and uses one final `WSYNC` to begin the next VSYNC on
a stable 262-line boundary.

The note aliases in `libraries/vcs/sound_ntsc.n` use the NTSC lead voice
(`AUDC=12`). The TIA's scale is not equal-tempered, so the values are useful
hardware approximations rather than exact concert pitches.

Build after building the toolchain:

```sh
make
```

The result is `ode_to_joy.bin`, a raw 4096-byte cartridge image, plus
`ode_to_joy.map`.
