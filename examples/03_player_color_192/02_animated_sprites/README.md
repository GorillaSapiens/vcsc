```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This example is covered under CC BY-NC-SA 4.0. See LICENSE.txt. -->

# Animated 8x8 sprite gallery

This cartridge demonstrates runtime bitmap animation, source-derived row colors,
and horizontal motion with the official-opcode 192-line player-color renderer.
It includes every source slot used by Quick's PICO-8 **Free 8x8 Sprites**
cartridge. The source contains 29 four-frame animations and one three-frame
animation: sprites 13, 14, and 15, followed by blank sprite 16. The blank slot
remains intact. That set uses its own modulo-3 phase, so it plays
13, 14, 15, 13 while its paired four-frame animation continues modulo 4.

P0 and P1 display two sets simultaneously on separate vertical lanes. Both move
one pixel to the right per NTSC frame through the renderer's color-safe range,
X=16 through X=140. The fixed margin keeps every COLUP/GRP update outside the
players' eight visible pixels; this example is testing animation colors, not
edge clipping. After X=140, both players return to X=16 with the next pair. The
15 pairs advance in source order and then wrap to the first pair.

## Bitmap conversion

Each PICO-8 frame is converted to a one-bit occupancy mask. Source color 0 is
transparent; every nonzero source color becomes a set Atari player bit. The 120
source slots occupy 960 real bitmap bytes: three 256-byte objects plus one
192-byte final object. All four are `page align(256)`, so the final object keeps
its low-byte-zero base without storing 64 literal padding bytes after source
sprite 120. Sprite 16 remains blank and is never selected.
Bitmap data is never copied into RAM; frame changes only replace the two graphics
pointers.

Glyph rows are written top row first through `game_SPRITE_GLYPH(...)`, which
stores them in the renderer's highest-index-to-zero display order.

## Color conversion

The conversion retains the original PICO-8 color information instead of assigning
a generic palette to each character. For every row of every source frame:

1. Ignore transparent pixels.
2. Choose the most frequent remaining PICO-8 color.
3. On a tie, choose the tied color whose pixels are nearest the row center.
4. If still tied, choose the lower PICO-8 palette index.
5. Map that source RGB color to the nearest NTSC TIA color.

A TIA player can use only one color per scanline, so a multicolor source row must
be reduced to one representative color. The resulting 960 row-color nibbles are
packed into 480 ROM bytes. When a frame is installed, its eight palette indices
are expanded into the renderer's mutable eight-byte RAM color table. Colors
therefore move vertically with the same source pixels as an animation bobs,
rather than remaining attached to fixed screen rows.

P0 uses the renderer's mutable-color timing path, which holds its next color until
VDELP0 transfers the matching delayed bitmap. P0 is placed at Y=55 so its
sixteen doubled scanlines remain within a normal renderer row; P1 uses Y=44.
Together with the X=16..140 motion range, the emulator oracle can require every
visible player pixel to use the selected source row's converted color.

Animation phase and frame-hold timing share one persistent RAM byte. The low
nibble contains the normal modulo-4 phase in bits 0..1 and the independent
source-set-03 modulo-3 phase in bits 2..3; the high nibble counts the eight NTSC
frames for which each animation frame is held. A sixteen-entry ROM transition
table advances both phase fields and clears the hold clock in one assignment.

Select-ready, fire-ready, and paused state share one additional flags byte. The
two adjacent animation-set selectors remain separate bytes: deriving `sprite1`
from `sprite0` saved one RAM byte in a measured trial but increased the linked
cartridge by 50 ROM bytes and grew `install_frames()` from 232 to 303 bytes, so
the smaller-ROM representation is retained. `install_frames()` itself remains
ordinary VCSC: it selects the hard ROM pages, computes frame offsets, expands
packed color nibbles through the palette, fills the mutable row-color arrays, and
installs the bitmap pointers without handwritten assembly or activation scratch.

Each frame is held for eight NTSC frames. One pair traversal takes 125 frames;
the complete fifteen-pair gallery takes 1,875 frames. The cartridge preserves
192 visible scanlines and exact 262-line NTSC frames. It uses 3,545 bytes of the
ordinary ROM region plus the six-byte vector segment and 106 RIOT RAM bytes, leaving
545 ordinary ROM bytes and 22 RAM bytes free.

## Controls

| Control | Action |
|---|---|
| Game Select | Advance immediately to the next pair and restart it at X=16 |
| Left fire | Pause or resume both movement and animation |
| Game Reset | Restart through the cartridge reset vector |

Select and fire are edge-triggered, so holding either control does not repeat.
Their two edge latches and the pause bit occupy one packed control byte.

## Artwork attribution

The sprite artwork and retained source palette information come from Quick's
PICO-8 cartridge **Free 8x8 Sprites**. They are not public-domain assets. This
directory is the sole exception to the examples tree's default CC0 license. See
[`LICENSE.txt`](LICENSE.txt) for attribution and the CC BY-NC-SA 4.0 terms.
