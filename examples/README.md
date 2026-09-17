```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# VCSC examples

The public examples are organized by **purpose**, not by historical migration
numbers. There are seven runnable top-level categories:

| Category | Purpose |
|---|---|
| [`01_basics`](01_basics/) | Small standalone introductory cartridges |
| [`02_components`](02_components/) | Focused reusable-component demonstrations |
| [`03_controllers`](03_controllers/) | Joystick, paddle, keypad, and driving-controller examples |
| [`04_renderers`](04_renderers/) | Maintained display-renderer families and score compositions |
| [`05_video_standards`](05_video_standards/) | Matched NTSC/PAL/SECAM demonstrations |
| [`06_games`](06_games/) | Complete interactive game examples |
| [`07_diagnostics`](07_diagnostics/) | Hardware, mapper, and toolchain diagnostics |

`_common/` is shared source support for examples in those categories. It is not
a runnable example group and deliberately contains no Makefile.

Each runnable leaf has its own Makefile. Most leaves contain one editable `.c26`
cartridge source plus a README; mapper diagnostics with multiple closely related
ROMs keep those ROMs together under one leaf where that relationship is part of
the example contract.

## Renderer identities

`04_renderers/` names the renderer being demonstrated rather than the old source
bucket it came from:

- `faithful_legacy_player_color/` — retained legacy player-color baseline with
  its historical unofficial-opcode behavior.
- `player_color/` — official-opcode P0/P1/Ball renderer, including scoreless,
  animated, 181-line score-composition, and 170-line dual-score examples.
- `player_color_unofficial/` — matched stable/common-NMOS unofficial-opcode peer.
- `all_five/` — official-opcode P0/P1/M0/M1/Ball renderer family.
- `all_five_unofficial/` — matched unofficial-opcode all-five peer; its Makefiles
  visibly opt in with `-Wa,--illegals`.
- `all_five_player_color/` — all-five renderer with independent P0/P1 row colors.
- `faithful_legacy_multisprite/` — retained legacy P0 + five multiplexed-P1
  baseline.
- `multisprite/` — maintained parameterized multisprite renderer.
- `enhanced_multisprite/` — maintained asymmetric-playfield enhanced multisprite
  renderer.

The original four 181-line score families still form the same 40-cartridge
composition matrix: four gameplay families x four production layouts x two
orders, plus eight poison stress compositions. Moving them into renderer-named
trees did not change their cartridge behavior.

## Video-standard matrix

`05_video_standards/` is demonstration-first. Each demonstration contains
`ntsc/`, `pal/`, and `secam/` cells so the same intent can be compared directly
across standards. The six demonstrations form an 18-cell matrix: blank,
player-color, official all-five, unofficial all-five, multisprite, and enhanced
asymmetric multisprite.

## Diagnostics

`07_diagnostics/` contains the 6507 fingerprint, the multi-standard F4SC field
and controller diagnostic, and the complete mapper diagnostic family under
`07_diagnostics/bankswitching/`. Mapper leaves keep hardware names such as
`f864`, `ua`, `3e_max`, and `3ex_max`; F8/F6/F4 and UA/UASW deliberately keep
multiple related ROMs in a single leaf.

Across all seven categories the tree contains **118 recursively discovered
runnable example Makefiles**: 110 migrated examples plus eight examples added by
the reorganization plan.

## Direct Register Access in examples

Maintained examples use the final Direct Register Access spelling for simple
physical-register operations. In particular, an Atari write-only strobe that
must store the accumulator is written `WSYNC := $A;` (and similarly for other
strobe registers) rather than the retired lone `_` spelling. When an expression
is evaluated only for side effects, examples use the ordinary `(void)` discard
form. Lone `_` is no longer accepted by the compiler.

DRA does not replace cycle-counted renderer assembly merely to reduce assembly
usage. The example assembly allowlist retains beam-critical multi-instruction
sequences whose exact scheduling belongs in assembly, while isolated native
register/flag operations may use `$A`, `$X`, `$Y`, `$S`, and the supported
status-flag forms documented in `compiler/README.md`.

## Assembly policy

Public examples should use VCSC for ordinary application logic. Inline `asm` is
kept only for cycle-exact beam work, direct hardware idioms, or a documented
language/compiler limitation with a focused regression and an explicit removal
follow-up. `test/example_assembly_allowlist.pl` inventories every remaining
example assembly block by normalized-statement hash, so new assembly cannot
quietly enter the examples without review.

The animated sprite gallery is intentionally a high-level stress case: frame-page
selection, pointer arithmetic, packed-color expansion, palette lookup, and frame
installation are ordinary VCSC. Its remaining assembly is the small console
Reset-vector hardware idiom.

## License

Everything under `examples/` is CC0-1.0 by default. The sole exception is
[`04_renderers/player_color/animated_sprites/`](04_renderers/player_color/animated_sprites/):
its original artwork and surrounding example are covered by that directory's
CC BY-NC-SA 4.0 [`LICENSE.txt`](04_renderers/player_color/animated_sprites/LICENSE.txt).
