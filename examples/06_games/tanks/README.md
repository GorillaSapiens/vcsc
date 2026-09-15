```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Tanks two-joystick example

`tanks` is a two-player tank duel using one joystick in each controller port. It
uses the same palette as the two-player Paddleball example: the left tank and
left score are blue, the right tank and right score are red, the background is
black, and the walls and barriers are white. The same three-plus-three score
component used by Paddleball draws a three-digit score for each player across
the top of the screen.

P0 and P1 draw the two tanks; M0 and M1 are their projectiles. Each 8x8 source
tank sprite is doubled vertically to 8x16 displayed pixels and the game has
sixteen headings in 22.5-degree steps. Only the 0..90-degree quadrant is stored:
N, NNE, NE, ENE, and E are five canonical 8-byte drawings. The other eleven
headings are synthesized from those 40 ROM bytes. `REFP0`/`REFP1` provide the
horizontal mirror and the renderer XORs a source-row index with either 0 or 7
to read a canonical sprite forward or backward. Thus no expanded 16-sprite ROM
table and no expanded RIOT-RAM bitmap cache are needed. The top and bottom arena
walls are exactly four scanlines high. The left and right walls are one reflected
TIA playfield bit wide, exactly four color clocks.

Three additional pseudo-random vertical barriers are generated from an 8-bit
LFSR. Each barrier is one PF2 bit wide (four color clocks) and 28 visible
scanlines high. `CTRLPF` reflection mirrors each barrier into the opposite half
of the arena. The compact representation is six ordered events, one start and
one end for each barrier; a seventh `0xff` row is the visible-kernel sentinel.
The three segments choose their X bits independently, while a small shared
vertical offset moves the complete three-barrier layout up or down. This leaves
at least ten clear doubled rows (20 visible scanlines) in each passage, so the
16-scanline-tall tanks have real maneuvering clearance. Reset generates a new
layout from the continuously advancing game LFSR; this is deliberately
lightweight pseudo-randomness, not hardware entropy.

For each joystick, Left and Right rotate the tank counterclockwise/clockwise by
one 22.5-degree heading. Up moves forward in the direction the tank is pointing;
Down moves backward. Translation advances on the existing four-frame cadence.
The four 45-degree headings change X and Y together on every movement step, and
the eight intermediate headings use a deterministic 7/16 minor-axis cadence
close to tan(22.5 degrees). Missiles, tanks, and ordinary movement share the same
compact 16-way motion primitive. A turn happens immediately on a new Left/Right
press, then a held turn repeats after 24 frames. The fire button launches that
tank's missile if its previous missile is no longer active. A newly launched
two-pixel missile is first rendered centered horizontally across the tank
(pixels 3-4 of its eight-pixel width); projectile motion begins on the following
frame.

TIA audio channel 1 supplies a quiet low-bass engine growl whenever either
player is holding Up or Down and that tank is not in a hit spin. The growl stays
continuous across the quarter-rate movement cadence. TIA audio channel 0 remains
independent for effects: firing produces a short four-frame noise burst, while a
player hit produces a different, longer 24-frame noise burst, increments the
shooter's score, stops the projectile, and spins the struck tank rapidly for 24
frames.

A hit also knocks the victim roughly 32 visible Atari pixels away from the
shooter. The projectile heading is rounded to the nearest octant; the LFSR then
selects a pseudo-random direction within the away half-plane. Horizontal
cardinal knockback is 32 pixels; vertical cardinal knockback is 16 doubled arena
rows, i.e. 32 visible scanlines. Diagonals use 23 horizontal pixels plus 11
doubled rows, about 31.8 visible pixels overall. Knockback deliberately ignores
playfield geometry. It can pass through an interior barrier, and crossing an
outer wall wraps the complete tank footprint through the legal 4..148 X or
4..78 Y coordinate span. If a tank lands overlapping playfield geometry, its
escape latch temporarily suppresses ordinary rollback until one clean frame is
reached, so it can always drive out. At the end of the hit spin the tank is left
facing a pseudo-random heading; movement, turning, and firing are ignored while
it spins.

All arena contact decisions use TIA collision latches from the raster that was
actually drawn. `CXM0FB`/`CXM1FB` stop projectiles on walls or barriers;
`CXM0P`/`CXM1P` score player hits. `CXP0FB`/`CXP1FB` normally make playfield
geometry solid by restoring the previous legal tank position, subject to the
post-knockback escape state above. `CXPPMM` similarly rolls both tanks back when
they collide. Player rollback is processed immediately after the arena at the
start of overscan, before controls can overwrite the previous legal position.
Missile collision, scoring, and hit-audio processing run in the following
VBLANK. The collision latches are cleared only after score drawing and the
player handoff.

The score component temporarily owns P0/P1. Player and missile positioning use
the usual subtract-by-15 coarse positioner, but the fine-motion table lookup is
deferred to a third line. The first two lines save only the subtraction
residuals in the already-existing `tanks_mnext[]` scratch bytes; the third line
loads HMP0/HMP1 or HMM0/HMM1 and performs HMOVE. This preserves exact RESP
timing while keeping even the extreme legal coordinates below the one-scanline
76-cycle boundary, without a 160-byte horizontal-position table.

The arena kernel is 172 lines, followed by a dedicated four-line bottom wall and
two blank tail lines for a 192-line visible field. P0/P1 graphics are published
at the start of each line-A, while the opposite half-line computes the next row,
missile staging, and the six-event PF2 barrier transitions. Work is deliberately
split across the two halves so the worst player+missile+barrier coincidence stays
below 76 CPU cycles. The complete NTSC frame remains at the scheduler's stable
264-raw / Stella-262 cadence, including the adversarial extreme-position case.

The cartridge is **plain unbanked 4K** with no Superchip or other cartridge RAM.
The current build uses 3800/4090 available ROM bytes and 116/128 RIOT RAM bytes
(108 bytes of objects plus the 8-byte reserved hardware stack), leaving 290 ROM
bytes and 12 RAM bytes free. Console Reset clears both scores, missiles,
spin/audio state, and tank positions while selecting a new barrier layout.
