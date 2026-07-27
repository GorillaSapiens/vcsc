```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

Standard 4K NTSC unofficial-opcode classification
=================================================

This document began as the task-20o inventory taken before legalizing the
normalized standard renderer. After task 20r removed the final source sites and
task 20s added a final linked-byte gate, the empty generated TSV and its one-use
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
profile. Tasks 20p and 20q removed the stable/common `LAX` and `DCP` sites.
Task 20r removed the last three forms below.

Task-20r legal replacements
---------------------------

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

Completed all-five component byte comparison
--------------------------------------------

Roadmap task 22i brings back the separately named unofficial-opcode
**181-line gameplay component** as a completed experiment. It is not a reversal of the
official predecessor policy and it is not selected by a hidden build alias.
The official and unofficial components must expose the same lifecycle API,
consume the same RAM, draw the same 181 scanlines, produce the same visible TIA
writes and object positions, and pass the same static/motion cartridges. Only
reviewed stable/common NMOS forms may be used.

The comparison reports linked executable bytes for otherwise identical
cartridges:

```text
official linked ROM bytes
unofficial linked ROM bytes
signed byte difference
```

No saving is assumed. A zero-byte result, growth caused by padding/alignment, or
rejection of a candidate whose timing cannot be matched is a successful and
publishable outcome.


Measured result
---------------

The matched `all_five_181_unofficial` component uses four stable/common
`AXS #252` sites and three stable/common zero-page NOP (`$04`) sites.
The row-boundary PF1 preload replaced the fourth `$04` site with an ordinary
two-cycle NOP while preserving the matched raster. Compensating NOPs preserve
every official cycle boundary. The maintained smoke
cartridge measures 1421 linked ROM bytes for both components: **0 bytes saved**.
Pairwise static/motion raster tests and the 360-frame motion oracle enforce the
claimed equivalence.

Completed player-color component byte comparison
------------------------------------------------

The matched `player_color_181_unofficial` component uses two reviewed
stable/common `AXS #252` sites and four stable/common zero-page NOP (`$04`)
sites. Two other candidate `AXS` substitutions were rejected by emulator
comparison because the official sequences' flag results were live and the
candidate cartridges failed to complete frames. Compensating NOPs preserve the
accepted sites' exact cycle boundaries.

The terminal-row raster repair moves cleanup behind a scanline boundary and
adds a compact 30-cycle blank-line phase pad. The maintained smoke cartridge
therefore measures 1429 linked ROM bytes for both the official and unofficial
components: **0 bytes saved**. Pairwise smoke, static,
and motion raster/timing tests cover both score orders, and the existing
320-frame player-color motion oracle enforces full-range P0/P1/Ball behavior,
per-row colors, and application-state preservation.
