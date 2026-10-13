```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# All five objects across colour sections

From the project root:

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

No JSON, Perl generator or extra configuration step is required.
See `libraries/vcs/renderers/all_five_sections_192/README.md` for the contract.
