```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# PAL and SECAM examples

This group keeps PAL and SECAM explicit while sharing the common 50 Hz frame
machinery.

- `00_pal50_blank`: minimal 312-line PAL50 frame.
- `00_secam50_blank`: minimal 312-line SECAM50 frame.
- `01_pal50_all_five`: interactive five-object 192-line gameplay kernel centered
  in the PAL 228-line visible window with PAL colors.
- `02_secam50_all_five`: the same geometry using only the eight legal SECAM
  display colors.

The interactive examples use 17 measured pre-component helper lines and an
18-line visible tail.  This is an emulator-verified phase composition, not a
simple `228 - 192` arithmetic split; the renderer owns its terminal WSYNC
boundary.

