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

Each leaf directory contains one editable `.c26` cartridge, its Makefile, and a
README. Renderer and layout directories contain additional READMEs describing
the shared timing, resource, opcode, and composition contracts.

## Renderer groups

| Group | Renderer or architecture | Public diagnostic |
|---|---|---|
| [`01_basic`](01_basic/) | Small standalone cartridges and reusable lifecycle components | Blank screen, audio, score, and silicon fingerprint |
| [`02_faithful_legacy_playercolors`](02_faithful_legacy_playercolors/) | Faithful retained legacy player-color renderer, including its historical unofficial opcodes | Interactive P0/P1/Ball motion and integrated score editing |
| [`03_player_color_192`](03_player_color_192/) | Official-opcode, scoreless 192-line P0/P1/Ball renderer | Interactive full-range P0/P1/Ball motion |
| [`04_player_color_181`](04_player_color_181/) | Official-opcode 181-line P0/P1/Ball renderer plus an 11-line score profile | Ten-layout matrix: four production scores plus poison, each above/below |
| [`05_all_five_192`](05_all_five_192/) | Official-opcode, scoreless 192-line P0/P1/M0/M1/Ball renderer | Interactive five-object motion |
| [`06_all_five_181`](06_all_five_181/) | Official-opcode 181-line P0/P1/M0/M1/Ball renderer plus an 11-line score profile | Ten-layout matrix: four production scores plus poison, each above/below |
| [`07_player_color_181_unofficial`](07_player_color_181_unofficial/) | Stable/common-NMOS unofficial-opcode twin of group 04 | Matching ten-layout score/poison matrix |
| [`08_all_five_181_unofficial`](08_all_five_181_unofficial/) | Stable/common-NMOS unofficial-opcode twin of group 06 | Matching ten-layout score/poison matrix |

The four 181-line groups contribute a **40-cartridge composition matrix**:
four gameplay families x four production score layouts x two orders, plus eight
poison stress compositions. Together with the seven basic, legacy, and 192-line
cartridges, the public tree contains **47 editable cartridges**.

The unofficial groups are separate source-level examples rather than a build
switch hidden inside the official examples. Their template names and
`-Wa,--illegals` build option make the opcode policy visible.
