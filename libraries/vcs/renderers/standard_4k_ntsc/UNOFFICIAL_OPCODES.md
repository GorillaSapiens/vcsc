```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See libraries/LICENSE.txt. -->

Standard 4K NTSC unofficial-opcode classification
=================================================

This document records the unofficial-opcode inventory made while legalizing
the normalized standard renderer. The final source sites were replaced, a
linked-byte gate was added, and the empty generated inventory plus its one-use
generator were retired. **No unofficial source sites remain** in this profile.

Historical classification vocabulary
------------------------------------

* **stable/common** means the used encoding and result are conventionally
  deterministic on original NMOS 6502/6507 silicon. It remains unofficial and
  is not a portability promise for CMOS descendants, FPGA cores, clones, or
  unrelated 6502-family CPUs.
* **silicon-sensitive** means the result or stored address depends on analogue
  or mask-specific behavior such as internal bus values or high-byte masking.
* **unstable** means software cannot rely on one repeatable result across normal
  NMOS parts or operating conditions.

No silicon-sensitive or unstable opcode was ever retained by this selected
profile. Earlier cleanup removed the stable/common `LAX` and `DCP` sites.
The final legalization pass removed the last three forms below.

Legal replacements
------------------

| Removed form | Legal replacement | Cycle treatment | Flags and bus effects |
|---|---|---|---|
| `ASR #$F0` / `ALR #$F0` (`$4B`) | `AND #$F0`; `LSR` | The blanking-only score helper grows from 2 to 4 cycles. The fixed VBLANK timer still determines visible-renderer entry. | The legal pair produces the same A, N, Z, and C result. Because the mask clears bit 0, carry is clear for the following `ADC`. It performs only instruction/operand reads and no writes. |
| `SBX #252` / `AXS #252` (`$CB`) | `TXA`; `ADC #4`; `TAX` | The row advance grows by 2 cycles. The following non-final and final transition pads shrink from 5/8 to 3/6 cycles, preserving both paths exactly. | Carry is known clear from the preceding `LDA #1` / `ADC #0` enable conversion. `CPX #44` immediately replaces N/Z/C; the prior conversion also leaves V clear, and A is dead before the next load. No memory bus write is introduced. |
| `NOP.z $00` (`$04`) | `BIT VSYNC` | Both are 3 cycles, so every odd `SLEEP` duration is unchanged. | `BIT` performs one read from TIA read address `$00` and no write. It preserves A, X, Y, C, D, and I while replacing N/V/Z. All five odd-delay sites have dead flags before the next flag consumer. |

The automated regression keeps the historical illegal byte/cycle probe opt-in
so assembler support for explicit silicon experiments does not disappear. It
also assembles the legal replacement byte matrix (`AND #$F0`, `LSR`, `TXA`,
`ADC #4`, `TAX`, `BIT VSYNC`) without `--illegals`. All standard-profile build
recipes now omit unofficial-opcode mode. The linked-code gate decodes every
executable profile segment and rejects unofficial instruction bytes, including
a negative control introduced through raw `op4B`.

The regression now scans the maintained source directly and separately verifies
the final linked executable bytes.

Historical all-five component byte comparison
---------------------------------------------

The separately named unofficial-opcode **181-line all-five gameplay
component** was an explicit experiment, not a hidden build alias. It was retired
in S9 after the comparison evidence was preserved. The official and unofficial
components exposed the same lifecycle API, consumed the same RAM, drew the same
181 scanlines, and shared the same corrected circular physical schedule. Only
reviewed stable/common NMOS forms were eligible.

The retired unofficial twin used one zero-page unofficial NOP (`$04`) as an
exact-size, exact-cycle replacement for dead-flag padding during VBLANK
positioning. It retained no AXS substitutions and no silicon-sensitive or
unstable opcodes. Ongoing unofficial-opcode opt-in coverage now belongs to the
assembler/toolchain regressions rather than a duplicate gameplay renderer.

The historical smoke cartridge measured:

```text
official linked ROM bytes:   1794
unofficial linked ROM bytes: 1794
signed byte difference:          0
```

Static and motion tests require pairwise visible TIA-event identity for both
score orders, matching public RAM addresses, full-range application-visible
object behavior, score composition, and stable 262-line frames.
