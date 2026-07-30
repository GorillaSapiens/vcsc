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
  05_all_five_192/
    01_interactive/
  06_all_five_181/
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
| [`05_all_five_192`](05_all_five_192/) | Official-opcode, scoreless 192-line P0/P1/M0/M1/Ball renderer | Interactive full-range five-object motion |
| [`06_all_five_181`](06_all_five_181/) | Official-opcode 181-line P0/P1/M0/M1/Ball renderer composed with an 11-line score | Interactive score-above and score-below layouts |

The player-color diagnostics expose P0, P1, and Ball with per-row player colors.
The all-five diagnostics expose P0, P1, M0, M1, and Ball with independent solid
P0/P1 colors, matching the timing tradeoff of the five-object renderers.
