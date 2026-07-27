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
| 05 | `multicolor_full_static` | Full 192-line static P0+P1+Ball display |
| 06 | `multicolor_score_above_static` | Static 181-line display with score above |
| 07 | `multicolor_score_below_static` | Static 181-line display with score below |
| 08 | `multicolor_full_dynamic_x_motion` | Full-height horizontal motion |
| 09 | `multicolor_score_above_dynamic_x_motion` | Horizontal motion with score above |
| 10 | `multicolor_score_below_dynamic_x_motion` | Horizontal motion with score below |
| 11 | `multicolor_full_dynamic_x_and_y_motion` | Full-height two-axis motion |
| 12 | `multicolor_score_above_dynamic_x_and_y_motion` | Two-axis motion with score above |
| 13 | `multicolor_score_below_dynamic_x_and_y_motion` | Two-axis motion with score below |

Examples 05 through 13 are intended to become a 3×3 matrix:

| Motion | Full 192 lines | Score above | Score below |
|---|---|---|---|
| Static | **05 certified** | 06 pending | 07 pending |
| X only | 08 pending | 09 pending | 10 pending |
| X and Y | 11 pending | 12 pending | 13 pending |

Only example 05 currently has pixel-level display certification and a reviewed
Stella reference. Examples 06 through 13 remain present for one-at-a-time
repair, but their successful builds and stable frame lengths must not be read as
proof that they render correctly.

These examples intentionally do not exercise M0 or M1. Five-object kernel work
remains blocked until every P0+P1+Ball example is independently certified.
