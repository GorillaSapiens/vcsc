```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

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
| [`01_basic`](01_basic/) | Small standalone cartridges and reusable lifecycle components | Blank screen, audio, centered/wide scores, and silicon fingerprint |
| [`02_faithful_legacy_playercolors`](02_faithful_legacy_playercolors/) | Faithful retained legacy player-color renderer, including its historical unofficial opcodes | Interactive P0/P1/Ball motion and integrated score editing |
| [`03_player_color_192`](03_player_color_192/) | Official-opcode, scoreless 192-line P0/P1/Ball renderer | Interactive full-range motion for 29 attributed four-frame animations and the source's sole three-frame animation, expanded to a nonblank four-slot cycle, traversing the screen in 15 pairs |
| [`04_player_color_181`](04_player_color_181/) | Official-opcode 181-line P0/P1/Ball renderer plus an 11-line score profile | Ten-layout matrix: four production scores plus poison, each above/below |
| [`05_all_five_192`](05_all_five_192/) | Official-opcode, scoreless 192-line P0/P1/M0/M1/Ball renderer | Interactive five-object motion |
| [`06_all_five_181`](06_all_five_181/) | Official-opcode 181-line P0/P1/M0/M1/Ball renderer plus an 11-line score profile | Ten-layout matrix: four production scores plus poison, each above/below |
| [`07_player_color_181_unofficial`](07_player_color_181_unofficial/) | Stable/common-NMOS unofficial-opcode twin of group 04 | Matching ten-layout score/poison matrix |
| [`08_all_five_181_unofficial`](08_all_five_181_unofficial/) | Stable/common-NMOS unofficial-opcode twin of group 06 | Matching ten-layout score/poison matrix |
| [`09_bankswitching`](09_bankswitching/) | F8/F6/F4 and F8SC/F6SC/F4SC mapper diagnostics using generated reset and cross-bank bridges | Parameterized all-transition PASS/FAIL cartridge plus shared-Superchip-RAM persistence checks for simulator and Stella certification |
| [`10_faithful_legacy_multisprite`](10_faithful_legacy_multisprite/) | Faithful unbanked/non-Superchip legacy multisprite baseline with integrated score/playfield and retained unofficial opcodes | Fixed P0 + five multiplexed-P1 raster, asymmetric playfield, and six-digit score diagnostic |
| [`11_all_five_170`](11_all_five_170/) | Official parameterized all-five renderer at `lines:=170` | Interactive score-above + gameplay + score-below composition |
| [`12_all_five_170_unofficial`](12_all_five_170_unofficial/) | Stable/common-NMOS unofficial parameterized all-five twin at `lines:=170` | Matching interactive score-above + gameplay + score-below composition |
| [`13_player_color_170`](13_player_color_170/) | Official parameterized player-color renderer at `lines:=170` | Interactive score-above + P0/P1/Ball gameplay + score-below composition |
| [`14_multisprite`](14_multisprite/) | Parameterized modern P0 + five multiplexed-P1 renderer derived from the faithful legacy raster | 192-line interactive demo plus 181-line interactive score-above and score-below compositions |

The four 181-line groups contribute a **40-cartridge composition matrix**:
four gameplay families x four production score layouts x two orders, plus eight
poison stress compositions. Together with the ten basic, faithful-legacy, and 192-line cartridges plus the
bank-switching diagnostic wrapper and the three modern multisprite proofs, the public tree contains **61 editable
cartridges**.

The unofficial groups are separate source-level examples rather than a build
switch hidden inside the official examples. Their component filenames and
`-Wa,--illegals` build option make the opcode policy visible.

## Assembly policy

Public examples should use VCSC for ordinary application logic. Inline `asm` is kept
only for cycle-exact beam work, direct hardware idioms, or a documented language or
compiler limitation with a focused regression and an explicit removal follow-up. The
source test `test/example_assembly_allowlist.pl` inventories every remaining example
assembly block by normalized-statement hash, so new assembly cannot quietly enter the
examples without review.

The animated sprite gallery is intentionally a high-level stress case: its frame-page
selection, pointer arithmetic, packed-color expansion, palette lookup, and frame
installation are all ordinary VCSC. Its only remaining assembly is the small console
Reset-vector hardware idiom.

## License

Everything under `examples/` is covered under CC0-1.0 by default. The sole
exception is `03_player_color_192/02_animated_sprites/`, whose original artwork
and surrounding example are covered by that directory's CC BY-NC-SA 4.0
`LICENSE.txt`.
