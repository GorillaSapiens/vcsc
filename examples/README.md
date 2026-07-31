```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# VCSC examples

Examples are grouped first by the renderer or display architecture they
exercise. Numbers are local to each directory and are append-only presentation
identifiers, not permanent global IDs.

```text
examples/
  01_basic/
  02_faithful_legacy_playercolors/
    01_interactive/
  03_player_color_192/
    01_interactive/
  04_player_color_181/
    01_score_above/
      01_interactive/
    02_score_below/
      01_interactive/
```

Each leaf directory contains one editable `.c26` cartridge, its Makefile, and a
README. Renderer and layout directories contain additional READMEs describing
the shared timing, resource, and composition contracts.

## Renderer groups

| Group | Renderer or architecture | Public diagnostic |
|---|---|---|
| [`01_basic`](01_basic/) | Small standalone cartridges and reusable lifecycle components | Blank screen, audio, score, silicon fingerprint with upper-right and lower-left VCSC logos |
| [`02_faithful_legacy_playercolors`](02_faithful_legacy_playercolors/) | Faithful retained legacy player-color renderer | Interactive P0/P1/Ball motion and integrated score editing |
| [`03_player_color_192`](03_player_color_192/) | Official-opcode, scoreless 192-line P0/P1/Ball renderer | Interactive full-range P0/P1/Ball motion |
| [`04_player_color_181`](04_player_color_181/) | Official-opcode 181-line P0/P1/Ball renderer composed with an 11-line score | Interactive score-above and score-below layouts |

The renderer groups intentionally describe only the public examples currently
present. These player-color profiles expose P0, P1, and Ball; M0 and M1 remain
covered by dedicated all-five-renderer fixtures until public examples are added
for those profiles.
