```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# VCSC compiler and language reference

VCSC is a small C-like language and compiler specialized for the Atari
2600/VCS. This document describes the behavior implemented by `vcsc-cc1`; it
does not assume familiarity with another compiler.

VCSC originated as an Atari-focused specialization of the broader
[N project](https://github.com/GorillaSapiens/n). The projects now have
separate source suffixes, object formats, runtimes, calling conventions, and
language surfaces. Parent-project features deliberately absent from VCSC are
listed tersely at the end of this document.

## Language summary

The largest differences from C are:

- Assignment uses `:=`; `=` is not the assignment operator.
- A lone underscore (`_`) is the discard token, not an identifier.
- Braces are required for `if`, `else`, `while`, `do`, and `for` bodies.
- Integer and pointer types are declared by the target support source. There
  are no implicit `char`, `short`, `int`, `long`, or `bool` types.
- Every ordinary function has one statically described activation: parameters,
  named locals, compiler scratch, and any return object use linker symbols rather
  than a per-call frame. A compile-time-constant byte offset into any such fixed
  linker symbol is emitted as a direct `symbol + offset` memory operand; Y is
  reserved for genuine runtime indexing or pointer indirection. The linker
  overlays activations whose call-graph lifetimes cannot overlap.
- Consequently, ordinary functions are non-reentrant and recursion is
  forbidden. The compiler and linker reject direct and mutual call cycles.
- Every ordinary call target is a directly named function with one visible
  signature.
- `inline` means mandatory source expansion, not an optimization hint.
- All language operators are built in.
- Inline assembly is available for cycle-counted and hardware-specific code.

## Includes, aliases, and conditional compilation

### Includes

```vcsc
include "vcs.c26"
```

An included file is processed once per translation unit. Identity is based on
an MD5 digest of its contents, so including identical content through different
paths still produces one inclusion.

### Instantiation

Reusable source components are instantiated explicitly:

```vcsc
instantiate "component.c26" as first
instantiate "component.c26" as second
```

`instantiate` uses the ordinary include search path but processes the selected
file on every invocation instead of participating in `include`'s MD5-based
include-once set. There is no semicolon after an `instantiate` directive.
The former `template` keyword has been removed; source must use `instantiate`.

Within instantiated source, the exact identifier `TEMPLATE` becomes the
instance identifier and an identifier beginning with `TEMPLATE_` normally
receives the instance prefix. Comments, strings, and unrelated identifier
substrings are not rewritten. Rewriting occurs before identifier classification
and UTF-8 symbol mangling, so ordinary and UTF-8 instance names are both
supported.

An instantiated component may declare integer-literal configuration parameters
at file scope:

```vcsc
parameter lines;
parameter color := 0x20;

uint8_t TEMPLATE_rows[TEMPLATE_lines];
uint8_t TEMPLATE_background := TEMPLATE_color;
```

A `parameter` declaration with no assignment is required. A declaration with
`:=` supplies a default and is optional. Parameter declarations end with a
semicolon and must precede uses of the corresponding `TEMPLATE_name`. The caller
supplies overrides in parentheses after the instance
name, using `:=`:

```vcsc
instantiate "renderer.c26" as game (lines:=192)
instantiate "renderer.c26" as short_game (lines:=181, color:=0x2e)
```

Instantiation argument values are integer literals, including VCSC hexadecimal,
octal, binary/visual-binary, and decimal forms. A declared `TEMPLATE_name`
parameter is replaced by the supplied literal or its default; remaining
`TEMPLATE_` identifiers continue to receive the instance prefix. Missing
required arguments, unknown arguments, duplicate arguments, and duplicate
parameter declarations are compile-time errors.

Declared parameter names are also integer constants in `#if` and `#elif` while
that instantiated source is being processed. The conditional sees the supplied
argument or the parameter default, so profile selection remains compile-time; no
run-time branch or parameter storage is emitted. `parameter` declarations are
valid only directly in the instantiated source file, not in an ordinary source
file or an included helper.

Ordinary includes inside instantiated source remain include-once. Nested
instantiations are allowed, while recursive instantiation of the same source is
diagnosed. Alias names, alias parameters, and identifier tokens in alias
replacement text participate in the same instance rewriting. Exact `TEMPLATE`
and leading `TEMPLATE_` identifier tokens in inline assembly are also rewritten
(or replaced by declared parameter literals) on assembler-identifier boundaries;
quoted assembler data and unrelated identifiers remain unchanged.
Definitions written directly in an instantiated file must name every
instance-owned file-scope function, object, typedef, tag, enum constant, table,
and source-visible assembler label with exact `TEMPLATE` or the leading
`TEMPLATE_` prefix. Ordinary included support files are exempt, so genuinely
shared declarations can live in one include-once header instead of being
redeclared by every instance. Assembler-local `@labels`, function locals,
function parameters, instantiation-parameter declaration names, and aggregate
members do not require the prefix.

### Aliases

Aliases are newline-terminated lexical substitutions:

```vcsc
alias LIMIT 314
alias inc(x) (x + 1)
alias add(a,b) (a + b)
```

Object-like aliases replace a bare identifier. Function-like aliases expand
only as `name(...)` with no whitespace before `(`.

Rules worth remembering:

- An alias name may be defined only once in a translation unit.
- Arguments are split with balanced-parenthesis and quoted-text awareness.
- Parameters shadow outer aliases during one expansion.
- Recursive alias expansion is rejected.
- Repeated parameter use duplicates argument text and therefore duplicates any
  side effects in that text.
- Replacement text is the rest of the definition line after trailing comments
  are removed; a trailing semicolon becomes part of the expansion.

Aliases are untyped text substitution, not functions or templates.

### Conditional compilation

Supported beginning-of-line directives are:

```text
#if expression
#ifdef NAME
#ifndef NAME
#elif expression
#else
#endif
```

`#if` and `#elif` accept integer literals, object-like aliases,
`defined(NAME)`, registered compiler-builtin calls, unary `!`, unary `+`/`-`,
`&&`, `||`, integer comparisons, and parentheses. Undefined names evaluate to
zero. Function-like aliases are not expanded in conditional expressions.
Skipped branches are lexer-inert except for nested conditional directives.

## Compiler builtins

Compiler builtins use ordinary call syntax but are owned by the compiler rather
than declared by source code. Their names are reserved, their arguments are
validated and folded at compile time, and they emit no runtime call or lookup
table. Registered builtins are available anywhere the compiler accepts an
integer constant expression, including global initializers, ordinary
expressions, and `#if`/`#elif` conditionals.

The VCS RGB matchers are:

```vcsc
uint8_t ntsc  := __builtin_ntsc_rgb(0xfd, 0x86, 0x85);
uint8_t pal   := __builtin_pal_rgb(0xf7, 0xe2, 0x7f);
uint8_t secam := __builtin_secam_rgb(0x21, 0x21, 0xff);
```

Each requires three compile-time integer arguments in `0..255`, uses squared
Euclidean RGB distance, and returns the nearest reference TIA byte as `uint8_t`.
Exact distance ties choose the lower TIA byte. NTSC and PAL consider the 128
meaningful even TIA bytes. PAL odd bytes are display color-loss states, not a
second source palette, so they are not matcher candidates. SECAM has only eight
distinct Stella reference colors; its matcher returns the canonical low even
bytes `$00,$02,...,$0e`.

The reference tables track Stella's standard NTSC/PAL/SECAM palettes. Display
palettes are approximations: real hardware, televisions, capture equipment, and
emulator settings can render different RGB values. These builtins are source
color conveniences, not promises about a particular display.

`builtin.c` contains the name/type/arity/argument-contract registry and shared
dispatch used by both the parser and conditional preprocessor. Domain-specific
evaluators live in `builtin_rgb.c`, which owns the reference tables and reusable
nearest-palette matcher.

## Types

The stock VCS machine definition, `libraries/vcs/vcs.c26`, declares:

```vcsc
type void     { $size:0 };
type *        { $size:2 $integer:unsigned $endian:little };
type int8_t   { $size:1 $integer:signed };
type uint8_t  { $size:1 $integer:unsigned };
type int16_t  { $size:2 $integer:signed $endian:little };
type uint16_t { $size:2 $integer:unsigned $endian:little };
type int24_t  { $size:3 $integer:signed $endian:little };
type uint24_t { $size:3 $integer:unsigned $endian:little };
type int32_t  { $size:4 $integer:signed $endian:little };
type uint32_t { $size:4 $integer:unsigned $endian:little };
type bcd8_t   { $size:1 $integer:unsigned $bcd };
type bcd16_t  { $size:2 $integer:unsigned $endian:little $bcd };
type bcd24_t  { $size:3 $integer:unsigned $endian:little $bcd };
type bcd32_t  { $size:4 $integer:unsigned $endian:little $bcd };
```

Most VCS programs should include `vcs.c26` instead of repeating these
declarations.

### Required names

The compiler requires `void`, `uint8_t`, and the two-byte unsigned pointer type
`*`. Other canonical names are required when their semantics are used:

- `int8_t` for character constants and string elements;
- `int16_t` for unannotated integer literals, `sizeof`, default enum values,
  and pointer differences.

The names `char`, `int`, and `bool` are ordinary identifiers until explicitly
introduced, for example:

```vcsc
typedef uint8_t bool;
typedef int8_t char;
typedef int16_t int;
```

`typedef` creates a simple alias for an already declared named type.

### Type declarations and flags

Ordinary binary integer types may be one through four bytes. Recognized flags
are:

- `$size:N`;
- `$integer:signed` or `$integer:unsigned`;
- `$endian:little` for multibyte values;
- `$bcd` on one- through four-byte unsigned packed-BCD types.

The pointer type `*` must be exactly two bytes and unsigned. Multibyte values
have one fixed little-endian representation.

### Structs, unions, enums, and bitfields

Struct and union names become types directly:

```vcsc
struct Pair {
   uint8_t first;
   uint16_t second;
};

// "Pair" is now directly usable as a type
Pair pair;

union WordBytes {
   uint16_t word;
   uint8_t bytes[2];
};

// "WordBytes" is now directly usable as a type
WordBytes wb;
```

Forward declarations are supported. Struct and union layouts may contain
arrays, pointers, nested aggregates, and integer bitfields. Signed bitfield
reads sign-extend; unsigned reads zero-extend. Packed-BCD bitfields are rejected.

Enum values are integer constants. The compiler chooses the smallest declared
ordinary binary integer type that represents the enum's complete value range.

## Integer literals and expression typing

Integer literals may be decimal, hexadecimal (`0x`), octal (leading `0`), or
binary (`0b`). Underscores may separate digits.

Binary literals also accept visual digits:

- `.` means zero;
- `X` or `x` means one.

For example, `0b..XXX...` is the same value as `0b00111000`. Visual and normal
binary digits may be mixed.

An integer literal may carry an explicit type annotation:

```vcsc
42`uint8_t
0x123456`uint24_t
```

Unannotated literals use `int16_t` until a typed operand or destination supplies
a different context. Literal-only expressions are folded at compile time. When
a literal interacts with a typed value, parameter, assignment target, return
object, or cast, it adopts that type at the boundary.

For runtime integer expressions:

- equal types keep that type;
- a narrower operand widens to the wider width;
- widening sign-extends signed values and zero-extends unsigned values;
- narrowing truncates high bytes;
- mixed signed/unsigned operations are rejected when width adjustment still
  leaves different signedness, unless the source writes an explicit cast.

VCSC does not implement C's usual arithmetic conversions.

### Casts

Ordinary casts use C-like syntax:

```vcsc
(uint16_t)value
```

A backtick annotation is literal-only:

```vcsc
123`uint16_t
```

The shortcut casts `($signed)` and `($unsigned)` preserve width while changing
signedness. They apply only to already typed ordinary integers, not literals,
pointers, or packed-BCD values.

### Packed BCD

Packed-BCD values store two decimal digits per byte, least-significant pair at
the lowest address:

```vcsc
bcd8_t  a := 42;       // $42
bcd16_t b := 1234;     // $34, $12
bcd24_t c := 567890;   // $90, $78, $56
bcd32_t d := 12345678; // $78, $56, $34, $12
```

Ranges are 0..99, 0..9999, 0..999999, and 0..99999999. Literal spelling does
not change conversion: `42`, `0x2a`, `052`, and `0b101010` all become packed
BCD `$42` in a `bcd8_t` destination.

Supported BCD operations are assignment, same-representation widening or
truncation, `+`, `-`, `+=`, `-=`, prefix/postfix `++` and `--`, comparisons,
truth tests, logical operators, and `switch` comparison. Several constant
multiply/divide/remainder forms also lower inline:

- multiplication, division, and remainder by a positive constant expression
  exactly equal to `10^n`, including `1` as `10^0`;
- remainder by `2` or `5`, determined entirely from the lowest decimal digit;
- multiplication by a constant expressible as the sum or positive difference
  of two decimal powers, `10^a + 10^b` or `10^a - 10^b`, provided that the
  constant fits the BCD type. Examples include `2`, `9`, `11`, `20`, `99`, and
  `101`.

Multiplication accepts the constant on either side. Division and remainder
require it on the right. The compound forms `*=`, `/=`, and `%=` support the
same applicable constants. Other BCD multiplication, division, and remainder
remain rejected rather than silently selecting a general arithmetic helper.

Decimal-power operations are packed-digit moves, not general BCD arithmetic.
Even powers move whole bytes; odd powers use four accumulator shifts plus
masks to join adjacent nibbles. Multiplication discards digits shifted past the
destination width, division discards shifted-off low digits, and remainder
retains only the low `n` decimal digits. Thus, for example, `bcd16_t` value
`1234` produces `2340` for `* 10`, `123` for `/ 10`, and `34` for `% 100`.
Remainder by `2` is a low-bit mask; remainder by `5` masks the lowest digit and
conditionally subtracts five.

Cheap constant multiplication forms shifted copies and combines them with one
packed-BCD addition or subtraction. For example, `x * 9` is lowered as
`x * 10 - x`, while `x * 101` is `x * 100 + x`. These forms use one tightly
scoped `SED`/`CLD` pair around the final decimal add/subtract but never call a
multiply helper.

Chains of decimal-power operations are fused into one contiguous digit-window
copy. Expressions such as `(x / 100) * 100`, `(x / 100) % 1000`, and
`(x % 1000) * 100` therefore avoid intermediate BCD temporaries. The equivalent
truncation spelling `x - (x % 100)` is fused when `x` is an ordinary variable;
function calls, indirect values, and absolute hardware refs retain their full
source evaluation behavior.

Addition and subtraction wrap at the destination width. The compiler brackets
only their decimal `ADC`/`SBC` chains with `SED` and `CLD`, so generated code
leaves decimal mode clear.

Runtime conversion between binary and BCD variables is not implemented. BCD
multiplication, division, or remainder with any other operand, along with BCD
shifts, bitwise operations, unary minus, signedness shortcut casts, and BCD
bitfields, is rejected.

## Declarations and storage

### Global and local objects

Globals, named locals, parameters, return objects, and compiler temporaries are
all linker-resolved static storage.

An unqualified local still has automatic *initialization timing*: its initializer
runs whenever control reaches the declaration. The object itself is not created
on entry and destroyed on return. Without an initializer, its previous bytes
remain until overwritten.

```vcsc
uint16_t count_once(void) {
   uint16_t value := 1; // writes 1 on every call
   return value;
}
```

A function-scope `static` object is initialized once, either as static data or
by a startup initializer when its expression needs runtime code. It may select
any writable named memory region supported for persistent objects, including a
split-address region such as `cartram`. Such an object lives in persistent
`BSS.<region>` or `DATA.<region>` storage, never in the owning function's
activation overlay. An uninitialized object is cleared during startup, a
link-time initializer is copied during startup, and a runtime initializer runs
from the translation unit's startup initializer exactly once. Split-address
reads use the read alias and every initialization or later write uses the write
alias.

Local arrays reserve their complete size in the owning activation. After all
objects and archive members are selected, `vcsc-ld` overlays mutually exclusive
function activations by call-graph lifetime. Caller and callee bytes remain
distinct; sibling functions may occupy the same physical addresses.

### Access-qualified pointers

For a non-pointer object, `const` requires an initializer and prohibits later
writes. In `const uint8_t *p`, the pointed-to bytes are readable but cannot be
written through `p`; the pointer object itself remains mutable. C's
`uint8_t * const p` spelling is not supported.

`writeonly` is the write-side counterpart for a one-address pointer:

```vcsc
writeonly uint8_t *output;
```

The pointer value may be copied, compared, indexed, incremented, decremented,
and adjusted with the ordinary pointer operations. Dereferencing it is valid
only as a pure store destination. A load, compound assignment,
increment/decrement of the pointed-to object, or packed-bitfield update is an
error because each obtains or preserves a value by reading through the pointer.
`const` and `writeonly` cannot qualify the same pointed-to object.

An ordinary readable/writable pointer converts implicitly to either restricted
form. Neither restricted pointer converts implicitly back to an ordinary
pointer, and `const T *` and `writeonly T *` do not convert implicitly to one
another. These qualifiers change access capability and type compatibility, not
representation: all three pointer forms remain one 16-bit address. Pointer
access qualification is part of function and object ABI fingerprints, including
aggregate members and separately compiled declarations.

### Cartridge-output topology

C26 may describe physical output chunks independently of allocatable `mem`
regions. The output-wide declaration gives the fill byte and, for a
selector-controlled cartridge, the linker-generated corridors:

```vcsc
cartridge {
   $fill:0xff $signature:F8
   $trampoline_offset:0x0f00 $trampoline_size:0x00e0
   $vector_bridge_offset:0x0fe0 $vector_bridge_size:0x0012
   $vectors_offset:0x0ffa $vectors_size:0x0006
};
```

Each physical chunk has a named `bank` declaration:

```vcsc
bank bank0 {
   $image_size:0x1000 $file_index:1 $image_offset:0
   $link_start:0xf000 $cpu_start:0xf000 $map_size:0x1000
   $select_access:0x1ff9 $startup
};
```

`$signature:TEXT` is an optional 1-4 byte ASCII alphanumeric cartridge signature.
When present, the linker NUL-pads it to exactly four bytes and writes it at
the four bytes beginning eight bytes before the end of the last CPU-mapped bank
in file order. File-domain `$data_only` banks are excluded. Public VCS
bankswitching profiles use this as their mapper identifier. Profile-owned `mem`
regions must leave `$xFF8-$xFF9` unavailable to ordinary allocation; the final
two signature bytes intentionally overlap the otherwise-unused 6507 NMI vector.

Ordinary CPU-mapped banks require `$image_size`, `$file_index`,
`$image_offset`, `$link_start`, `$cpu_start`, and `$map_size`. `$select_access`
and bare `$startup` are optional. A bank without `$select_access` is directly
mapped; a bank with it is selector-controlled. `$select_access` is a physical
6507 bus address in `$0000-$1FFF`; it need not lie inside the cartridge ROM
window. Direct banks do not acquire generated switching code. One direct bank
may carry `$startup` as the linker's startup/home placement marker;
selector-controlled topologies require exactly one startup bank. Mixing direct
and selector-controlled CPU banks is rejected until a separate window model is
defined.

A physical image chunk that is not CPU-addressable instead uses bare
`$data_only`:

```vcsc
bank bank2 { $image_size:0x0800 $file_index:2 $data_only };
mem bank2 { $size:0x0800 $ro $data_bank:bank2 };
```

A `$data_only` bank has no link start, CPU start, mapped size, selector, or
startup state. Its matching `$data_bank:NAME` read-only `mem` has no `$start`;
objects placed there use bank-local file offsets and cannot be referenced as
6507 addresses. The linker rejects executable layouts and ordinary relocations
to such objects. This is used by DPC for its 2K display ROM and 255-byte Poly8
image tail.

`bank` and `mem` have separate namespaces, so both declarations may be named
`bank1`. Source placement modifiers always refer to `mem bank1`; a `bank bank1`
name is only a topology handle. No behavior is inferred from either spelling.
Identical declarations in separate translation units merge, while conflicts are
link errors naming both objects.

The compiler emits versioned absolute metadata exports; it emits no cartridge
instructions itself. Complete `mem` declarations are emitted independently of
whether a translation unit places an object in the region. A C26 profile may be
included when its named `mem` regions are needed as source placement modifiers,
or compiled as a configuration-only input when only link-time topology is
needed. The linker retains such metadata-only command-line objects even when
they export no ordinary program symbol. The reduced `vcs.cfg` now contributes
only operational policy such as call-stack reservation; C26 topology supplies
mapper mechanics, physical output order, allocator facts, and ordinary segment
routing. The linker map reports the resulting `C26 CARTRIDGE TOPOLOGY`.

### Memory regions

A source file may declare named storage regions:

```vcsc
mem fast { $start:0x0080 $size:0x0010 $rw };

fast uint16_t counter;
```

An ordinary CPU-addressable region must provide `$start`, either `$size` or
`$end`, and exactly one of `$rw` or `$ro`. A read-only region may additionally
use `$bank:NAME` to name its physical C26 topology-bank owner. That qualifier is
required when multiple physical banks intentionally share the same 16-bit link
range; it keeps physical output identity separate from the CPU address encoded
in instructions and pointers. A file-domain data-only region instead provides
`$size`, `$ro`, and `$data_bank:NAME`; it deliberately has no `$start` and may
contain only data destined for that topology bank. Split-address writable storage instead provides
`$read_start`, `$write_start`, size/end, and `$rw`. An optional `$read_hazard`
flag marks the write alias (or `$start` for a single-address region) as a range
where a CPU *read bus cycle* has side effects; the compiler preserves that fact
for final-link NMOS 6502 dummy/ghost-read checking. A completely empty `mem`
declaration remains available as a policy-only name and creates no allocator
region.

Complete declarations are authoritative linker metadata even when no object in
the declaring translation unit currently uses the region. Identical declarations
merge across objects; conflicting declarations are link errors naming both C26
locations. A repeated cfg `MEMORY` entry is compatibility input only: its
allocator address, size, access type, priority, and ordinary routes are replaced
by the C26 declaration, while operational cfg properties such as stack
reservation may remain during migration.

`mem` describes allocatable bytes only. It excludes RAM-port prefixes,
trampoline corridors, bridges, vectors, selector bytes, and physical fill holes.
A region is treated as zero page when its declared address range fits entirely
within `$0000..$00ff`; the region's name has no special meaning.

Unqualified DATA and BSS objects use the highest-priority writable region. When
that choice is unique and its complete range lies in page zero, the compiler
emits `.segmentaddrsize "DATA", zp` and `.segmentaddrsize "BSS", zp` into the
assembler source. That explicit contract lets relocatable assembly retain the
short addressing modes required by the Atari VCS without guessing from a
symbol's temporary section offset. A target whose default writable region begins
at `$0200`, or whose highest-priority choice is ambiguous, emits no contract and
keeps absolute-family addressing. Named writable regions carry their own address-size contract independently of
the unqualified DATA/BSS default. A named `$rw` region wholly inside page zero
emits `zp`; a named `$rw` region outside page zero emits `absolute`. Split-address
writable regions also emit `absolute`. This prevents an explicit cartridge-RAM
object such as OMNI `cartram` at `$1000-$1FFF` from inheriting RIOT-RAM zero-page
opcodes merely because ordinary variables default to `ram`.

Compiler-lowered ordinary 6502 memory operations deliberately do **not** carry
`.z`, `.a`, `.zx`, `.ax`, `.zy`, `.ay`, `.ix`, or `.iy` addressing-mode
suffixes. The compiler supplies semantic symbol references plus the address-size
contracts above; `vcsc-as` chooses and relaxes the shortest legal encoding from
those contracts and final placement. Split-address/non-zero-page regions retain
absolute-family encoding through their `.segmentaddrsize ..., absolute` metadata,
not through per-instruction suffixes. Addressing-mode suffixes remain available in
explicit `asm` for source code that intentionally requires a particular encoding
or cycle count. Compiler optimizations must not silently turn that source-level
assembly intent into a different mode.

A file-scope object may combine one named read-only `mem` region with the hard
`page` qualifier.  The compiler emits a private region-specific RODATA segment,
`.pagecontain`, and the ordinary index-range metadata, so constructs such as
`bank0 page const uint8_t glyph[8]` retain both explicit bank ownership and a
true 256-byte containment requirement.  This is used for beam-critical banked
renderer tables; it is not merely preferred alignment.

Named regions also describe non-inline function code and return-object
placement. The compiler classifies each modifier from the region's declared
properties rather than its name: a `$ro` region selects code placement, while
one `$rw` region selects the hidden return object's storage. Their order is not
significant:

```vcsc
mem bank1 { $start:0xD000 $size:0x1000 $ro };
mem fast_result { $start:0x0080 $size:0x0010 $rw };

bank1 fast_result uint8_t update_level(void) {
   // emitted in CODE.bank1
   // update_level$__return is in fast_result
   return 1;
}
```

A declaration may spell the same contract as `fast_result bank1`; declarations
and definitions must agree independently on the order-insensitive code-region
set and the writable result region. With no `$ro` modifier, code placement stays
automatic. With no `$rw` modifier, the return object keeps its default placement.
At most one writable result region is allowed, and a `void` function cannot
select one.

Multiple `$ro` modifiers explicitly replicate one non-inline function body into
each named ROM region. Calls from a bank containing a copy bind to that local
body before the linker considers a cross-bank trampoline. A call from another
bank may use the primary copy through the ordinary trampoline path. One optional
`$rw` modifier still names a single shared hidden return object rather than a
body copy:

```vcsc
bank0 bank1 cartram uint8_t lookup(uint8_t index) {
   return level_table[index];
}
```

Here `lookup` has a body in both `CODE.bank0` and `CODE.bank1`, but only one
`lookup$__return` in `cartram`. Region order is immaterial in declarations and
definitions. Inline functions cannot use any named region because their
expansions have no independently placeable linker layout. For numbered bank
regions, `main` may be unmarked or use `bank0`; explicitly placing it in `bank1`
or another nonzero numbered bank is rejected.


Selector-controlled profiles that support automatic cross-bank calls declare
`$bankcall`. The public
cross-bank direct-call contract is defined in
[`../BANKSWITCHING.md`](../BANKSWITCHING.md): same-bank calls remain ordinary
JSRs, while a cross-bank call uses a six-byte linked bundle consisting of the
JSR, a 16-bit target CPU address, and one mapper-defined destination descriptor
byte. The caller bank's source descriptor is baked into its trampoline instance
rather than inferred from the return PC.

The compiler/assembler/linker emit the descriptor field. F8/F6/F4(+SC), FA,
DPC, FA2, JANE, 0840, UA/UASW, 0FA0, and WD consume it end-to-end.

A constant object may use one named read-only region:

```vcsc
bank1 const uint8_t level_table[4] := { 1, 2, 3, 4 };
```

or an order-insensitive set of read-only regions for explicit immutable
replication:

```vcsc
bank0 bank1 const uint8_t level_table[4] := { 1, 2, 3, 4 };
```

The single-region form emits
`RODATA.bank1.__vcsc_object$level_table`. The multi-region form emits one
byte-identical private layout in every listed region. A reference from code in a
bank containing a copy resolves to that bank-local layout; a pinned reference
from a bank without a declared copy is an error. Copies are independently placed
and need not have the same low-twelve-bit offset. Mutable objects, split-address
regions, duplicate region names, and non-`$ro` regions are rejected for
multi-region object placement because no coherence protocol exists.

Every `$ro` definition must be `const` and its initializer must be representable
entirely at link time. It cannot require a startup write or silently become
DATA/BSS in a read-only cartridge region. Unmarked private CODE and RODATA layouts remain eligible for deterministic
automatic placement across every compatible read-only region in a multi-region
linker topology. Explicit named-region placement remains a hard pin. Automatic
placement does not extend to writable DATA/BSS/ZEROPAGE; those keep their
configured or explicitly named RAM regions.

For a Superchip bank, the source region describes only allocatable ROM. Exclude
the RAM-port prefix, for example `$start:0xD100 $size:0x0E00`; `$size:0x1000`
would run through `$E0FF` rather than stopping at the end of the 4K bank mirror.
The eventual banked cartridge writer still emits the complete physical bank.

### Split-address allocated memory

A named read/write region may expose separate CPU aliases for the same physical
storage:

```vcsc
mem cartram {
   $read_start:  0xF080
   $write_start: 0xF000
   $size:        0x80
   $rw
};

cartram uint8_t foo;
cartram uint8_t buffer[32];
```

The order matches explicit split refs: read address first, write address second.
Loads from these objects use the read alias. Stores, runtime initializer writes,
and startup BSS clearing use the write alias. The compiler preserves both
symbolic aliases in relocations rather than replacing the object with a fixed
integer address; the linker therefore allocates each object once and can report
both final addresses. Neither the region name nor the relative order, spacing, alignment, or size
of the two windows is significant; those facts come entirely from the
source-level `mem` declaration. Mapper RAM whose write port is destructive when
read should add `$read_hazard`; the stock Superchip, FA/RAM Plus, and CommaVid
profiles do so.

Split-address allocation supports persistent file-scope objects and automatic
local objects, including arrays and inline-expansion-private locals. Automatic
local initializers run whenever control reaches the declaration, exactly as for
ordinary locals, while their fixed backing bytes participate in the normal
call-graph activation overlay. Loads use the read alias; stores and initializer
writes use the write alias.

Taking one ordinary read/write address, implicit array-to-pointer decay, and
passing one to an ordinary `ref T` parameter remain rejected because one
ordinary address cannot encode different load and store locations. Directional
`ref const T` and `ref writeonly T` parameters are supported: the caller passes
only the selected read or write alias, respectively. Direct indexing remains
supported, including runtime array indexes. Compound assignment,
increment/decrement, and bitfield updates load through the read alias and store
through the write alias rather than using a single-address 6502
read-modify-write instruction.

Function-scope `static` objects use persistent split-region BSS/DATA storage.
Every reset clears their BSS or copies their DATA initializer through the write
alias; bank switches preserve the bytes between resets. Value parameters and hidden
function return objects may also select a split writable region; callers store
arguments and returned expressions through the write alias, while callees and
callers read through the read alias.

The unary directional projections expose either alias as an ordinary one-address
pointer without loading or storing the object:

```vcsc
const uint8_t *input := &<buffer[0];
writeonly uint8_t *output := &>buffer[0];
```

`&<` selects the exact read address and returns `const T *`; `&>` selects the
exact write address and returns `writeonly T *`. The lvalue location, including
any runtime subscript, is evaluated once. The operators work for named-region
objects, absolute external bindings, array elements, aggregate members, and
pointer-derived lvalues. They are adjacent multi-character unary operators;
`& <value` and `& >value` are not alternate spellings. A missing direction is a
compile-time error. Plain `&` remains valid only when the object has one
conventional address suitable for an ordinary read/write pointer. Split-address
array decay remains invalid, so source must project an element explicitly.
The same address selection is available without explicitly forming a pointer:
`ref const T` receives the read address, `ref writeonly T` receives the write
address, and ordinary `ref T` requires both addresses to exist and compare
equal. All three contracts pass one pointer-sized address; none creates a fat
pointer.

The linker classifies a region as output-owned only when its complete
synthetic allocation range lies inside exactly one C26 `bank` mapping. Split
aliases such as Superchip `$F080/$F000` lie outside F8SC's `$x100` ROM mappings,
and FA/RAM Plus `$F100/$F000` lies outside FA's `$x200` ROM mappings. Those
regions therefore remain shared and never trigger a selector transition.

### Pointers and arrays

Pointers are 16-bit addresses. `const` and `writeonly` restrict access through
that address without changing its width. Unary `&<lvalue` forms a readable
`const T *` from the lvalue's read address, while `&>lvalue` forms a writable
`writeonly T *` from its write address. For an ordinary object the numeric
addresses may be equal even though the pointer capabilities differ. Plain `&`
continues to form `T *` only when one conventional read/write address exists.

Arrays decay to pointers to their first element in pointer-valued expressions
and assignments when the array has one ordinary representable address. A split-
address array does not decay implicitly; use `&<array[0]` or `&>array[0]`.
Pointer addition and subtraction scale by the pointed-to element size.

Subtracting compatible pointers produces an `int16_t` element count. Pointers
to incompatible element types cannot be subtracted. Typed object pointers may
convert to `void *`; converting `void *` back to a typed pointer requires an
explicit cast.

## References

A `ref` parameter is pass-by-reference. Its access qualifier selects both the
address passed by the caller and the operations permitted in the callee:

```vcsc
uint8_t inspect(ref const uint8_t value) {
   return value;                 // read-only
}

void output(ref writeonly uint8_t value, uint8_t replacement) {
   value := replacement;         // pure writes only
}

void swap(ref int16_t a, ref int16_t b) {
   int16_t temporary := a;       // ordinary read/write refs
   a := b;
   b := temporary;
}
```

* `ref const T` requires a readable exact-type lvalue and passes its read
  address. The callee may read it but may not write it.
* `ref writeonly T` requires a writable exact-type lvalue and passes its write
  address. The callee may perform pure writes but may not read it or use an
  operation with a hidden read, such as compound assignment or
  increment/decrement.
* Ordinary `ref T` requires both readable and writable locations and requires
  those locations to be identical. It retains ordinary read/write behavior.

All three forms pass exactly one 16-bit address in one pointer-sized parameter
symbol. A split-address object may therefore bind to either matching directional
form, but not to ordinary `ref T`; no implicit fat pointer is created. A
read/write ref may narrow to either restricted form when forwarded. Restricted
refs cannot regain read/write access or convert between `const` and `writeonly`.
The access contract is part of function declaration compatibility and
linker-visible ABI metadata.

Every argument must be an lvalue of the exact declared type, including matching
array extents and aggregate shape. `ref` is reserved for function parameters;
it is not an object-storage modifier.

## Absolute external bindings

An address annotation binds a source name directly to pre-existing storage:

```vcsc
uint8_t port@0x10;
uint8_t status@STATUS_REG;
uint8_t write_only@[none/0x00];
uint8_t read_only@[0x30/none];
uint16_t split@[0x100/0x180];
```

`@address` is shorthand for `@[address/address]`. The annotation itself means
that the compiler allocates no storage and emits no initializer. Loads use the
read address; stores use the write address. Reading a write-only binding,
writing a read-only binding, or taking one ordinary address of a split-address
binding is rejected. Use `&<binding` to project a usable read address and
`&>binding` to project a usable write address; the result types are respectively
`const T *` and `writeonly T *`. An annotation with no usable side (`@none` or
`@[none/none]`) is invalid. Address terms are single integer literals or
identifiers, not arbitrary expressions.

Absolute external bindings cannot have initializers or allocation/linkage
modifiers such as `static`, `extern`, `page`, or a named `mem` region. Compatible
redeclarations must agree on the type and both addresses; ABI metadata preserves
those facts for separate-compilation checking.

They also may not overlap allocator-managed linker `MEMORY`. The linker checks
the complete object extent, not just its first byte: each usable read address is
compared with every managed read/ordinary window, and each usable write address
is compared with every managed write/ordinary window. Use a named `mem` object
for storage owned by the allocator; reserve `@[read/write]` for external hardware
that lies outside those managed windows.

## Functions and calls

### Declarations and linkage

Each function name has exactly one signature. Compatible declarations followed
by one definition are allowed; conflicting declarations and multiple
definitions are errors.

```vcsc
extern uint16_t twice(uint16_t value);
```

`extern` emits imports as needed. `static` gives a function internal linkage.
Calls require a visible declaration and a directly named target.

Arguments are evaluated left-to-right. Value arguments permit the normal
integer widening and pointer conversions described above. `ref` arguments are
strict exact-type lvalues. Ordinary calls use selective staging. A converted
argument is copied to its callee-owned parameter object immediately unless a
later argument may execute a function call. Only values which must survive such
a later call remain in caller-owned scratch, preventing sibling activation
overlay from clobbering them without reserving space for the complete argument
list.

### All parameters are static

Every non-void parameter of every ordinary VCSC function is a callee-owned
symbol. Before `JSR`, the caller evaluates and converts each argument and writes
it into the corresponding parameter symbol. No parameter bytes are pushed onto
a language stack.

```vcsc
uint16_t add(uint16_t left, uint16_t right) {
   return left + right;
}
```

`left` and `right` are fixed objects owned by `add`, not per-call variables.
The `static` modifier is accepted on a parameter but is redundant; all
parameters already use static storage. A memory-region modifier changes where
the parameter symbol is placed:

```vcsc
mem fast { $start:0x0080 $size:0x0010 $rw };
mem ports { $read_start:0x3003 $write_start:0x5007 $size:0x0008 $rw };

void capture(fast uint16_t ordinary, ports uint16_t split) {
   // ordinary lives in fast
   // split loads through ports' read alias and stores through its write alias
}
```

For a split-address value parameter, the caller uses the same selective rule.
A safe argument is copied immediately through the configured write alias; an
argument which must survive a later call is copied through that alias after all
argument expressions finish. The callee reads through the read alias and writes
through the write alias. ABI metadata includes the region and both aliases, so
separate declarations and definitions must agree. A `ref` parameter itself
still has one pointer-sized backing symbol rather than split parameter storage.
Its qualifier determines which address the caller supplies: `ref const` selects
the argument's read alias, `ref writeonly` selects its write alias, and ordinary
`ref` requires one shared read/write address. Combining `static` with a
memory-region modifier is rejected as redundant and ambiguous.

### Static activation and recursion

Every ordinary function body owns one logical activation consisting of its
parameters, named locals, return object, and private compiler scratch. The
compiler emits those pieces in function-owned activation segments. `vcsc-ld`
uses the complete acyclic call graph to assign one weighted activation path per
memory region: a callee starts after every live caller, while sibling functions
reuse the same bytes. Internal-linkage functions are qualified by object so
same-named static helpers in separate translation units remain distinct.

A function therefore cannot be active twice.

- Direct self-recursion is rejected.
- Mutual recursion is rejected.
- The compiler detects cycles wholly visible in one translation unit.
- `vcsc-ld` detects cycles completed across `.o26` files and `.l26` members.
- A call hidden in inline assembly or an opaque assembly object is outside that
  analysis; such code must not re-enter a live VCSC function.

This restriction applies even to parameterless functions and functions whose
bodies happen not to declare locals.

### VCS frame-phase lifetime metadata

For the fixed NTSC scheduler and reusable instantiated-component lifecycle, the
compiler also records when writable storage is live within a frame. The internal
phase mask uses VSYNC, VBLANK, visible draw, and overscan bits. Template suffixes
such as `_vblank`, `_draw`, and `_overscan` are recognized only on instantiation-owned
`require` lifecycle functions; an ordinary function merely ending in `_draw`
does not become a phase contract. The fixed `vcs_ntsc_*` scheduler helpers are
classified directly.

High-level reads/writes and recognized inline-assembly object references emit
reserved `__phaseuse$V1$...` records. A use from `main`, initialization, or any
other unclassified context emits an unscoped record, which conservatively
forbids phase overlay for that object. The linker treats multiple scoped accesses
as one contiguous live interval from the earliest to the latest observed phase,
not merely as independent phase bits.

Access timing alone does not authorize a file-scope value to lose its prior-frame
contents. An overlay candidate must also carry the internal
`__phaseworkspace$V1$symbol` ownership contract. Compiler scratch whose every
acquisition belongs to known phases receives this marker automatically and may
leave the ordinary activation segment; one unscoped acquisition keeps it there.
Renderer/application workspaces opt in only when their owner can guarantee that
contents outside the inferred interval are disposable.

This metadata is an internal storage optimization, not a source-language promise
that arbitrary similarly named functions have frame semantics. `vcsc-ld` reuses
physical bytes only for explicitly eligible, uninitialized writable objects with
provably disjoint conservative intervals.

### Returns and `$$`

A value-returning function owns an exact-sized hidden return object. It uses
zero page by default. One writable `mem` modifier on the function selects that
region for the return object. A separate read-only modifier may independently
select code placement:

```vcsc
mem ports { $read_start:0x3003 $write_start:0x5007 $size:0x0008 $rw };
mem orchard { $start:0xD000 $size:0x1000 $ro };

orchard ports uint16_t twice(uint16_t value) {
   $$ := value + value; // store through ports' write alias
   return;
}
```

Legal return types are:

- one- through four-byte ordinary binary integers;
- `bcd8_t` through `bcd32_t`;
- a 16-bit pointer.

`void` returns no object. Structs, unions, and arrays cannot be returned.

Inside a value-returning function, `$$` names its return object:

```vcsc
uint16_t twice(uint16_t value) {
   $$ := value + value;
   return;
}
```

`return expression;` writes the same object. An ordinary writable region uses
its declared address and may be zero-page or absolute. For split storage,
assignments and compound assignments to `$$` use the write alias and reads use
the read alias.

When every return expression in a non-inline value-returning function is the
same automatic local, the compiler may bind that local directly to `$$`. This
removes the local's separate allocation and the final copy. Coalescing requires
an exact type match and an exact storage contract: the same named region,
zero-page versus absolute placement, and the same complete split read/write
mapping. Distinct region names never match merely because their current
addresses happen to be equal. The optimization also requires no explicit `$$`
access and no escape of the local's address. Passing the local by value is safe;
binding it to a `ref` parameter, taking its address, or exposing it to inline
assembly forces the normal separate objects and copy. The public
`function$__return` symbol remains the allocation's ABI name.

An ordinary callee ends with `RTS`; it does not place a language return value in
A, X, or Y. `main` is the sole exception: it must be exactly `void main(void)`,
stock startup tail-jumps to it, and its return/fall-through epilogue is
`JMP ($FFFC)` so an erroneous return restarts through the RESET vector without
requiring a fictitious hardware-stack return address. After an ordinary call, a
caller that uses the value copies it from the return symbol's read address. Declarations and definitions must agree independently on
the result region and code-region set. ABI metadata records an ordinary result
region's identity/address class or a split region's identity and both window
starts. Any writable modifier on a `void` function is rejected because there is
no return object to place.

### Inline functions

`inline` requires source expansion at every call site:

```vcsc
inline uint8_t add_one(uint8_t value) {
   return value + 1`uint8_t;
}
```

The complete definition must be visible before a call. `extern inline` and an
inline `main` are rejected. Inline and non-inline declarations of the same name
are incompatible.

Each expansion receives private static symbols for its parameters, locals, and
return object, plus private source and assembler-local labels. It emits no
callable function symbol, `JSR`, `RTS`, or hardware-stack level. Calls made
inside the expanded body remain ordinary calls attributed to the enclosing
ordinary function. Direct and mutual inline-expansion cycles are rejected.

Expansion storage is intentionally not shared between call sites. This costs
RAM as well as ROM, so inline helpers should remain small.

### Optimizer-selected specialization and inlining

Ordinary `static` functions are different from source `inline`. Single-callsite
ref/readonly-parameter specialization is part of normal compiler lowering. With
the driver's explicit `-finline-profit` option, a reachable translation-unit-
internal ordinary function with exactly one effective direct call site may also
be expanded into that caller when safety and measured-profitability gates pass.
The source language and ABI do not promise that an optimizer-selected internal
function will remain separately callable when that option is used.

For a single fixed call site, a `ref`, `const ref`, or `writeonly ref` formal may
use the caller's known read/write address directly rather than allocating a RAM
slot containing that address. A by-value formal that is explicitly `const` or
proven readonly may likewise avoid a private copy when the caller value is a
constant or stable storage whose by-value semantics remain unchanged. Cases with
observable storage identity, aliasing/mutation hazards, unsupported assembly
escapes, exported ABI identity, lifecycle/contracts, or timing/placement geometry
retain the ordinary ABI.

Ordinary-function inlining is selected from real speculative final links rather
than an instruction-count estimate. The driver accepts a legal expansion when
final ROM shrinks, or when ROM is unchanged and the required hardware-stack
reserve shrinks, provided activation/object RAM does not regress. `.same`/`.cross`
branches, hard page containment, independently placed function regions, contract
identity, and supported assembly-visible symbol families conservatively block
movement when preservation is not proven. The measured inliner is opt-in because speculative final links can materially
increase build time; use `vcsc -finline-profit -v` to run it and report measured
decisions. Compile-only `-c` and assembly-only `-S` do not run final-link
profitability trials.

## Expressions and operators

VCSC provides the usual arithmetic, comparison, logical, bitwise, shift,
address, dereference, indexing, member, ternary, comma, assignment, compound
assignment, and prefix/postfix increment/decrement operators supported by the
parser. All are compiler-defined built-ins.

Truth is zero versus nonzero. `!`, `&&`, and `||` produce `uint8_t`; `&&` and
`||` short-circuit. Comparisons also produce `uint8_t`.

Constant negative shift counts and counts at least as wide as the left operand
are errors. Signed right shift is arithmetic; unsigned right shift is logical.

`sizeof(type)` and `sizeof(expression)` produce `int16_t` and do not evaluate an
expression operand for side effects.

A simple assignment expression has the value of its right-hand side after
conversion to the left-hand type. Chained assignments preserve and forward that
converted value; the compiler does not store the inner assignment and then read
its destination back. This matters for memory-mapped `ref` objects: write-only
and split read/write registers may be used in a chain without an illegal or
semantically different read from the register. A discarded chain of directly
addressable one-byte targets is lowered through A: the right-hand value is
loaded once and each `STA` forwards it to the next target, with no compiler
scratch and no Y setup. Wider or otherwise general simple chains use one shared
value slot for the whole chain rather than one nested slot per assignment.

A lone underscore is a discard token usable only in simple assignment:

```vcsc
WSYNC := _;                       // store whatever is already in A
WSYNC := RESP1 := RESP0 := _;    // store that same A value, inner to outer
_ := update();                    // evaluate update() and discard its result
_ := value + 1;                   // evaluate the expression only for its effects
```

Assignment *from* `_` requires one-byte, non-bitfield lvalues. It generates no
source-value load or conversion. A bare directly addressed byte object such as
`foo := _;` lowers to exactly one `STA`, independent of whether `foo` is placed in
zero page, ordinary RAM, a function activation, or at an absolute hardware address.
That store is transparent to A, X, Y, S, and P. A right-associated chain ending in
`_` emits its stores from the innermost target outward while preserving the
accumulator value. Such chains require directly addressable targets, so pointer
setup cannot destroy the raw accumulator source. Direct TIA-register chains require
no register readback, compiler scratch, hardware-stack traffic, or index-register
setup. Assignment *to* `_` evaluates the right-hand expression normally and
creates no destination object. Both forms are value-less and are intended as
expression statements, not operands in larger expressions. Identifiers
containing underscores remain ordinary identifiers; only the exact one-character
spelling `_` is reserved.

Runtime division or remainder by a known positive power of two greater than one
emits a performance warning. The compiler does not silently replace the
operation because shifts and masks differ for signed negative values.

## Initializers, strings, and xforms

Constant global and static initializers are emitted as bytes. Generated S26
`.byte` directives are automatically wrapped at 128 bytes per line, so large
C26 objects never need to be split merely to satisfy assembler source-line
limits. A non-constant global or static initializer creates a translation-unit
startup function that the runtime calls before `main`.

Braced initializers support scalars, arrays, structs, unions, nested aggregates,
and designated fields. Simple assignment also accepts a braced initializer:

```vcsc
Pair pair;
uint16_t values[3];

pair := { .second := 5, .first := 4 };
values := { 2, 3 }; // remaining elements are zero-filled
```

Compound assignment does not accept a braced initializer.

A string literal is a NUL-terminated read-only array of `int8_t`. It may
initialize an `int8_t` array or decay to `int8_t *`; writing through such a
pointer is invalid even though const-correctness is not yet fully enforced.

Named `xform` tables translate character and string literals at compile time:

```vcsc
xform upper { 'a' 0x41, 'b' 0x42 };
int8_t message[] := "abba"`upper;
```

## Control flow

Supported statements are blocks, declarations, expressions, `if`/`else`,
`while`, `do`/`while`, `for`, `switch`, `return`, `goto`, labels, `break`, and
`continue`. `break` and `continue` may name an enclosing labeled statement.

`case` labels accept constant expressions and inclusive ranges:

```vcsc
switch (value) {
   case 1:
      break;
   case 2 to 5:
      break;
   default:
      break;
}
```

A reversed range is diagnosed and compiled with its bounds exchanged.

## Inline assembly

Within a function, `asm` emits one assembler source line at that point:

```vcsc
asm lda #$01
asm sta COLUBK
asm @again:
```

The compiler leaves general assembler text under programmer control, with three
source-aware rewrites:

- exact `TEMPLATE` and leading `TEMPLATE_` identifiers inside an instantiated
  source instance receive the instance prefix and ordinary UTF-8 symbol mangling;
- absolute `ref` operands select the legal read or write address from the
  instruction's access kind;
- assembler-local `@labels` inside an inline-function expansion receive a
  private expansion prefix.

Loads from write-only refs, stores to read-only refs, and read-modify-write use
of a split ref are compile-time errors. Register, flag, decimal-mode, stack, and
cycle timing remain the programmer's responsibility.

## Generated-code and runtime model

The runtime workspace is eight zero-page bytes: one byte each for `arg0` and
`arg1`, plus two bytes each for `ptr0` through `ptr2`. Each cell is a separate
archive member, and stock startup selects the complete set. Compiler-generated
objects, inline assembly, and selected runtime helpers import only the cells
they reference. `vcsc-runtime.inc` defines short assembler aliases but imports
no storage.

One- through four-byte copies, fills, integer extension, negation, comparison,
and bitwise operations are emitted inline. Variable shifts call width-specific
8-, 16-, 24-, or 32-bit helpers. Multiplication and division/remainder likewise
select fixed-width helpers that use the already-live compiler expression
scratch for operands and results. Compile-time identities and annihilators are
removed before helper selection: multiplication by zero or one, division by
one, remainder by one, and division/remainder by a positive constant larger
than every possible left operand value lower to evaluation plus a copy or zero.
Operand side effects are preserved. Packed-BCD decimal-power operations,
remainder by two or five, cheap two-decimal-term constant multiplication, and
fused digit-window expressions also lower inline. All scalar helper families
stay at the eight-byte runtime baseline and own no private BSS. Objects wider
than four bytes may use the aggregate byte-copy/fill helpers.

Compiler expression scratch is part of the owning function activation. It is
lifetime-colored by active lease depth across the complete activation owner,
then overlaid with mutually exclusive function activations by the whole-program
linker call graph. Sequential statements, mutually exclusive branches, loop
iterations, and separate inline expansions reuse the same physical slot;
genuinely nested live leases use deeper slots. A lease remains active through
its final copy-out or side effect, and compiler scratch cannot be named or have
its address taken, so it cannot escape across a join or loop back-edge.

The diagnostic option `-X scratch` emits one machine-readable line per
scope/lifetime-group use. It reports the activation owner, depth slot, shared
symbol, maximum size used by that scope, lifetime-group name, allocation policy,
reason, and acquisition count. The linked map supplies the final address of the
shared symbol, making overlaid offsets auditable.

Ordinary directly addressable unsigned-byte state uses a compact lowering path.
Constant `+=`, `-=`, `&=`, `|=`, and `^=` updates, unit increment/decrement,
copy-plus/minus-constant assignment, logical-not assignment, truth and constant-
mask tests, and constant comparisons emit direct byte operations without generic
expression scratch. Packed-BCD, signed, indirect, and bitfield cases continue
through the general expression machinery. Absolute external bindings preserve
required read/write side effects even for apparent no-op updates. The compiler
does not assume A or flags survive across source statements; a comparison after
an update may reload the byte, but still avoids generic scratch.

The same direct-byte path also recognizes compact ROM-table and pointer idioms used
by ordinary application code. A file-scope pointer initialized from an array is emitted
as relocatable low/high data instead of BSS plus a run-time initializer. For statement
code, an adjacent `p := array; p += byte_offset` pair can be fused into one relocatable
pointer calculation when the byte offset and pointee contract prove the transformation.
One-byte array and pointer subscripts can stay in A/Y; safe promoted unsigned-byte
constant masks and shifts remain byte-sized; constant byte `<<=`/`>>=` use direct
ASL/LSR sequences; and direct byte-array stores avoid constructing a general run-time
lvalue. A non-coalesced automatic unsigned-byte scalar initializer also stores directly
from A when the initializer has one of these exact direct lowerings, avoiding expression
scratch entirely. Packed-BCD, return-coalesced, pointer-backed, and otherwise unproven
initializers retain the general typed/scratch path. A low-byte-zero array base is used only
when the declaration actually proves it: `align(256)` (or a stronger alignment), or
the special case of an exactly 256-byte `page` object whose containment necessarily
forces a page boundary. `page` by itself does **not** imply a zero low byte for smaller
objects. With a proven page base, a page-selection chain can install only the selected
high byte, a proven bounded low-byte offset can omit impossible carry propagation, and
identical selector suffixes are shared. When a later page-pointer setup is proven to use exactly twice the earlier
masked/shifted byte offsets and the intervening counted loop cannot mutate the pointer
or source values, the compiler reuses the existing low byte with `ASL` instead of
reconstructing the offset. The proof is byte-exact modulo 256 and does not allocate a
hidden temporary. These shortcuts are deliberately narrow: absolute hardware bindings, most signed or
packed-BCD forms, wider objects, calls/assembly across a reuse lifetime, and expressions
that need general aliasing semantics still use the normal lowering machinery. The few
additional direct application-code shapes recognized below are explicit exceptions.
Ref-array formals are deliberately excluded from direct absolute-array stores: their
declarator retains array shape, but their runtime representation is pointer-backed.

The direct application-code path also covers three narrowly proven forms used by the
public VCS examples. A runtime-indexed direct `uint8_t` array element may participate
in an unsigned constant comparison or `+=`/`-=` constant update without materializing
a general lvalue. A packed-BCD scalar may use `+=` or `-=` with a runtime-indexed
direct array element of the same packed-BCD width; the index is scaled by the element
width and the compiler emits one decimal-mode carry chain over the selected bytes.
Finally, assigning a relocatable address expression to a constant-index element of a
direct two-byte unsigned array emits relocatable low/high stores directly. These are
shape-specific code-size optimizations, not new aliasing rules: indirect/ref-backed,
mixed-width, signed, or otherwise unproven forms continue through the general
expression/lvalue machinery.

A small counted loop may keep its loop-local unsigned-byte index entirely in X when the
complete body is proven to contain only supported straight-line byte assignments and
expressions. The established ascending shape is
`for (uint8_t i := C; i < N; i += S)`. A constant nonzero countdown to zero is also
recognized in the natural forms `for (uint8_t i := C; i; i--)`, `i > 0`, or `i != 0`;
prefix `--i` is equivalent in the discarded `for` step clause. Proven countdowns emit
`LDX #C`, the body, then `DEX` / `BNE` and therefore need neither an entry comparison
nor a RAM object for `i`.

Calls, inline assembly, nested control flow, address-taking, signed/BCD arithmetic,
and other X-clobbering constructs reject the shortcut. A bare directly addressed
one-byte discard store `foo := _;` is always register/flag transparent: it is one
`STA`, regardless of the object's fixed address or placement. `WSYNC := _;` is just
the hardware-register instance of that general rule and is therefore safe inside an
X-backed countdown. Such a proven loop emits no activation object for its lexical
index; X is restored around the supported `i + constant` array-store form. When an
ascending `C < N` proves the loop nonempty, lowering uses a post-tested `CPX`/`BCC`
loop and avoids a redundant entry test/back jump. An ascending loop that can be empty
retains the pre-test. A zero-initialized downward loop is deliberately not classified
as a post-tested countdown, preserving zero-iteration semantics. Constant stores
through an X-backed array subscript are routed through the same direct array path
rather than referring to a nonexistent materialized loop-local object. This
optimization makes compact high-level table expansion and scanline waits practical
without turning lexical loop counters into permanent RAM.

There is no language software stack or frame pointer. The 6502 hardware stack
is used for `JSR`/`RTS` and the startup initializer cursor. A linker memory
region marked `callstack = callgraph` reserves two hardware-stack bytes per
active ordinary-function level, plus the documented startup allowance. Stack
use hidden in assembly must be declared separately by the integration's linker
configuration.

A, X, Y, and P are caller-clobbered across ordinary calls. No register carries
a language return value. Generated code expects decimal mode clear except
inside its own tightly scoped packed-BCD arithmetic.

The compiler applies a conservative peephole pass to generated assembly by
default. `-fno-peephole` disables every peephole rewrite for inspection and
regression work; `-fpeephole` explicitly re-enables the default. These switches
do not disable source-expression optimization.

Every recognized rewrite kind has a pattern-level optimizer regression. A
separate source-level regression compiles ordinary VCSC twice, first with
`-fno-peephole` to prove the compiler actually emits the candidate pattern and
then with the default enabled to prove the rewrite occurs. The currently emitted
source patterns cover duplicate `LDA`/`LDY` loads, branches or jumps to their
immediately following labels, and a generated conditional branch followed by a
`JMP` to the alternate arm. The latter is inverted to a single branch only inside
pure compiler-generated procedures; the presence of inline assembly disables that
size-changing control-flow rewrite for the whole procedure so handwritten timing
intent is not silently rescheduled.

Inline assembly is opaque. The pass neither rewrites instructions inside an
`asm` block nor carries register, flag, or scratch-value facts across it. The
inline-assembly delimiters are removed from final `.s26` output even when
`-fno-peephole` is selected.

Source identifiers may contain valid UTF-8. Non-ASCII scalars are escaped into
assembler-safe `?uXXXX?` or `?uXXXXXXXX?` forms and converted back in user-facing
diagnostics.

## Intentional language limits

- Alias and conditional-compilation facilities are deliberately small.
- Mixed signed/unsigned arithmetic requires an explicit choice by the source.
- Typed object pointers convert to `void *`; the reverse conversion is explicit.
- `switch` case expressions use the compiler's restricted constant-expression
  grammar rather than arbitrary runtime expressions.
- Assembly calls and stack operations are not inferred by source call-graph
  analysis.

## Minimal example

```vcsc
include "vcs.c26"

void bump(ref int16_t value) {
   value++;
}

uint16_t twice(uint16_t value) {
   return value + value;
}

void main(void) {
   int16_t counter := 1;
   uint16_t result := twice(21`uint16_t);

   bump(counter);
   if (counter == 2 && result == 42) {
      COLUBK := 0x84;
   }
}
```

## Unsupported/removed parent project features

- Floating-point types, literals, helpers, and libraries.
- Big-endian types and endian shortcut casts.
- Ordinary function overloading.
- Operator overloading and `$exactops`.
- Function pointers and indirect calls.
- Variadic functions and `stdarg` support.
- Recursive or reentrant functions and software call frames.
- Struct, union, and array returns.
- The parent runtime's software stack, frame pointer, `sbrk`, and interrupt-entry library.

### Page-aware data objects

Every file-scope data-object definition is emitted in a private compiler-owned
segment. This preserves the size and boundary of even a one- or two-byte scalar
so the linker can reuse same-page holes without changing source order or adding
padding. The ordinary placement is a soft preference only.

At file scope, `page` requests hard 256-byte page containment, for example
`page const uint8_t table[80] := { ... };`. The complete object must fit within
one hardware page, but its first byte need not be `$xx00`; a small `page` object
may share a page with other objects. The private segment is marked with
`.pagecontain`, and for objects of at most 256 bytes the compiler also emits
`.indexrange 0, size-1` as explicit full-declaration access metadata. The linker
must find a legal address or reject the link.

`align(N)` is the independent start-address alignment contract for file-scope
data-object definitions:

```vcsc
align(256) const uint8_t ascii_font[760] := { ... };
page align(256) const uint8_t frame_page[192] := { ... };
```

`N` must be a compile-time positive power of two from 1 through 32768. Other
values are rejected. `align(256)` means the first byte is `$xx00`; unlike
`page`, the object may span as many pages as its size requires. Combining the
two requests both a page-aligned start and whole-object page containment.
`align()` does not apply to functions, locals, extern data declarations, or
absolute external bindings. The compiler emits the contract through the
assembler/linker `.segmentalign` metadata rather than inserting literal padding
into application data.

A non-inline function definition is likewise emitted as its own `CODE` layout,
so the linker knows its exact boundary and size. Ordinary functions receive the
same soft containment preference. `page` on a function definition upgrades that
function to hard containment; declarations without a body reject `page` because
the final size is not yet known. Locals, extern data declarations, absolute external bindings,
and named `mem` data regions do not yet accept the hard `page` modifier. Ordinary
objects in named `mem` regions still receive private soft-placement segments.
