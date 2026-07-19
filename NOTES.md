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
| Wide binary scalars         | The callee-owned memory-return ABI can carry wider values, but ordinary binary integer definitions and operators are still restricted to one or two bytes until the planned width-generalization work is completed.                                                    | `context.txt`, `compiler/compile_type.c`, `compiler/compile_function.c`                        |
| Peephole optimizer        | The peephole pass is intentionally conservative: mostly compiler-owned scratch/immediates, one-sided branch cleanup, no aggressive memory reasoning.                                                                                       | `compiler/README.md:745-747`                                                                 |
| Assembler o65 output      | o65 relocation expressions are limited: one relocatable term, no subtracting relocatable expressions, no multiply/divide relocatable expressions, and no external/cross-segment branch targets.                                            | `assembler/o65.c:668-707`, `assembler/o65.c:1031-1039`                                       |
| Linker                    | Linker is only a companion o65 subset; branch relocations are unsupported, config parsing is intentionally small, and Intel HEX output is sparse records.                                                                                  | `linker/README.md:165-180`                                                                   |
| Simulator timing          | Cycle accuracy is not implemented, so mid-frame hardware tricks are not reliable.                                                                                                      | `simulator/mos6502/README.md:37-38`                                                          |

`test/unimpl_audit.pl` reports no live `error_unimplemented()` feature stubs beyond the diagnostic function itself. This list is based on static audit notes and targeted checks, not a completed full-suite verdict.
