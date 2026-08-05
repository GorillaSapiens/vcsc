```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# vcsc-sim

`vcsc-sim` runs linked VCSC programs on the bundled MOS 6502 core.  It accepts
ordinary Intel HEX images and, with a banked linker cfg, raw F8/F6/F4 cartridge
images.  The simulator is useful for deterministic linker/runtime diagnostics;
Stella remains the independent authority for Atari mapper and TIA behavior.

## Command line

```sh
./vcsc-sim [options] program.hex
./vcsc-sim -T libraries/vcs/vcs_8k_f8.cfg program.bin
```

Supported forms include:

```sh
./vcsc-sim program.hex
./vcsc-sim program.hex 0x0c
./vcsc-sim --trace=0x20 program.hex -T linker/cfg/sim.cfg
./vcsc-sim -T libraries/vcs/vcs_16k_f6.cfg --start-bank=0 game.bin
./vcsc-sim -T libraries/vcs/vcs_32k_f4.cfg \
  --start-bank=7 --stop-pc=0xF234 --dump-on-stop game.bin
./vcsc-sim -T libraries/vcs/vcs_8k_f8sc.cfg --split-fill=0xA7 \
  --reset-on-pc=0xF234 --stop-pc=0xF234 --dump-on-stop game.bin
```

Options added for banked diagnostics are:

- `--start-bank=N` starts with physical/file chunk `N` selected.  This is not a
  VCSC logical `BANKn` name.  For the public profiles, physical index zero is
  the first 4K chunk in the file and VCSC BANK0 is the final chunk.
- `--stop-pc=ADDR` exits successfully before executing the instruction at
  `ADDR`.
- `--dump-on-stop` emits the complete logical 64K memory array as Intel HEX when
  `--stop-pc` fires. Tests use this to inspect RIOT and cartridge RAM signatures.
- `--split-fill=BYTE` fills every configured shared split-address region before
  the initial CPU reset. It is a hostile-initial-state test aid; zero remains the
  default for compatibility, but programs must not depend on either value.
- `--reset-on-pc=ADDR` performs one CPU reset immediately before executing
  `ADDR`, preserving ordinary and split-address RAM. The reset vector is fetched
  through the currently selected cartridge bank, so the generated reset bridge
  and startup initialization run exactly as they do after a console reset. A
  matching `--stop-pc` therefore stops on the second arrival.

The trace argument is parsed with `strtoul(..., 0)`, so decimal, hex, and octal
forms all work.

## Trace flags

- `0x0001` — memory reads
- `0x0002` — memory writes
- `0x0004` — register dump before each instruction
- `0x0008` — disassembly before each instruction
- `0x0010` — cycle-counter callback
- `0x0020` — simulator-dispatch logging

Banked cartridge trace lines include the selected physical/file chunk and its
VCSC logical bank name:

```text
read $F123 [file-bank=0 BANK3] -> $A9
```

## Cfg-based memory and mapper model

With `-T`, `--config`, or `--script`, the simulator parses the same
linker-style `MEMORY`, `CARTRIDGE`, and `BANKS` descriptions used by the public
profiles.

For an unbanked image, `type=ro` MEMORY ranges reject guest writes.  For a
banked image, the simulator additionally:

- accepts `mapper=F8`, `F6`, or `F4`;
- loads each complete 4K `.bin` chunk into the logical range named by its BANKS
  entry;
- maps every CPU cartridge-window fetch through the currently selected physical
  chunk while preserving the low twelve address bits;
- changes the selected chunk on reads or writes to the configured hotspots;
- fetches reset vectors through the selected bank, including F4's
  `$1FFA/$1FFB` vector/hotspot overlap;
- disables the `$FFFF` host dispatch escape hatch, because `$FFFF` is real
  cartridge/vector space in these profiles.

A raw `.bin` therefore requires a banked cfg.  An Intel HEX image can still be
used when logical bank ranges are already represented explicitly.

`--start-bank` defaults to the cfg entry marked `startup=yes`. Tests explicitly
run every physical start index to prove the generated reset bridges. Split RAM
persists across mapper hotspot changes and `--reset-on-pc`; only startup code
changes it after reset. The simulator's initial fill is not a hardware power-on
contract.

The simulator deliberately does not model TIA video, audio, or analogue
behavior.  The public bank-transition diagnostic is also run under Stella from
every forced startup bank and with randomized developer startup-bank selection.

## Dispatch hook

For flat, unbanked Intel HEX programs, the simulator reserves `JSR $FFFF` as
an escape hatch to host services.  The hook is disabled for banked cartridge
images because `$FFFF` is real cartridge/vector space.
When the CPU reaches program counter `$FFFF`, `vcsc-sim` does **not** execute whatever byte happens to live there. Instead it:

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

Split-address memory and Superchip mapper support
-------------------------------------------------
Any cfg `MEMORY` entry with both `read_start` and `write_start` is modeled as
one physical byte array with two CPU windows. The region name, window order,
window spacing, alignment, and size are not special-cased. Reads must use the
declared read window and writes must use the declared write window; the
simulator reports a directional-access error if generated code uses the wrong
alias. `--dump-on-stop` mirrors the final bytes into both declared windows so
the two aliases can be inspected directly.

With F8SC/F6SC/F4SC cfg files, the ordinary `superchip` entry therefore models
the shared 128-byte cartridge RAM without a compiler-specific name hook. The
mapper still provides the real cartridge mirroring: writes to the physical
`$1000-$107F` port update the storage and reads from `$1080-$10FF` return it
regardless of the selected ROM bank. The canonical BANK0 dump aliases remain
`$F000-$F07F` and `$F080-$F0FF`.
