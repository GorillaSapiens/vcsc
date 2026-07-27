```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# VCSC examples

The public examples are intentionally ordered as a progression rather than a
collection of historical test cartridges.

| No. | Example | Purpose |
|---:|---|---|
| 01 | `blank_screen` | Minimal complete 4K NTSC cartridge |
| 02 | `ode_to_joy` | Frame-driven TIA audio |
| 03 | `score` | Standalone six-glyph score component |
| 04 | `fingerprint` | Unstable-opcode silicon fingerprint |
| 05 | `faithful_legacy_playercolors` | Faithful legacy player-color kernel example |
| 06 | `multicolor_full_static` | Pending-repair scoreless 192-line static P0+P1+Ball display |
| 07 | `multicolor_score_above_static` | Static 181-line display with score above |
| 08 | `multicolor_score_below` | Static 181-line display with score below |
| 09 | `multicolor_full_dynamic_x_motion` | Full-height horizontal motion |
| 10 | `multicolor_score_above_dynamic_x_motion` | Horizontal motion with score above |
| 11 | `multicolor_score_below_dynamic_x_motion` | Horizontal motion with score below |
| 12 | `multicolor_full_dynamic_x_and_y_motion` | Full-height two-axis motion |
| 13 | `multicolor_score_above_dynamic_x_and_y_motion` | Two-axis motion with score above |
| 14 | `multicolor_score_below_dynamic_x_and_y_motion` | Two-axis motion with score below |

Example 05 is checked separately. The kernel template is compared with a
retained-source audit using an identical fixture scene, while the public example
checks its 264-line frame schedule and exact sprite rows/colors. Its different
playfield scene is not compared with the pristine cartridge.

Examples 06 through 14 remain pending one-at-a-time display repair. Example 06
has build/frame/player/Ball smoke coverage, but no exact playfield-pixel
certification:

| Motion | Full 192 lines | Score above | Score below |
|---|---|---|---|
| Static | 06 pending | 07 pending | 08 pending |
| X only | 09 pending | 10 pending | 11 pending |
| X and Y | 12 pending | 13 pending | 14 pending |

These examples intentionally do not exercise M0 or M1. Five-object kernel work
remains blocked until every P0+P1+Ball example is independently certified.
