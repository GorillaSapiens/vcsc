```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Cinder Run

A one-player, endless sidescroller for the Atari 2600. Carry your lantern through
the volcanic ruins: climb three tiers of scrolling platforms above the road,
leap over rolling cinders, duck low embers, shoot monsters and collect sparks.
Three lamps at the upper left show your lives.

## Play

```sh
make
make play
```

- **Up:** jump. Release between jumps; holding Up does not jump repeatedly.
- **Left joystick fire:** start, shoot, or restart after losing all three lives.
  One shot at a time; release between shots. Shots travel right and kill monsters.
- **Left/right:** move along the road or platforms. The world keeps scrolling.
- **Down:** crouch. Your feet stay planted while the body becomes half-height;
  low embers that hit a standing courier pass overhead. Release to stand up.
- **Console Reset:** return to the starting scene.

Sparks award 50 points, kills award 100, passed hazards award 10, and distance adds
points over time. Scrolling begins at 30 pixels/second, rises to 45 after roughly
34 seconds, then caps at 60 after roughly 102 seconds. Kills do not accelerate it.
After a hit, the courier flashes
and is briefly invulnerable. Hazards travel at four elevations: road-level
cinders, head-height embers, and bats on the middle and upper routes.
The red score means game over; release fire, then press it to begin a fresh run.

## Platforms and movement

The platforms are real terrain, not background hills. Jump early onto an
approaching ledge, then jump again to climb the next tier. Falling feet land on
the top; jumping into an underside bumps your head. Walk off an edge and gravity
takes over. Side walls block movement and scrolling walls push the courier back.
There is always a continuous road below, so a missed jump is recoverable.
Ledges are eight scanlines thick, half their original thickness; their tops
remain at the same three heights.

The four-frame running cycle alternates extended strides and passing/recovery
poses, with counter-swinging arms and contrasting boots. Airborne and crouched
poses are separate from the running cycle.

## Cartridge

NTSC, **8K F8**, ordinary joystick, official 6502 opcodes only. No extra
cartridge RAM or emulator modifications are required.

The game-owned raster specializes the maintained 181-line player-color schedule:
two multicolored eight-row sprites, an M0 shot, an M1 spark, and a mutable 44-byte
playfield. The Ball is disabled. M0 shares the courier palette; M1 shares the
monster palette, contrasting with the platforms. While a shot is active, M0 and
M1 alternate frames (30 Hz each); players and terrain remain steady at 60 Hz.
Collision probes sample the same
packed playfield bytes that the kernel displays. The six-glyph component supplies
the score above gameplay. TIA collision latches drive damage, kills and collection.
Physics runs in VBLANK; terrain updates and scoring run in overscan, keeping both
blanking deadlines bounded. Beam-critical graphics stay in the startup bank.
Overscan/VBLANK scratch aliases reuse dead renderer workspace, never persistent
coordinates or live drawing state.

`test/vcs_cinder_run.pl` builds the ROM and runs a CPU/input oracle covering
start, Up jumping, held-Fire suppression, a continuous climb through all four heights,
walking off platforms, crouching, movement limits, injected hardware
collision responses, immunity, scoring, game over, restart, Reset, scrolling,
and stable frame periods. Injected collisions test game logic, not TIA geometry.
An additional 7,200-frame endurance run exercises the gradual pace and all
four hazard elevations, including scoring during platform collisions.
`test/vcs_cinder_run_stella.pl` separately checks the actual rendered courier,
three real platform landings and fixed-foot crouching. Separate standing/ducking
runs prove that real TIA ground contact costs a life and ducking avoids the low
ember. Captures use recorded RawStream frame identities, not stream positions.
The running cycle must produce four distinct rendered silhouettes. Pixel checks
also measure thinner platforms, contrasting M1 sparks, visible M0 shots, and a
real missile/monster collision that replaces the killed monster.
