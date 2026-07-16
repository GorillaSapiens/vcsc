# N compiler and language notes

N is a mostly C-like systems language aimed at small targets, especially 8-bit machines. This document describes the language model and the current compiler/runtime behavior as implemented in this tree.

## Big differences from C

- Assignment uses `:=` instead of `=`.
- Braces are required on `if`, `else`, loops, and similar statements. There is no dangling-`else` ambiguity.
- Included files behave like `pragma once` automatically. Include-file identity is based on an MD5 of file contents, so duplicate content is only compiled once.
- There are no built-in integer or float type names. Types are declared explicitly.
- Struct and union names become types directly. There is no separate `typedef struct foo foo;` dance.
- Functions can return any value type supported by the compiler, including arrays.
- Static function parameters are supported.
- Some operators can be overloaded.
- Strings can be translated through named `xform` mappings.
- Inline assembly statements are supported as raw one-line passthroughs with `asm ...` inside functions.

## Aliases

The compiler supports newline-terminated lexical aliases:

```n
alias PI 3.14159
alias inc(x) (x + 1)
alias add(a,b) (a + b)
```

Object-like aliases replace a bare identifier with the stored replacement text. Function-like aliases declare a fixed parameter list and are expanded only when invoked as `name(...)` immediately after the alias name.

Current alias rules:

- alias names are unique within a translation unit; redefining an alias name is a hard error even if one form is object-like and the other is function-like
- function-like aliases are not overloaded with object-like aliases
- function-like alias arguments are split using balanced parentheses and quoted string/character handling
- alias parameters are local to one expansion and shadow outer/global aliases only for that expansion
- recursive alias expansion is rejected

Pitfalls:

- aliases are lexer-level textual substitution, not typed functions or templates
- a function-like alias name used without an immediate `(` is an error, so `foo(...)` works but `foo (...)` does not
- object-like alias replacement text is the rest of the definition line after stripping trailing `/* ... */` and `// ...` comments outside quoted text; if you put a semicolon there, that semicolon becomes part of the expansion text
- argument splitting tracks parentheses plus quoted strings/chars; careless use of commas in other syntactic constructs can surprise you
- repeated parameter use duplicates the argument text, so side-effect-heavy arguments are easy to misuse

Use aliases for small, local convenience rewrites... not for hiding control flow, declarations, or anything that would make the source lie about what it does.

## Conditional compilation

The lexer also supports simple beginning-of-line conditional directives inspired by the C preprocessor:

```n
alias FEATURE 2

#if defined(FEATURE) && (FEATURE >= 2)
alias MODE 1
#else
alias MODE 0
#endif

#ifdef FEATURE
#ifndef DISABLE_THING
...
#endif
#endif
```

Supported directives:

- `#if expr`
- `#ifdef NAME`
- `#ifndef NAME`
- `#elif expr`
- `#else`
- `#endif`

Current expression support inside `#if` / `#elif`:

- integer literals in the same forms the lexer already accepts
- `defined(NAME)` and `defined NAME`
- object-like alias expansion
- unary `!`, unary `+`, unary `-`
- `&&` and `||`
- integer comparisons `== != < > <= >=`
- parentheses for grouping

Current rules and pitfalls:

- directives only count at beginning-of-line, optionally preceded by horizontal whitespace
- undefined names in conditional expressions evaluate to `0`
- object-like aliases expand recursively inside conditional expressions; recursive alias use there is rejected
- function-like aliases do not expand in conditional expressions yet
- skipped branches are lexer-inert other than nested conditional directives, so syntax errors inside a skipped branch are ignored as long as the conditionals balance
- conditional blocks must balance before the end of the current source input

As with aliases, keep conditional compilation boring and local. It is useful for configuration gates and small compile-time switches... not for turning one source file into twelve different personalities.

## Type system

There are no implicit built-in scalar types other than the required pointer type `*`, the required boolean type `bool`, and the required empty type `void`.

Example:

```n
type void   { $size:0 };
type bool   { $size:1 $integer:unsigned };
type *      { $size:2 $integer:unsigned $endian:little };
type s2     { $size:2 $integer:signed   $endian:little };
type u4     { $size:4 $integer:unsigned $endian:little };
type f4     { $size:4 $float:ieee754 $endian:little }; // IEEE 754 binary32
```

### Required type declarations

The compiler requires these declarations to exist in the program or its includes:

- `*` ... the machine pointer type
- `bool` ... boolean result type used by comparisons and logical expressions
- `void` ... the canonical no-value type used for empty parameter lists and no-result functions

`int` and `float` are **not** required and are not hard-coded semantic fallback types.

Non-float scalar type declarations say whether they are integer-like with `$integer:signed` or `$integer:unsigned`. The required `bool` type must use `$integer:unsigned`, while `void` remains flagless.

Bitfield reads follow the declared integer style of the field type: signed integer types sign-extend, unsigned integer types zero-extend.

### Type flags

Recognized flags include:

- `$size:N`
- `$integer:signed`
- `$integer:unsigned`
- `$exactops` ... same-type operators on this type must resolve through visible exact-name `operator...` overloads; the compiler does not fall back to generic helpers for that type
- `$float:ieee754` ... IEEE 754 packing for `$size:2`, `$size:4`, and `$size:8`
- `$float:simple` ... generic `SExMy` packing where `x = round(3 * log2(size) + 2)` and `y` is the remaining fraction bits

For generated arithmetic/comparison overloads on custom float-like types, see `libraries/float/n65_gen_float.pl`. It emits `.n` code that cracks the value through union+bitfield overlays and generates an exact-operator surface for the float type: binary `+ - * /`, unary `+ -`, `== != < > <= >=`, `operator{}` truthiness, and `++ --`. Build mode emits a `<typename>_decls.n` file that declares the type with `$exactops` plus the matching `extern operator...` prototypes. Classic single-file mode emits only the operator definitions, so the including translation unit must provide the matching `type ... $exactops` declaration itself.

For non-`$exactops` builtin binary16/binary32/binary64 arithmetic, the compiler lowers `+ - * /` for `(size, expbits) = (2,5), (4,8), and (8,11)` to fixed helper entry points in `libraries/float/float.a65`: little-endian types use `_f16_add` ... `_f64_div`, while big-endian types use byte-swapping wrappers `_f16be_add` ... `_f64be_div`. Builtin comparisons lower through `_fcmp`; the archive also owns the builtin half/float/double comparison operator members that call `_fcmp`. Custom float layouts should use `$exactops` and the generated operators from `libraries/float/n65_gen_float.pl`.
- `$endian:little`
- `$endian:big`

## Declarators

The compiler supports:

- pointers
- arrays
- functions
- combinations such as arrays of pointers, pointer-to-function style declarators, and return-value arrays where the grammar allows them

Current `const` behavior on declarators follows the common C reading for leading `const` on pointer declarations:

- `const T* p` means a pointer to const `T`
- the pointer object itself is mutable, so it does not require an initializer just because the pointee type is const
- non-pointer declarations such as `const T x` are const objects and require an initializer
- syntax for a const pointer object in the C sense (`T * const p`) is not supported

Struct and union declarations immediately introduce their names as usable types.

### Function declarations

Ordinary function declarations work. Multiple compatible declarations are allowed, and a later definition may follow an earlier declaration. Incompatible redeclarations are rejected.

```n
int twice(int x);

int main(void) {
   return twice(21);
}

int twice(int x) {
   return x + x;
}
```

`extern` function declarations are also supported and cause the compiler to emit an import for the referenced symbol. Direct calls require a visible function signature in the current translation unit or via an `extern` declaration; the compiler rejects bare calls to unknown symbols instead of guessing at a call ABI.

### Ordinary function overloading

Ordinary non-operator functions can be overloaded by parameter signature. Overload resolution uses a best-viable-match search like the operator-overload matcher:

- exact matches win first
- implicit object-pointer conversion to `void*` or `const void*` is considered after exact matches
- safe integer promotions for plain value parameters are considered after exact matches
- `ref` parameters remain strict and require an lvalue of the exact declared type
- the reverse direction (`void*` to some typed pointer) requires an explicit cast
- ambiguous best matches are rejected

Examples:

```n
s2 pick(s2 x) {
   return x;
}

s4 pick(s4 x) {
   return x;
}

s2 a(s2 x) {
   return pick(x);
}

s4 b(s4 x) {
   return pick(x);
}
```

If no viable overload exists, the compiler rejects the call. If multiple viable overloads tie for best cost, the compiler reports the call as ambiguous.

### Function pointers and indirect calls

Pointer-to-function declarators are supported.

```n
int twice(int x) {
   return x + x;
}

int (*fp)(int) := twice;

int main(void) {
   return fp(21);
}
```

Function names decay to function pointers in ordinary expression and initializer contexts, and `&name` also works when a function pointer is wanted.

Indirect calls through function pointers are implemented. The compiler lowers them through a small runtime helper so ordinary call-frame setup and result handling work.

Functions that use `static` parameters are **not** allowed to have pointers formed to them. That prohibition applies both to bare decay and explicit `&name`, because the static-parameter calling convention needs caller knowledge that a plain function pointer does not carry.


### Variadic functions and `stdarg.n`

Parser and AST support exist for `...`, and the current backend implements variadic calls as a raw byte blob rather than C's promotion-heavy ABI.

There is no textual preprocessor yet, so the user-facing layer is a small builtin-style wrapper in `libraries/nlib/stdarg.n` rather than literal macros. Include it and use these compiler-recognized forms:

```n
include "stdarg.n"

int sum(int count, ...) {
   va_list ap;
   int x;
   int total := 0;

   va_start(ap);
   while (count) {
      va_arg(ap, x);
      total += x;
      count--;
   }
   va_end(ap);
   return total;
}
```

`stdarg.n` defines:

```n
struct va_list {
   void *args;
   void *bytes;
   void *offset;
};
```

Behavior of the current variadic ABI:

- variadic arguments are packed left-to-right in source order
- there is no alignment padding between variadic arguments
- there are no C-style default promotions for variadic arguments
- each argument is copied using its actual runtime storage size and byte order
- `va_arg(ap, out)` copies `sizeof(out)` bytes into the destination lvalue and advances `ap.offset`
- `va_end(ap)` zeroes the `va_list` state

That means a call like `f(1`char, 2`int, 3`long)` is packed as 1 byte, then 2 bytes, then 4 bytes... not as promoted `int, int, long`.

The implementation names `__va_args` and `__va_arg_bytes` are reserved for compiler-generated variadic metadata and may not be declared by user code.

## Expressions

### Truthiness

Truth-testing is driven by `operator{}`.

```n
bool operator{}(box b) {
   return b.valid;
}
```

The compiler uses this hook for:

- `if (x)`
- `while (x)`
- `for (...; x; ...)`
- `!x`
- `x && y`
- `x || y`
- conditional-expression tests

`!`, `&&`, and `||` are builtin operators and are **not** overloadable. They short-circuit and use `operator{}` under the hood.

### Literal typing, casts, and mixed integer expressions

The language model for integer expressions is deliberately simpler than C:

- a literal used only with other literals is folded on the host at compile time, and the result remains a literal
- a literal interacting with a typed nonliteral operand adopts that operand's type for the operation
- a literal consumed by a typed sink such as assignment, return, or argument passing adopts the sink type at that boundary
- two operands of the same type produce that same type
- for ordinary non-`$exactops` integers of different widths, the narrower operand widens to the wider width first
- widening sign-extends signed integers and zero-extends unsigned integers
- narrowing truncates bitwise; there is no saturation or range check by default
- if width adjustment leaves one operand signed and the other unsigned, the expression is rejected unless the user writes an explicit cast
- `$exactops` values do not participate in mixed-type promotions; an `$exactops` value may only interact with another type after an explicit cast

This is intentionally less C-like than the usual arithmetic conversions. The compiler should widen by width automatically, but it should not guess signedness automatically.

### Cast forms

The language uses two cast families:

- backtick casts such as ``123`u2`` are literal-only and always happen immediately on the host
- parenthesized casts such as `(u2)expr` are ordinary expression casts; when applied to a literal they may also fold on the host at compile time

There are also four shortcut casts:

- ``($signed)expr``
- ``($unsigned)expr``
- ``($big)expr``
- ``($little)expr``

`($signed)` and `($unsigned)` preserve width and endianness while changing signedness, but only for already-typed ordinary fixed-width integers. They are never legal on literals, `$exactops` types, floats, or pointers.

`($big)` and `($little)` preserve width and numeric family while changing endianness. They are legal on already-typed fixed-width integers and floats, including `$exactops` values, but they are never legal on literals, `bool`, or pointers.

### Shifts

The intended shift rules are:

- the result type is the type of the left operand after ordinary literal typing and any explicit casts have been applied
- if the right operand is a literal, it adopts the type needed by the surrounding operation just like any other literal
- a literal-only shift is folded on the host and remains a literal until consumed by a typed sink
- signed right shift uses arithmetic shift
- unsigned right shift uses logical shift
- negative constant shift counts are hard errors
- oversized constant shift counts are hard errors
- runtime negative shift counts are not a supported language feature; codegen should not reinterpret `x << -n` as `x >> n`


### Endianness in expressions and assignment

Mixed-endian assignments are supported.

The compiler performs endian-aware conversion when values move between slots or symbols. When source and destination integer or float endianness differ, bytes are reordered instead of blindly copied.

Ordinary mixed-endian integer operators are accepted in target-typed contexts where the destination type supplies the endian choice. This includes declaration initializers, assignments, braced assignment, return values, casts, and function-call arguments. For example, when `u2be x` receives `a * b`, the mixed-endian operands are compiled through a `u2be` work type before the result is stored.

For overloaded calls, a mixed-endian binary argument can make several parameter-endian choices viable. Exact non-mixed argument matches still win; equal-cost mixed-endian parameter choices are reported as ambiguous.

Compound assignments use the left-hand side as the destination. For `x += y`, `x *= y`, `x <<= y`, and the other compound assignment forms, a mixed-endian right-hand side is converted through the left-hand side/work type before the operation is performed, and the final value is stored back into the left-hand side type.

Mixed-endian integer comparisons compare logical values. The compiler converts to a common same-endian work type for `==`, `!=`, `<`, `>`, `<=`, and `>=` when the integer signedness is compatible.

Ordinary mixed-endian integer operators in free expressions do **not** promote through a hidden work type. A free expression such as `a * b;` is rejected unless the user makes the endianness choice explicit with a cast, either a full type cast such as `(u2le)expr` or an endian shortcut cast such as `($little)expr`.

That means these are handled sensibly:

- big-endian to little-endian assignment of equal-sized integers
- little-endian to big-endian assignment of equal-sized integers
- big-endian to little-endian assignment of equal-sized floats
- little-endian to big-endian assignment of equal-sized floats
- mixed-endian integer arithmetic in target-typed destinations
- mixed-endian integer arithmetic after an explicit endian cast
- mixed-endian integer comparisons
- mixed-endian compound assignment using the left-hand side as the endian sink
- mixed-endian pointer indexing after an explicit endian cast

## Inline assembly

Inside a function body, a line of the form:

```n
asm nop
asm lda #$01
asm loop_start:
```

emits the remainder of the line directly into the generated assembler output at that point.

Current limits:

- it is a single-line statement
- it is emitted verbatim after the `asm ` prefix is removed
- operand checking and clobber tracking are entirely the programmer's responsibility

## Operator overloading

Operator functions are ordinary functions spelled with `operator...` names.

Examples:

```n
vec2 operator+(vec2 lhs, vec2 rhs) {
   vec2 out;
   out.x := lhs.x + rhs.x;
   out.y := lhs.y + rhs.y;
   return out;
}

bool operator{}(vec2 v) {
   return v.x || v.y;
}
```

### Implemented overloads

The compiler supports exact-signature operator overload resolution for:

- unary `+`, `-`, `~`
- binary `+`, `-`, `*`, `/`, `%`, `&`, `|`, `^`, `<<`, `>>`
- binary comparisons `==`, `!=`, `<`, `>`, `<=`, `>=`
- `operator{}` truthiness hook
- `++` and `--`

### `++` and `--`

Pre and post increment/decrement use the **same** overload. The compiler owns the sequencing difference:

- pre form returns the updated value
- post form returns the previous value

A typical overload looks like this:

```n
counter operator++(ref counter x) {
   x.value := x.value + 1;
   return x;
}
```

### Compound assignment sugar

Compound assignments are treated as syntactic sugar over the corresponding binary operator plus ordinary assignment.

Examples:

- `a += b` behaves like `a := a + b`
- `a <<= b` behaves like `a := a << b`
- `a &= b` behaves like `a := a & b`

That means the compiler first tries the matching overloaded binary operator such as `operator+`, `operator<<`, or `operator&`. If no matching overload is available, it falls back to the builtin compound-assignment implementation.

The left-hand side is treated as an lvalue target for the final store, so the result of the binary operator is converted and assigned back using ordinary assignment rules.

### Overload matching limits

Operator overload matching prefers exact matches first and then considers safe integer promotions for plain value parameters. Smaller integers may widen, and mixed signed/unsigned operands may promote to a signed type that can represent the full range of the actual argument. `ref` parameters remain strict and require an lvalue of the exact declared type.

By default, same-type operators behave pragmatically:

- if a visible exact overload exists, the compiler uses it
- otherwise the compiler falls back to the builtin/generic lowering for that representation

`$exactops` changes that contract for the marked type. When both operands already have that exact declared type name, or when that type is used for unary operators, truthiness, or `++`/`--`, the compiler requires a visible exact-name overload and does **not** fall back to generic helpers. That means a type such as:

```n
type wideint { $size:4 $integer:signed $endian:little $exactops };
```

must provide the overloads it actually uses, for example `operator+`, `operator==`, `operator{}`, or `operator++`. If one is used without a visible declaration or definition, compilation fails immediately instead of emitting a symbolic call and hoping the linker finds something later.

### User identifier symbol escaping

Source identifiers may contain valid UTF-8 non-ASCII characters. The lexer validates UTF-8 inside the `{IDENT}` rule before alias lookup, typedef lookup, symbol table insertion, or any other processing. Malformed UTF-8 in an identifier is a compile-time error.

The compiler keeps assembler-safe ASCII identifiers unchanged, but each non-ASCII Unicode scalar in an identifier is escaped in place before it reaches assembly or overload ABI names:

```text
cafe     -> cafe
café     -> caf?u00E9?
λ_count  -> ?u03BB?_count
🦍       -> ?u0001F98D?
```

The escape uses only assembler-identifier-safe characters. ASCII punctuation that is not valid in N identifiers is not accepted as source identifier text; `?` is therefore reserved for compiler-generated Unicode escapes in emitted symbols.

Diagnostics reverse these escapes when reporting user-facing names, so an error involving `🥹` is printed as `🥹`, not `?u0001F979?`. Diagnostic source columns are one-based. For UTF-8 identifiers, columns are counted in Unicode scalar values rather than raw bytes, so the reported column for a non-ASCII identifier points at the source character the programmer sees.

### Operator ABI symbol names

Operator function symbols use readable `?@op_...` operator codes. The rest of the overload signature uses the same assembler-safe identifier spelling described above, so `operator>>(int, int)` mangles as `?@op_rsh@int_p0_a0@int_p0_a0`, while `operator+(λ_type, λ_type)` mangles as `?@op_add@?u03BB?_type_p0_a0@?u03BB?_type_p0_a0`.

| Source operator | ABI code | Meaning |
| --- | --- | --- |
| `+` binary | `add` | add |
| `+` unary | `pos` | unary plus |
| `-` binary | `sub` | subtract |
| `-` unary | `neg` | negate |
| `*` | `mul` | multiply |
| `/` | `div` | divide |
| `%` | `mod` | modulo/remainder |
| `&` | `and` | bitwise and |
| `|` | `or` | bitwise or |
| `^` | `xor` | bitwise xor |
| `~` | `inv` | bitwise invert |
| `==` | `eq` | equal |
| `!=` | `ne` | not equal |
| `<` | `lt` | less than |
| `<=` | `le` | less or equal |
| `>` | `gt` | greater than |
| `>=` | `ge` | greater or equal |
| `<<` | `lsh` | left shift |
| `>>` | `rsh` | right shift |
| `++` | `inc` | increment |
| `--` | `dec` | decrement |
| `{}` | `tst` | truthiness test |

This is not a full C++-style overload system. There is no arbitrary narrowing conversion search and no user-defined conversion machinery. Ordinary function overloading uses the same general best-viable-match style as operators for exact matches plus safe integer promotions.

## `ref` parameters

`ref` parameters are real pass-by-reference parameters.

- callers pass an address, not a copied value
- reads and writes in the callee dereference the referenced object
- mangling and overload matching distinguish `ref` parameters

Example:

```n
void swap(ref s2 a, ref s2 b) {
   s2 t;
   t := a;
   a := b;
   b := t;
}
```

### `static ref` parameters

`static ref` parameters work. Their backing symbol storage is pointer-sized, not referent-sized.

### Absolute `ref` declarations

The compiler supports `ref` declarations bound directly to absolute addresses. This is intended for memory-mapped hardware registers and similar machine-defined storage that already exists outside normal compiler allocation.

Supported forms:

```n
ref u8 port@0x10;
ref u8 status@STATUS_REG;
ref u8 vsync@[none/0x00];
ref u8 cxm0p@[0x00/none];
ref u16 banked@[0x100/0x180];
```

Meaning:

- `ref T x@addr` is shorthand for `ref T x@[addr/addr]`
- `@[read/write]` gives separate address expressions for loads and stores
- either side may be `none` to model read-only or write-only hardware
- each side intentionally accepts only a single integer literal or identifier, not an arbitrary expression

Intentional behavior and limits:

- reading uses the read address
- writing uses the write address
- storing to a `@[read/none]` declaration is rejected as write to a read-only absolute ref
- loading from a `@[none/write]` declaration is rejected as read from a write-only absolute ref
- taking the address of a split-address absolute ref such as `@[0x100/0x180]` is rejected by design, because it does not have one canonical address
- if both sides name the same address, `&name` behaves normally
- identifiers used in the address slots are passed through to the assembler/linker; the compiler does not require them to be declared as N symbols

Absolute address binding is only meaningful on `ref` declarations. Using `@...` on a non-`ref` declaration is accepted but ignored, and the compiler warns about it.

## Function parameters

### Ordinary parameters

Ordinary parameters are passed in the N argument stack frame.

### Symbol-backed parameters

Function parameters declared `static`, or parameters that use a `mem` modifier, are not pushed as ordinary call-frame arguments.

Instead:

- the callee owns a symbol-backed storage slot for that parameter
- the caller evaluates the argument and writes it directly into that storage before `jsr`

This includes zero-page-backed parameters and non-zero-page named memory regions such as `banana`.

A parameter may not combine `static` with an explicit `mem` modifier. Use `static int x` for default BSS-backed parameter storage, or use the memory-region modifier by itself, such as `zeropage int x`, `banana int x`, or `register int x` if a `mem register` region has been declared.

Because that storage is owned by the callee rather than the call frame, symbol-backed parameters should be treated as re-entrancy-hostile unless the programmer arranges external protection. Recursive or interrupt-driven re-entry can overwrite the shared parameter slots.

The compiler performs a direct-call graph check inside each translation unit and rejects any call-cycle strongly connected component that contains a function with symbol-backed parameters. That catches obvious self-recursion and mutual recursion cases before code generation completes.

The linker also performs the same check across the selected object files, so call cycles that only become visible after separate compilation are rejected before image generation.

Because symbol-backed parameters need named callee-owned storage, functions with symbol-backed parameters cannot be converted to plain function pointers.

## Storage classes and memory regions

### Globals, locals, static locals

The compiler supports:

- globals
- stack locals
- function-scope `static`
- mem-backed symbol storage for locals and parameters

### Memory regions

Memory region handling is driven by `mem` declarations, not by hard-coded names.

A declaration is treated as zero-page only if its referenced `mem` declaration fits entirely inside `$0000..$00FF` according to `$start` plus `$size` or `$end`.

So a region named `banana` can be zero-page if its declared address range fits there, and a region literally named `zeropage` is **not** magically zero-page if its range does not fit.

When a `mem` region is actually used for symbol storage, the compiler emits object metadata describing the region name, `$start`, size, and `$rw`/`$ro` type. `n65ld` validates that metadata against the linker config `MEMORY` entry before laying out the image. This turns stale cfg/source mismatches into link-time errors instead of silent placement surprises.

For validation to work, any used `mem` declaration must provide `$start`, either `$size` or `$end`, and exactly one of `$rw` or `$ro`.

## Initializers

### Static and global initializers

The compiler supports real constant-expression evaluation for static/global initializers, including:

- integers
- floats
- booleans
- comparisons and logical expressions
- ternary expressions
- nested aggregate initializers
- simple relocatable address constants such as `&symbol + 1`

When a non-constant global initializer cannot be emitted as static bytes, the compiler places the object in writable storage and emits a translation-unit `__init_*` function so startup code can perform the runtime initialization before `main`.

### Braced assignment

Simple assignment also accepts braced initializers. The compiler lowers these through the same initializer machinery used for declarations, so scalar, array, struct, union, designated aggregate, indirect, static/global, absolute-ref, and bitfield assignment targets use the target type as the initializer sink.

Examples:

```n
int x;
int a[3];
Pair p;

x := { 1 };
a := { 2, 3 };              // remaining bytes/elements are zero-filled
p := { .b := 5, .a := 4 };
```

Braced initializers are valid only for simple assignment. Compound assignment operates on ordinary expressions, so forms such as `x += { 1 }` are rejected.

### String initializers

Strings can initialize pointer values and byte arrays where appropriate. String bytes may be translated through an `xform`.

## Arrays

### Local arrays

Automatic local arrays reserve their full declared size.


### Return object: `$$` and A:X

Inside a function that returns a value, `$$` names the current function's
return object. It behaves like a real lvalue, so code may assign to it directly,
read it back, use compound assignment on it, and select aggregate members from
it. The spelling `return expr;` writes the converted expression into the same
object for you.

For a one-byte scalar result, the current VCS ABI returns the value in A. For a
two-byte little-endian scalar or pointer result, A holds the low byte and X
holds the high byte. In these functions `$$` is currently implemented as a
hidden callee-local scratch object and the common epilogue loads it into A:X
before RTS.

Example:

```n
uint16_t twice(uint16_t value) {
   $$ := value + value;
   return;
}
```

A conventional return is equivalent:

```n
uint16_t twice(uint16_t value) {
   return value + value;
}
```

The caller does not allocate a callee return slot for these one- and two-byte
A:X results. The current stack-based expression engine may still allocate its
own caller-local scratch area after the call; that is temporary implementation
machinery, not part of the function ABI.

Larger, aggregate, array, and big-endian returns temporarily retain the old
caller-owned return-slot ABI while those unsupported features are being removed
or redesigned. The `$$` name is reserved; it cannot be declared as a global,
local, function, or parameter name, and it is invalid in `void` functions or
outside a function body.

### Array returns

Array returns still use the temporary legacy caller-owned return-slot path.
They are not part of the intended minimal Atari 2600 language.

## Control flow

The compiler supports:

- `if` / `else`
- `while`
- `do` / `while`
- `for`
- `switch`
- labeled `break` and `continue`
- `goto`

### `switch` / `case`

`switch` compares the switch expression against each `case` label in source order.

`case` labels accept either a single numeric primary expression or an inclusive range:

```n
switch (x) {
   case 1:
      break;
   case 2 to 5:
      break;
   default:
      break;
}
```

Range bounds are inclusive on both ends. If the programmer writes a reversed range such as `case 9 to 3:`, the compiler emits a warning and compiles it as `case 3 to 9:`.

`default` remains optional and may appear anywhere inside the switch body.

## Strings and xforms

A string literal may optionally specify an `xform` name after a backtick.

```n
char msg1[] = "hello"`cp437;
char msg2[] = "hello";
```

## ABI and runtime notes

### Hardware stack vs N stack

The 6502 hardware stack is used for `jsr`, `rts`, temporary saves, and similar low-level operations.

The language-level argument/local storage model uses `_nl_sp` and `_nl_fp`.

### `_nl_sp` and `_nl_fp`

Startup initializes both `_nl_sp` and `_nl_fp` from `__stack_start`, not from a hard-coded constant. The N stack grows upward from there.

The runtime also seeds `_nl_sbrk` from `__stack_top`, so simple `sbrk` allocations can grow downward through the same free RAM arena.

### Frame pointer preservation

Compiled calls save and restore the caller's frame pointer around calls so nested calls do not smash the caller's frame-relative addressing.

### Peephole optimization

The compiler runs a conservative peephole pass over compiler-generated assembly after code generation. It removes duplicate `lda`, `ldx`, and `ldy` loads when the register value and the load's N/Z flag effects are already proven equivalent or the load's N/Z flag effects are proven dead, removes redundant stores to compiler-owned scratch bytes when the same value is already known to be there, removes redundant `tax`, `tay`, `txa`, and `tya` transfers when the destination register and observable N/Z flag effects are already equivalent, removes redundant repeated simple status-flag setters (`clc`, `sec`, `cld`, `sed`, `cli`, `sei`, and `clv`) when the same flag state is already proven, folds adjacent `lda #byte` plus immediate `and`, `eor`, or `ora` into a single equivalent `lda #byte`, removes a dead adjacent `lda`/`ldx`/`ldy` when it is immediately overwritten by another load into the same register before the earlier value or N/Z flags can be observed, removes conditional branches that are provably never taken from known N/Z, C, or V flag facts, removes `jmp` and all 6502 conditional branches (`bcc`, `bcs`, `beq`, `bmi`, `bne`, `bpl`, `bvc`, `bvs`) that target the immediately following label or an adjacent label in the same following label run, and keeps byte-saved statistics for `-X peephole`.

The pass tracks compiler-owned zero-page scratch operands such as `arg0`, `fp`, `sp`, and `ptr0` conservatively. Stores to a tracked scratch byte update or invalidate the corresponding known memory value, so a later load or duplicate scratch-store is removed only when the store proves the same value is present. If the source register's exact value is unknown, a store to tracked scratch still proves that the source register and scratch byte contain the same byte; a following reload of that scratch byte can therefore be removed only when the reload's N/Z flag effects are proven dead. Dead adjacent load removal is limited to side-effect-free compiler-known loads, namely immediates and compiler-owned zero-page scratch bytes; untracked memory reads are preserved. `brk` is treated as observing N/Z through the status byte it pushes. Conditional branches are treated as N/Z liveness barriers unless the branch itself is removed as a branch to the next label or as provably never taken, because a C/V-only branch can skip a later N/Z overwrite. The never-taken branch cleanup is intentionally one-sided: it removes false `beq`/`bne`/`bmi`/`bpl` branches when N/Z is known from a plain immediate byte, false `bcc`/`bcs` branches after known `sec`/`clc`, and false `bvs` branches after known `clv`; it does not replace always-taken conditional branches with `jmp`, because that is usually larger on 6502. Stores through unknown addresses and calls reset the tracked memory facts rather than guessing. Peephole byte accounting recognizes one-byte implied/register instructions, accumulator shifts/rotates, relative branches, `jmp`/`jsr`, immediate operands, compiler zero-page operands, compiler zero-page indexed operands such as `arg0,x`, and indirect zero-page forms. The immediate ALU fold is deliberately limited to plain byte literals so expression-valued assembler operands are not guessed at by the compiler.

Inline `asm` statements are bracketed internally and treated as raw programmer assembly, even when the assembler text begins with whitespace. The peephole pass removes those internal markers from final assembly and resets its facts around the programmer-owned line instead of rewriting it.

## Intentional limitations and non-goals

The following limits are deliberate in the language and compiler design, not unknown missing work:

- Aliases are lexer-level textual substitution. They are not typed macros, templates, or inline functions; function-like aliases require `name(...)` with no whitespace before `(`, and repeated parameters duplicate the argument text.
- Conditional compilation is intentionally small. `#if` and `#elif` accept only the expression subset listed above, and function-like aliases are not expanded there.
- There is no separate textual preprocessor phase. Facilities such as `stdarg` are handled by compiler-recognized wrappers rather than by C-style macro expansion.
- `void*` conversion is one-way by default: typed object pointers may convert to `void*` or `const void*`, but converting `void*` back to a typed pointer requires an explicit cast.
- Ordinary mixed signed/unsigned integer operators require an explicit cast when width adjustment leaves the signedness ambiguous. The compiler widens by width, but it does not guess signedness.
- `$exactops` types opt out of generic mixed-type promotion. They require explicit casts and visible exact operator overloads for the operations they use.
- `switch case` labels use the compiler's restricted constant-case grammar. Numeric literals, character literals, enum constants, floats, unary operators, and parenthesized forms are supported, but arbitrary identifier expressions such as `case y + 2:` are not.
- Runtime float arithmetic for ordinary non-`$exactops` floats is provided only for the builtin binary16, binary32, and binary64 layouts. Custom float layouts should use `$exactops` plus generated operators.

## Incomplete or limited features

A few sharp edges remain:

- operator overload resolution only considers exact matches plus safe integer promotions for plain value parameters
- ordinary function overloading supports exact matches plus safe integer promotions for plain value parameters, but there is no user-defined conversion search or other C++-style ranking machinery
- mixed-endian ordinary integer operators in free expressions require an explicit endian cast; target-typed contexts use the destination type as the endian sink
- symbol-backed-parameter cycle checking spans the selected object files at link time, but truly dynamic call targets cannot be proven safe
- shift-count diagnostics are lax

## Minimal example

```n
type void { $size:0 };
type bool { $size:1 $integer:unsigned };
type *    { $size:2 $integer:unsigned $endian:little };
type s2   { $size:2 $integer:signed   $endian:little };

bool operator{}(s2 v) {
   return v != 0;
}

void bump(ref s2 x) {
   x++;
}

s2 main(void) {
   s2 x;
   x := 1;
   bump(x);
   if (x) {
      x += 2;
   }
   return x;
}
```
