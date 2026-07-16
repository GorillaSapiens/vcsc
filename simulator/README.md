# n65sim

`n65sim` loads a linked Intel HEX image into a 64 KiB 6502 memory array, resets the bundled MOS 6502 core, and runs until the simulated program exits through the simulator dispatch hook.

## Command line

```sh
./n65sim [options] program.hex
```

The simulator expects an Intel HEX input file.
It accepts the input `.hex`, optional trace mask, and optional linker-style cfg in any order.
Supported forms are:

```sh
./n65sim program.hex
./n65sim program.hex 0x0c
./n65sim --trace 0x0c program.hex
./n65sim --trace=0x20 program.hex -T linker/cfg/sim.cfg
./n65sim linker/cfg/sim.cfg program.hex 0x20
```

The trace argument is parsed with `strtoul(..., 0)`, so decimal, hex, and octal forms all work.
For example, `0x0c` enables register and disassembly tracing, while `0x20` enables dispatch logging.

## Trace flags

Tracing can be enabled either from the command line or at runtime through the dispatch hook.
The trace bit assignments in `simulator/main.cpp` are:

- `0x0001` ... memory reads
- `0x0002` ... memory writes
- `0x0004` ... register dump before each instruction
- `0x0008` ... disassembly before each instruction
- `0x0010` ... cycle counter callback
- `0x0020` ... dispatch logging

Examples:

```sh
./n65sim program.hex 0x0c
./n65sim --trace=0x2f program.hex
./n65sim --trace 0x20 program.hex -T linker/cfg/sim.cfg
```

With tracing enabled, the simulator prints lines like:

```text
read $1234 -> $56
write $78 -> $1234
A:$01 X:$02 Y:$03 P:$24(nv-BdIzc) SP:$ff PC:$8000
ASM: $8000: lda #$01       ; a9 01
cycle 42
```

Notes:

- register tracing happens before each instruction
- disassembly tracing happens before each instruction
- cycle tracing prints the current instruction counter value passed to the clock callback
- dispatch logging is printed only when the dispatch trace bit (`0x20`) is enabled


## Optional cfg-based ROM protection

When a linker-style cfg is supplied with `-T`, `--config`, `--script`, or as a positional `.cfg` file, `n65sim` reads its `MEMORY` block and treats every `type = ro` region as read-only for guest writes. A guest write into one of those regions stops the simulator with a diagnostic such as:

```text
n65sim: write to read-only memory at $2FFF
```

This protection applies only to guest-side writes through the emulated CPU. The simulator allows its own image loader and internal `$FFFF` dispatch shim to touch memory as needed.

## Dispatch hook

The simulator reserves `JSR $FFFF` as a host-call escape hatch.
When the CPU reaches program counter `$FFFF`, `n65sim` does **not** execute whatever byte happens to live there. Instead it:

1. reads the dispatch opcode from register `A`
2. reads a 16-bit argument from `Y:X` (`X` = low byte, `Y` = high byte)
3. calls the host-side `dispatch(op, arg)` function in `simulator/main.cpp`
4. temporarily plants an `RTS` at `$FFFF` so the guest code returns normally to the caller after the hook finishes

That means guest code can treat the hook like an ordinary subroutine call.

Example:

```asm
lda #$00
ldx #<message
ldy #>message
jsr $ffff
```

When dispatch tracing is enabled (`trace_ops & 0x20`), the simulator logs each dispatch first as:

```text
dispatch <op> <arg>
```

where `<op>` is two hex digits and `<arg>` is four hex digits.

## Dispatch functions

### `A = $00` ... print NUL-terminated string

- argument: `Y:X` points at a NUL-terminated byte string in simulated memory
- output: the bytes are printed to stdout as a C string

Example:

```asm
lda #$00
ldx #<message
ldy #>message
jsr $ffff
```

### `A = $FD` ... set trace bitmask

- argument: new trace bitmask in `Y:X`
- output: none beyond the optional `dispatch fd xxxx` log line when dispatch tracing is enabled
- effect: replaces the current `trace_ops` mask

This can be used to turn tracing on, off, or switch modes at runtime.
For example, `arg = $002c` enables register tracing, disassembly tracing, and dispatch logging, while `arg = $0000` disables all optional trace output.

Example:

```asm
lda #$fd
ldx #$2c
ldy #$00
jsr $ffff
```

### `A = $FE` ... dump all memory as Intel HEX

- argument: ignored
- output: the entire 64 KiB `mem[]` array is written to stdout as Intel HEX records, wrapped in markers:

```text
---8<--- BEGIN MEMORY DUMP ---8<---
... Intel HEX records ...
---8<---  END MEMORY DUMP  ---8<---
```

The dump emits one 16-byte data record for each address range from `$0000` through `$FFFF`, followed by the normal Intel HEX EOF record.

Example:

```asm
lda #$fe
ldx #$00
ldy #$00
jsr $ffff
```

### `A = $FF` ... exit the simulator

- argument: process exit status in `Y:X`
- output: none beyond the optional `dispatch ff xxxx` log line when dispatch tracing is enabled
- effect: calls `exit(arg)` on the host process

Example:

```asm
lda #$ff
ldx #$00
ldy #$00
jsr $ffff
```

This exits with status 0.
