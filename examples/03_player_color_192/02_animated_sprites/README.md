```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Animated 8x8 sprite gallery

This cartridge demonstrates runtime bitmap animation with the official-opcode
192-line player-color renderer. P0 and P1 display two different four-frame
8x8 animations at the same time. After four complete four-frame cycles, the
cartridge advances to the next pair, eventually showing all eight adapted
sprite sets:

1. running man and dog;
2. cat and T. rex;
3. worm and orange hopper;
4. blue hopper and helicube.

The graphics table contains 32 frames in one page-aligned 256-byte object. Each
sprite set occupies 32 bytes, and each frame occupies eight bytes. Source glyphs
are written top row first through `game_SPRITE_GLYPH(...)`; that macro stores the
bytes in the renderer's required highest-index-to-zero display order.

Each animation frame is held for eight NTSC frames, and each pair remains on
screen for four complete animation loops before the automatic advance. The cartridge changes only
the low bytes of the two graphics pointers when selecting a new animation frame;
it does not copy bitmap data into RAM. This preserves the renderer's 192 visible
scanlines and leaves 20 bytes of RIOT RAM free.

## Controls

| Control | Action |
|---|---|
| Game Select | Advance immediately to the next pair of sprite sets |
| Left fire | Pause or resume animation |
| Game Reset | Restart through the cartridge reset vector |

Select and fire are edge-triggered, so holding either control does not repeat.

## Artwork attribution

The sprite concepts and animation names are adapted from Quick's PICO-8
cartridge **Free 8x8 Sprites**. They are not public-domain assets. See
[`ASSET_LICENSE.md`](ASSET_LICENSE.md) for the attribution and license applying
to the adapted sprite artwork.
