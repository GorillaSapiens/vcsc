```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This example is covered under CC BY-NC-SA 4.0. See LICENSE.txt. -->

# Animated 8x8 sprite gallery

This cartridge demonstrates runtime bitmap animation and horizontal motion with
the official-opcode 192-line player-color renderer. It includes every animated
frame used by Quick's PICO-8 **Free 8x8 Sprites** cartridge: source sprites 1
through 120, interpreted exactly as the source program does as 30 consecutive
four-frame sets.

P0 and P1 display two sets simultaneously on separate vertical lanes. Both begin
at visible X=0 and move one pixel to the right on every NTSC frame. Their
eight-pixel graphics progressively clip as they leave the right edge. After the
X=159 frame, both players respawn at X=0 with the next pair. The 15 pairs advance
in source order: sprites 1-4 with 5-8, then 9-12 with 13-16, continuing through
sprites 113-116 with 117-120 before wrapping to the first pair.

Each PICO-8 frame is converted to an exact one-bit occupancy mask: source color 0
is transparent and every nonzero source color becomes a set Atari player bit.
The source program includes a blank frame at sprite 16; this example preserves
it rather than silently "fixing" the artwork. Glyph rows are written top row
first through `game_SPRITE_GLYPH(...)`, which stores them in the renderer's
required highest-index-to-zero display order.

The 120 frames occupy 960 bytes in four page-aligned 256-byte objects. The final
hard page has 64 zero padding bytes after source sprite 120. Each set occupies 32
bytes and each frame occupies eight bytes. Runtime selection changes only the
player graphics-pointer bytes; bitmap data is never copied into RAM.

Each animation frame is held for eight NTSC frames while the sprites continue
moving. Some source animations bob vertically within their 8x8 cells. To keep
the multicolor bands attached to those sprites, the cartridge counts transparent
rows above each selected frame and rotates that player's eight-row palette by
the same amount into a mutable RAM color table. The 960 graphics bytes remain
byte-for-byte source-exact; only the row-color mapping changes. A completely
blank frame uses the unrotated palette because no color is visible.

A complete left-to-right traversal takes 160 frames, and the complete 15-pair
gallery takes 2,400 frames. The cartridge preserves 192 visible scanlines. It
uses 3,484 ROM bytes and 124 RIOT RAM bytes including the four-byte hardware
stack reserve, leaving 606 ROM bytes and 4 RAM bytes free.

## Controls

| Control | Action |
|---|---|
| Game Select | Advance immediately to the next pair and restart it at X=0 |
| Left fire | Pause or resume both movement and animation |
| Game Reset | Restart through the cartridge reset vector |

Select and fire are edge-triggered, so holding either control does not repeat.

## Artwork attribution

The sprite artwork comes from Quick's PICO-8 cartridge **Free 8x8 Sprites**. It
is not public-domain artwork. This directory is the one exception to the examples tree's default CC0
license. See [`LICENSE.txt`](LICENSE.txt) for the attribution and CC BY-NC-SA
4.0 terms covering this example.
