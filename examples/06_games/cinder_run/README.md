<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Cinder Run

A one-player, endless sidescroller for the Atari 2600. Carry your lantern through
the volcanic ruins: leap over rolling cinders, stay beneath flying embers, and
collect the floating sparks. Three lamps at the upper left show your lives.

## Play

```sh
make
make play
```

- **Left joystick fire:** start, jump, or restart after losing all three lives.
  Release between presses; holding fire does not automatically jump again.
- **Left/right:** move along the road. Scenery and hazards keep scrolling.
- **Console Reset:** return to the starting scene.

Sparks award 50 points, passed hazards award 10, and distance adds points over
time. The pace increases after the fifth hazard. After a hit, the courier flashes
and is briefly invulnerable. Flying embers can be avoided without jumping.
The red score means game over; release fire, then press it to begin a fresh run.

## Cartridge

NTSC, unbanked **4K**, ordinary joystick, official 6502 opcodes only. No extra
cartridge RAM or emulator modifications are required.

The maintained player-color renderer draws two multicolored eight-row sprites,
the Ball spark and a mutable 44-byte playfield. Hills rotate slowly while the
road scrolls faster. The six-glyph component supplies the score above gameplay.
TIA collision latches drive damage and spark collection. All game logic and
playfield updates run in overscan; graphics selection runs in VBLANK.

`test/vcs_cinder_run.pl` builds the ROM and runs a CPU/input oracle covering
start, held-fire jumping and landing, movement limits, injected hardware
collision responses, immunity, scoring, game over, restart, Reset, scrolling,
and stable frame periods. Injected collisions test game logic, not TIA geometry.
`test/vcs_cinder_run_stella.pl` separately checks the actual rendered courier,
jump/landing, and a real TIA contact removing exactly one life, using recorded
RawStream frame identities and independent pixel assertions.
