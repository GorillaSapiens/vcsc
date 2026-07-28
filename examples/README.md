```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# VCSC examples

Examples are grouped first by the renderer or display architecture they
exercise. Numbers are local to each directory and are append-only presentation
identifiers, not permanent global IDs. New examples may be added without
renumbering unrelated renderer groups.

```text
examples/
  01_basic/
  02_faithful_legacy_playercolors/
  03_player_color_192/
    01_full/
  04_player_color_181/
    01_score_above/
    02_score_below/
```

Each leaf directory contains one editable `.c26` cartridge, its Makefile, and a
README. Renderer and layout directories contain additional READMEs describing
the shared timing, resource, and composition contracts.

## Renderer groups

| Group | Renderer or architecture | Examples |
|---|---|---|
| [`01_basic`](01_basic/) | Small standalone cartridges and reusable lifecycle components | Blank screen, audio, score, silicon fingerprint |
| [`02_faithful_legacy_playercolors`](02_faithful_legacy_playercolors/) | Faithful retained legacy player-color renderer | Static compatibility baseline |
| [`03_player_color_192`](03_player_color_192/) | Official-opcode, scoreless 192-line P0/P1/Ball renderer | Static, X motion, X/Y motion |
| [`04_player_color_181`](04_player_color_181/) | Official-opcode 181-line P0/P1/Ball renderer composed with an 11-line score | Score above and score below; static, X motion, X/Y motion |

The renderer groups intentionally describe only the public examples currently
present. Other library renderers, including all-five-object variants, remain
covered by dedicated fixtures until public examples are added for them.
