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
tank sprite is doubled vertically to 8x16 displayed pixels and has eight
orientations. The top and bottom arena walls are exactly four scanlines high.
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

For each joystick, Left and Right rotate the tank counterclockwise/clockwise.
Up moves forward in the direction the tank is pointing; Down moves backward.
Translation advances one pixel every fourth frame while held. A turn happens
immediately on a new Left/Right press, then a held turn repeats after 24 frames.
The fire button launches that tank's missile if its previous missile is no
longer active. A newly launched two-pixel missile is first rendered centered
horizontally across the tank (pixels 3-4 of its eight-pixel width); projectile
motion begins on the following frame.

Firing produces a short four-frame TIA noise burst. A player hit produces a
different, longer 24-frame noise burst, increments the shooter's score, stops
the projectile, and spins the struck tank rapidly for 24 frames. At the end of
the spin the tank is left facing a pseudo-random direction; movement, turning,
and firing are ignored for that tank while it is spinning.

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
mid-scanline. An 86-byte Superchip PF2 schedule supplies the top-wall continuation
and vertical barriers with constant-time loads. This keeps the complete NTSC
frame at the scheduler's stable 264-raw / Stella-262 cadence even at extreme
object positions and during simultaneous hit/audio/spin activity.

The cartridge is 8K F8SC. The current build uses 2237/3584 bytes in bank 1,
2402/3584 bytes in bank 0, 111/128 bytes of RIOT RAM (including the reserved
hardware stack), and 86/128 bytes of Superchip RAM. Console Reset clears both
scores, missiles, spin/audio state, and tank positions while selecting a new
barrier layout.
