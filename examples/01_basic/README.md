```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Basic cartridges and components

These examples do not share one gameplay renderer. They introduce the toolchain
and the lifecycle-component model in small, independently understandable steps.

| No. | Example | Display architecture |
|---:|---|---|
| 01 | [`blank_screen`](01_blank_screen/) | Inline 262-line NTSC frame with a constant background |
| 02 | [`blank_noasm`](02_blank_noasm/) | The same basic 262-line frame expressed entirely in VCSC source |
| 03 | [`ode_to_joy`](03_ode_to_joy/) | Inline frame scheduler plus TIA audio updates during overscan |
| 04 | [`score`](04_score/) | `frame_ntsc.c26` composed with the 11-line `six_glyph_component.c26` |
| 05 | [`fingerprint`](05_fingerprint/) | Centered Whimsey fingerprint with fixed `012345` VCSC logos at upper right and lower left |
| 06 | [`wide_score`](06_wide_score/) | `frame_ntsc.c26` composed with the 88-pixel-wide `six_glyph_wide_component.c26` |

The score, wide-score, and fingerprint examples demonstrate component composition rather than
a full gameplay renderer. They own the surrounding blank visible lines and call
each six-glyph component at its calibrated entry phase. The fingerprint example
combines centered, left-justified, and right-justified eleven-line variants and
reuses score digits as six slices of a wider logo.
