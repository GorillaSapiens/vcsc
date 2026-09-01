```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# vcsc-sim

`vcsc-sim` runs linked VCSC programs on the bundled MOS 6502 core. It accepts
ordinary Intel HEX images and raw cartridge images. For VCS `.bin` files it reads
C26 cartridge/memory topology from `--map FILE`, or automatically from the
same-stem linker `.map` sidecar when present. Generic legacy linker cfg input via
`-T` remains supported as a separate mechanism. The simulator is useful for deterministic linker/runtime diagnostics; Stella remains the independent authority for Atari mapper and TIA behavior.

## Command line

```sh
./vcsc-sim [options] program.hex
./vcsc-sim --map program.map program.bin
```

Supported forms include:

```sh
./vcsc-sim program.hex
./vcsc-sim program.hex 0x0c
./vcsc-sim --trace=0x20 program.hex -T linker/cfg/sim.cfg
./vcsc-sim --map game.map --start-bank=0 game.bin
./vcsc-sim --map game.map \
  --start-bank=7 --stop-pc=0xF234 --dump-on-stop game.bin
./vcsc-sim --map game.map --split-fill=0xA7 \
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

- accepts `mapper=F8`, `F6`, `F4`, CBS `FA`, Harmony `FA2`, `JANE`, `0840`, `UA`, `UASW`, `0FA0`, `E0`, `FE`, `DPC`, `3F`, or `3E` (plus the SC variants);
- loads each physical `.bin` chunk into the logical range named by its BANKS
  entry (4K for the conventional banked profiles and FE, 1K for E0);
- maps every CPU cartridge-window fetch through the currently selected physical
  chunk; conventional mappers and FE preserve the low twelve address bits, while E0
  preserves the offset within each independently selected 1K segment;
- changes the selected chunk on reads or writes to the configured hotspots;
- fetches reset vectors through the selected bank, including F4's
  `$1FFA/$1FFB` vector/hotspot overlap;
- disables the `$FFFF` host dispatch escape hatch, because `$FFFF` is real
  cartridge/vector space in these profiles.

A raw `.bin` therefore requires a banked cfg.  An Intel HEX image can still be
used when logical bank ranges are already represented explicitly.

A BANKS entry may include `fileindex=N` when physical file order differs from
logical bank numbering. JANE uses this to preserve file banks 0/1/2/3 while
VCSC names physical startup bank 1 as logical `bank0`: selectors `$1FF0`,
`$1FF1`, `$1FF8`, and `$1FF9` select file banks 0, 1, 2, and 3 respectively.
Cfgs that omit `fileindex` retain the historical inferred ordering.

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

Raw unbanked 2K and 4K images are placed in the conventional cartridge window
when the map/config topology describes a direct cartridge. Superchip split-RAM
aliases likewise come from that topology. Other raw unbanked sizes are rejected
rather than guessed.

OMNI direct-multi support
-------------------------
The FA2 linked map models six/seven directly selected 4K banks at
`$1FF5-$1FFA/$1FFB` with 256 bytes of split-address cartridge RAM (write
`$1000-$10FF`, read `$1100-$11FF`) and bank 0 at power-up. Harmony `$1FF4`
persistence is intentionally outside the core simulator contract.

The OMNI linked map describes the planned OmniCart PHM direct-addressing model.
The simulator loads its eight 4K file chunks directly at logical `$1000`,
`$3000`, `$5000`, `$7000`, `$9000`, `$B000`, `$D000`, and `$F000`. OMNI has no
selected-bank state or selector hotspots; its map records are file-to-logical
placement records only. The `$1000-$1FFF` `cartram` entry is
same-address writable memory, while the seven program/constant islands remain
read-only. This mode exists to certify VCSC/OmniCart software before PHM hardware
is available; it is not an emulation of conventional Atari bank switching.

Split-address memory and Superchip mapper support
-------------------------------------------------
Any map/config memory entry with both `read_start` and `write_start` is modeled as
one physical byte array with two CPU windows. The region name, window order,
window spacing, alignment, and size are not special-cased. Reads must use the
declared read window and writes must use the declared write window; the
simulator reports a directional-access error if generated code uses the wrong
alias. `--dump-on-stop` mirrors the final bytes into both declared windows so
the two aliases can be inspected directly.

For 4KSC and F8SC/F6SC/F4SC map-driven simulation, the ordinary `cartram` entry
therefore models the shared 128-byte cartridge RAM without a compiler-specific name hook. The
mapper still provides the real cartridge mirroring: writes to the physical
`$1000-$107F` port update the storage and reads from `$1080-$10FF` return it
regardless of the selected ROM bank. The canonical BANK0 dump aliases remain
`$F000-$F07F` and `$F080-$F0FF`. FA uses the same split-memory model for its 256-byte `cartram`: writes `$F000-$F0FF`, reads `$F100-$F1FF`.

### 0840 / EconoBanking

`mapper=0840` models the two 4K physical banks selected by below-cartridge bus
accesses. The selector decoder uses the hardware-relevant `$1840` mask, so the
`$0800` family selects file bank 0 and the `$0840` family selects file bank 1.
Reads select after sampling the underlying console byte; writes both select the
bank and continue to the ordinary low-memory model. The bundled MOS6502 core
models the operand bus read performed by undocumented absolute NOP `$0C`, which
lets linker-generated state-preserving 0840 bridges execute faithfully.

`mapper=UA` and `mapper=UASW` use the UA Limited alias decoder. The simulator
canonicalizes each low-address access with `address & $1260`: `$0220` selects
UA bank 0 and `$0240` selects UA bank 1, while UASW reverses those associations.
Thus shifted aliases such as `$02A0/$02C0` work identically. As with 0840,
reads sample the underlying console byte before the mapper side effect and writes
continue to the ordinary low-memory model while also changing the selected bank.


### 0FA0 / Fotomania

`mapper=0FA0` models the Brazilian two-bank 8K scheme with physical/file bank 1
as the power-on bank. Selection is explicitly mask-decoded:

```text
(A & $16E0) == $06A0  -> file bank 0
(A & $16E0) == $06C0  -> file bank 1
```

The profile uses `$0FA0/$0FC0` as canonical accesses, but aliases that differ in
A11, A8, or A4-A0 behave identically. Reads and writes below the cartridge window
still reach the underlying console-side memory model before the bank-switch side
effect. Generated cross-bank transitions use the state-preserving absolute-NOP
read path introduced for 0840.

### 3F / 3E

`mapper=3F` maps the final physical 2K permanently at `$1800-$1FFF` and a
value-selected ROM bank at `$1000-$17FF`; writes in the low TIA page update the
lower-bank selection. `mapper=3E` keeps the same fixed-final ROM shape, uses
exact `$3F` writes to select lower ROM, and exact `$3E` writes to select one of
32 1K cartridge-RAM banks. In 3E RAM mode reads use `$1000-$13FF` and writes use
`$1400-$17FF`; returning through `$3F` restores lower-ROM mode.

### E0 / Parker Brothers

`mapper=E0` loads eight 1K physical/file chunks. At reset, physical banks 4, 5,
6, and 7 occupy `$1000-$13FF`, `$1400-$17FF`, `$1800-$1BFF`, and
`$1C00-$1FFF`. Reads or writes to `$1FE0-$1FE7`, `$1FE8-$1FEF`, or
`$1FF0-$1FF7` replace the selected physical bank in the corresponding first,
second, or third 1K window; the top window remains physical bank 7. Selector
reads sample the byte from fixed bank 7 before applying the switch, matching the
normal cartridge bus transaction order. Because E0 has three simultaneous bank
states, `--start-bank` is rejected for this mapper rather than pretending one
scalar start bank can describe it.

### DPC

`mapper=DPC` accepts the conventional 10,495-byte image: two 4K F8-style
program chunks, followed by 2K of DPC display data and the 255-byte Poly8 image
tail. Program bank 0/1 selection uses `$1FF8/$1FF9`; the DPC register window at
`$1000-$107F` overlays the first `$80` bytes of the selected program bank.

The simulator models the CPU-visible DPC data fetchers used by the public
diagnostic: top/bottom comparators, 11-bit counters, display/flag reads, music
mode flags/amplitude reads, RNG reset, and the Poly8 LFSR. Like Stella's DPC
implementation, the RNG is clocked before DPC-register and F8-hotspot accesses.
Display fetches read `display[2047-counter]` and decrement the non-music counter
modulo 2048. The 255-byte image tail is retained as conventional cartridge
image data; runtime RNG values are generated by the LFSR rather than read from
that tail.

### FE / SCABS

`mapper=FE` loads two 4K physical/file chunks. Physical bank 0 is the
`$F000-$FFFF` reset/startup view and physical bank 1 is the `$D000-$DFFF`
alternate view. FE does not switch on an address hotspot. Any mirrored access to
`$01FE` arms a latch; the **following bus cycle's data** selects the bank using
`((value >> 5) ^ 7) & 1`, which maps E/F values to bank 0 and C/D values to bank
1 for the released two-bank cartridge.

The simulator observes that ordering literally: a read from `$01FE` returns the
byte using the old bank state, then arms the latch, and only the next read/write
bus value changes the selected bank. This makes the released `SP=$FF`, direct
`JSR $Dxxx`, `RTS` idiom work without a synthetic hotspot. Reset restores
physical bank 0 and clears any pending latch.
