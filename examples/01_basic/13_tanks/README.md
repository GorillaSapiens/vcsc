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
tank sprite is doubled vertically to 8x16 displayed pixels and has sixteen
orientations in 22.5-degree steps. The sprite table is intentionally written as
one visual-binary `0b...X....` byte per source line so every orientation can be
inspected directly in the C26 source. N, NNE, and NE are the canonical drawings;
the other thirteen headings are rotations or reflections of those shapes. The
intermediate sprites cant the complete hull so NNE/ENE/ESE/etc. are visibly
separate headings rather than cosmetic variants of the eight old directions.
The top and bottom arena walls are exactly four scanlines high.
The left and right walls are one reflected TIA playfield bit wide, exactly four
color clocks.

Three additional pseudo-random vertical barriers are generated from an 8-bit
LFSR. Each barrier is one PF2 bit wide (four color clocks) and 28 visible
scanlines high. `CTRLPF` reflection mirrors each barrier into the opposite half
of the arena, so each generated segment appears as a symmetric pair of narrow,
tall obstacles. The three segments occupy separate Y bands and choose their X
bit and Y offset independently. The generator advances continuously while the
game is played, so pressing the console Reset switch selects another layout
based on when Reset was pressed. This is deliberately lightweight
pseudo-randomness, not a claim of hardware entropy.

For each joystick, Left and Right rotate the tank counterclockwise/clockwise by
one 22.5-degree heading. Up moves forward in the direction the tank is pointing;
Down moves backward. Translation advances on the existing four-frame cadence.
Movement follows the same logical coordinate geometry as the sprite table: the four
45-degree headings change X and Y together on every movement step, and the eight
intermediate headings use a deterministic 7/16 minor-axis cadence close to
tan(22.5 degrees). The renderer doubles each source row, but movement deliberately
does not compensate for that doubling; doing so would make a projectile diverge
from the rendered angle of its tank. Missiles and tanks use the exact same 16-way
motion table. A turn happens immediately on
a new Left/Right press, then a held turn repeats after 24 frames.
The fire button launches that tank's missile if its previous missile is no
longer active. A newly launched two-pixel missile is first rendered centered
horizontally across the tank (pixels 3-4 of its eight-pixel width); projectile
motion begins on the following frame.

TIA audio channel 1 supplies a quiet low-bass engine growl whenever either
player is holding Up or Down and that tank is not in a hit spin. The growl stays
continuous across the quarter-rate movement cadence instead of pulsing only on
the frames where position changes. TIA audio channel 0 remains independent for
effects: firing produces a short four-frame noise burst, while a player hit
produces a different, longer 24-frame noise burst, increments the shooter's
score, stops the projectile, and spins the struck tank rapidly for 24 frames. A
hit also knocks the victim roughly 32 visible Atari pixels away from the shooter.
The projectile heading is rounded to the nearest octant for hit-knockback geometry,
while the LFSR selects among straight-away, adjacent diagonal, and occasional
perpendicular headings; no choice ever points back toward the shooter. Horizontal cardinal
knockback is 32 pixels; vertical cardinal knockback is 16 doubled arena rows, i.e.
32 visible scanlines. Diagonals use 23 horizontal pixels plus 11 doubled rows,
about 31.8 visible pixels overall. Hit knockback deliberately ignores arena
geometry: it can pass straight through an interior playfield barrier, and crossing
an outer wall wraps the complete tank footprint into the opposite side of the
legal arena coordinate range. Ordinary joystick movement still treats all walls
and barriers as solid. At the end of the spin the tank is left facing a
pseudo-random direction; movement, turning, and firing are ignored for that tank
while it is spinning.

All arena contact decisions use the TIA collision latches from the raster that
was actually drawn. `CXM0FB`/`CXM1FB` stop M0/M1 on the outer walls or a
playfield barrier. `CXM0P` detects M0 hitting P1 and `CXM1P` detects M1 hitting
P0. `CXP0FB`/`CXP1FB` make the playfield barriers solid to the tanks by rolling
back the movement that produced a player/playfield overlap. `CXPPMM` does the
same for P0/P1 contact: both tanks return to their last legal positions, so they
cannot drive through each other even when both move on the same frame. Player
rollback happens immediately after the arena at the start of overscan, before
the next controls update can overwrite the saved last-legal position. Missile
collision, scoring, and hit-audio processing remain in the following VBLANK.
The latches are cleared only after the score and fixed-time player handoff, so
score pixels cannot contaminate gameplay collision state. Controls, hit-spin
advance, missile motion, Reset handling, and RNG advance run during overscan
after any required player rollback.

The score component temporarily owns P0/P1. A packed 160-entry position-control
table is prepared during VBLANK, then a fixed three-scanline handoff restores
P0/P1 after the 11-line score without coordinate-dependent divide loops in
visible time. The paired arena kernel is 172 lines; a dedicated four-line
bottom-wall phase follows it, then two blank tail lines complete the 192-line
visible field. P0/P1 graphics are published in the first 3/6 CPU cycles of each
line-A so moving tanks cannot tear at left-side X positions. The side-wall PF0
transition is likewise completed during horizontal blank, and the bottom wall
is established before its first visible pixel instead of changing PF0/PF1 in
mid-scanline. An 86-byte `cartram` PF2 schedule supplies the top-wall continuation
and vertical barriers with constant-time loads. This keeps the complete NTSC
frame at the scheduler's stable 264-raw / Stella-262 cadence even at extreme
object positions and during simultaneous hit/audio/spin activity.

The cartridge is 8K F8SC. The source has no explicit `bank0`/`bank1` code or
constant placement: the linker automatically partitions those whole layouts while
keeping `main` and startup code in bank 0. Mapper-owned RAM remains explicitly
marked `cartram` in the source. The current build uses 3534/3584 bytes in bank 1,
3428/3584 bytes in bank 0, 127/128 bytes of RIOT RAM (113 bytes of objects plus
the 14-byte reserved hardware stack), and 102/128 bytes of cartridge RAM. The
two turn-repeat counters and the movement scratch byte are explicitly kept in
`cartram`; beam-facing position and graphics state remains in zero page. Console Reset clears both
scores, missiles, spin/audio state, and tank positions while selecting a new
barrier layout.
