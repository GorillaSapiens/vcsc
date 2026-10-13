```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# All five objects across colour sections

From this example directory:

```sh
make
make play
```

Use `make clean` to remove generated files. Alternatively, from the project root:

```sh
driver/vcsc -I libraries/vcs \
  examples/04_renderers/all_five_sections/all_five_sections_192.c26 \
  -o /tmp/all_five_sections.bin
stella /tmp/all_five_sections.bin
```

All five objects move vertically across eight sections with four palettes.
Motion wraps at the bottom. Change the `sectionN_lines`, `sectionN_colupf` and
`sectionN_colubk` arguments in the source's `instantiate` statement to configure
your own layout. Heights are even scanline counts totalling 192. Up to eight
sections are supported; omit unused slots (their heights default to zero).

The A and B each have eight intentional glyph rows, drawn across sixteen
hardware scanlines. The player-height value is the last row index (7 for 8 rows).

No JSON, Perl generator or extra configuration step is required.
See `libraries/vcs/renderers/all_five_sections_192/README.md` for the contract.
