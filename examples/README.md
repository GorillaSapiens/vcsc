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

Examples 05 through 13 form a deliberate 3×3 matrix:

| Motion | Full 192 lines | Score above | Score below |
|---|---|---|---|
| Static | 05 | 06 | 07 |
| X only | 08 | 09 | 10 |
| X and Y | 11 | 12 | 13 |

All nine matrix cartridges use the official multicolor P0+P1+Ball kernels.
They intentionally do not exercise M0 or M1; five-object kernel work remains a
separate later phase.
