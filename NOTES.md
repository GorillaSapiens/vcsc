```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Additional missing / incomplete / limited features

| Area                      | Additional limitation                                                                                                                                                                                                              | Evidence                                                                                     |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------- |
| Const declarators         | `T * const p` style “const pointer object” syntax is not supported.                                                                                                                                                                    | `compiler/README.md:153-158`                                                                 |
| Bitfields                 | Bitfields must be plain integer scalar, non-array fields. All multibyte types are little-endian.                                                                                                                                      | `compiler/compile_toplevel.c:894-920`                                                        |
| Packed BCD conversions    | Compile-time integer constants convert numerically to and from packed BCD, but runtime BCD/binary conversion is deliberately rejected until explicit conversion operations exist. Raw byte writes can manufacture invalid BCD digit nibbles outside the language guarantee. | `compiler/README.md`, `compiler/compile_expr_slot.c`, `compiler/compile_init.c`                |
| Wide binary scalars       | The core and stock headers support ordinary signed/unsigned and packed-BCD widths from one through four bytes.                                                   | `context.txt`, `compiler/compile_type.c`, `compiler/compile_function.c`                        |
| Peephole optimizer        | The peephole pass is intentionally conservative: mostly compiler-owned scratch/immediates, one-sided branch cleanup, no aggressive memory reasoning.                                                                                       | `compiler/README.md:745-747`                                                                 |
| Assembler o26 output      | o26 relocation expressions are limited: one relocatable term, no subtracting relocatable expressions, no multiply/divide relocatable expressions, and no external/cross-segment branch targets.                                            | `assembler/o26.c:668-707`, `assembler/o26.c:1031-1039`                                       |
| Linker                    | Linker is only a companion o26 subset; branch relocations are unsupported, config parsing is intentionally small, and Intel HEX output is sparse records.                                                                                  | `linker/README.md:165-180`                                                                   |
| Source function inlining  | Inline assembly is supported, but source-level `inline` functions are not. Ordinary calls are prologue-free JSR/body/RTS; timing-aware inlining needs explicit language and cycle-policy work. | `compiler/parser.y`, `compiler/README.md`, `context.txt`                                      |
| Simulator timing          | Cycle accuracy is not implemented, so mid-frame hardware tricks are not reliable.                                                                                                      | `simulator/mos6502/README.md:37-38`                                                          |

`test/unimpl_audit.pl` reports no live `error_unimplemented()` feature stubs beyond the diagnostic function itself. This list is based on static audit notes and targeted checks, not a completed full-suite verdict.

## Width-generic scalar core

The compiler's ordinary binary-integer machinery accepts one- through four-byte little-endian signed or unsigned scalar declarations. Assignment, numeric literal encoding, widening/truncation, parameters, callee-owned memory returns, add/subtract, comparisons, bitwise operations, shifts, compound assignment, increment/decrement, multiplication, division, remainder, and constant folding are width-generic through four bytes. The stock VCS headers expose canonical signed and unsigned 8-, 16-, 24-, and 32-bit names.
