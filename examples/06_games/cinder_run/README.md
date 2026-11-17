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
The three mirrored lamps in the upper corners show your lives.

## Play

```sh
make
make play
```

- **Up:** jump. Release between jumps; holding Up does not jump repeatedly.
  Jumping makes an upward pitch sweep; catching a spark makes a high fixed chime.
- **Left joystick fire:** start, shoot, or restart after losing all three lives.
  One shot at a time; release between shots. Hold Fire with any joystick direction
  to aim in eight directions. Neutral Fire shoots in the last facing direction.
  While Fire is held, the stick aims rather than moving, crouching, or jumping.
- **Left/right:** run in either direction. The camera follows near the side of
  the movement window; there is no forced scrolling or speed acceleration.
- **Down:** crouch. Your feet stay planted while the body becomes half-height;
  low embers that hit a standing courier pass overhead. Release to stand up.
- **Console Reset:** return to the starting scene.

Sparks award 50 points, kills award 100, and survival adds points over time.
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
Ledges are four scanlines thick, a quarter of their original thickness; their tops
remain at the same three heights.

The four-frame running cycle alternates extended strides and passing/recovery
poses, with counter-swinging arms and contrasting boots. Airborne and crouched
poses are separate from the running cycle.

PF0, PF1 and PF2 cover all forty four-pixel columns: **160 pixels**, not only
the central 128. Scrolling advances a terrain column after four movement pixels.
Each reversible 16-bit LFSR state describes a sixteen-pixel chunk of platform
occupancy; the nonzero initial seed is `$ACE1`, with feedback polynomial `$B400`.
Moving left uses the inverse step, so returning to a location restores exactly
the same platforms. Chunk widths are bounded; the continuous road remains a
fallback, but the generator does not promise every overhead route is climbable.

## Cartridge

NTSC, **16K F6**, ordinary joystick, official 6502 opcodes only. No extra
cartridge RAM or emulator modifications are required.

The game-owned 181-line raster draws two eight-row sprites, an M0 shot, an M1
spark, and three independent full-width platform tiers. The visible terrain uses
**18 bytes**: left PF0/PF1/PF2 and reflected right PF2/PF1/PF0 for each tier.
This is three bytes more than a bit-packed 15-byte window, but needs no expanded
render cache. Gaps and the full-width road are implicit. Two LFSR endpoint states
and a chunk phase regenerate newly exposed columns without a stored level.
The Ball is disabled. M0 shares the courier palette; M1 shares the
monster palette, contrasting with the platforms. While a shot is active, M0 and
M1 alternate frames (30 Hz each); players and terrain remain steady at 60 Hz.
The courier retains per-row colours and reflects when facing left; monsters and
M1 use one tint from the monster palette. Missile enables commit in horizontal
blanking, avoiding partial scanlines as a missile approaches the left edge.
Collision probes sample the same
packed playfield bytes that the kernel displays. The six-glyph component supplies
the score above gameplay. TIA collision latches drive damage, kills and collection.
Physics runs in VBLANK; terrain updates and scoring run in overscan, keeping both
blanking deadlines bounded. Beam-critical graphics stay in the startup bank.
Overscan/VBLANK scratch aliases reuse dead renderer workspace, never persistent
coordinates or live drawing state.

`test/vcs_cinder_run.pl` builds the ROM and runs a CPU/input oracle covering
jumping, crouching, all three swept platform landings, solid undersides, falling
off ledges, injected missile/damage/collection responses, game over, restart,
Reset, distinct jump/catch tones, and all eight aim directions without accidental
movement. An additional 7,200-frame traversal compares every displayed terrain
column with an independent LFSR decoder, checks inverse steps and window endpoint
states, and verifies that revisiting terrain restores its bytes. Every frame must
retain the established 264-line period. Broken kills, ceilings and inverse steps
are rejected as negative controls; injected collisions do not prove TIA geometry.

`test/vcs_cinder_run_stella.pl` checks all 160 pixels of every platform scanline
and intervening gap, the full-width road, four running poses, Up jumping,
fixed-foot crouching, a real missile kill, and visible travel in all eight aim
directions. A scripted right/left excursion must restore the original platform
pixels. Three sweeps check M1 at X1..64, including vertical terrain seams: all
occupied scanlines must have identical horizontal spans. Captures use recorded
RawStream frame identities, never stream positions or artwork/ROM goldens.
