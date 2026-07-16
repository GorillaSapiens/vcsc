# float library and code generator

`libraries/float` contains the builtin float runtime archive plus `n65_gen_float.pl`, which writes `.n` source for float-like exact operator overloads.


## Builtin runtime archive

`make` in this directory assembles `asm/*.s` and `asm/*.asm` into `float.a65`. That archive contains the non-`$exactops` builtin helpers for the standard `half`, `float`, and `double` layouts:

- little-endian pointer-ABI wrappers: `_f16_add` ... `_f64_div`
- big-endian byte-swapping wrappers: `_f16be_add` ... `_f64be_div`
- generated exact-operator assembly members used by those wrappers
- `_fcmp`, the shared builtin float comparison helper
- builtin weak comparison operator members for `half`, `float`, and `double`, split out of `nlib` because they call `_fcmp`

These sources used to be hidden behind `libraries/nlib/genasm.pl`; they are now checked in under `libraries/float/asm/` and archived directly. The driver links `nlib.a65` by default and adds `float.a65` when builtin float helpers, `_fcmp`, or the builtin half/float/double comparison operator symbols are referenced unless `-nostdlib` is used. Direct `n65ld` invocations that use builtin floats should include both archives.

Classic single-file mode writes one monolithic implementation to stdout:

```sh
n65_gen_float.pl typename little-or-big size-bytes exp-bits > mytype_ops.n
```

That output emits the operator definitions only. The including translation unit must already declare the matching type, and should mark it `$exactops` if you want the compiler to require the generated exact-name operators instead of falling back to generic helpers. It emits:

- binary `typename operator+(typename, typename)`
- unary `typename operator+(typename)`
- binary `typename operator-(typename, typename)`
- unary `typename operator-(typename)`
- `typename operator*(typename, typename)`
- `typename operator/(typename, typename)`
- `bool operator==(typename, typename)`
- `bool operator!=(typename, typename)`
- `bool operator<(typename, typename)`
- `bool operator>(typename, typename)`
- `bool operator<=(typename, typename)`
- `bool operator>=(typename, typename)`
- `bool operator{}(typename)`
- `typename operator++(ref typename)`
- `typename operator--(ref typename)`

Build mode writes archive-friendly generated sources and immediately compiles them. From an installed tree, the script finds sibling `n65c`, `n65asm`, and `n65ar` in `bin/`, and `nlib` includes under `include`; use `N65C`, `N65ASM`, `N65AR`, or `NLIB_INC` to override those paths:

```sh
n65_gen_float.pl --build outdir typename little-or-big size-bytes exp-bits
```

That produces:

- `outdir/<typename>_decls.n` ... type declaration with `$exactops` plus `extern operator...` prototypes
- `outdir/<typename>_operator_<name>.n` ... one self-contained source per operator member
- matching `.s` and `.o65` files for each operator source
- `outdir/<typename>.a65` ... archive containing all generated operator members

The generated operator surface is intentionally complete for same-type exactops use: binary `+ - * /`, unary `+ -`, `== != < > <= >=`, `operator{}` truthiness, and `++ --`. Several of those are emitted as thin wrappers around the smaller primitive set so the compiler sees the full exact-operator contract without paying full implementation cost for every member.

The per-operator build-mode units are self-contained and mark their scratch globals and helper routines `static`, so multiple generated members can coexist inside one archive without symbol collisions.

The generator keeps emitted code and member-local state tight: it uses direct typed assignments where the compiler handles widening/narrowing correctly, build-mode members only declare the scratch globals they actually use, and several operators are emitted as thin derived wrappers instead of separate heavy implementations. In practice that trims both generated source size and linked archive-member size, especially for compare-only members and single-op archives on 64K targets.

The generated custom-layout implementation is pure `.n` code. It uses a union overlay plus a bitfield struct to expose sign, exponent, and mantissa, then performs manual `SExMy` arithmetic/comparison in generated helpers. It does not call the builtin `float.a65` arithmetic helpers. The checked-in `asm/` sources provide only the compiler builtin non-`$exactops` path for the standard `half`, `float`, and `double` layouts.

The generated helpers and scratch globals are ordinary user-defined `.n` symbols with an `nlf_` prefix. They intentionally do not start with `_`, and the compiler preserves that at the assembly/object-symbol layer too; raw `nlib` helper names remain separate assembly symbols like `_pushN` and `_callptr0`.

Current limits:

- supports sizes up to 8 bytes
- assumes the target format is `SExMy` with the supplied exponent width
- supports both little-endian and big-endian storage
- handles zeros, subnormals, infinities, and NaNs for the declared layout
- build-mode declaration inference only auto-tags known built-in `$float:` styles (`ieee754` / `simple`); other layouts fall back to a size/endian-only type declaration in `<typename>_decls.n`

Example:

```n
type gf32 { $size:4 $endian:little $float:ieee754 $exactops };
include "generated_gf32_ops.n"

union bits {
   gf32 f;
   char b[4];
};

void main(void) {
   bits a;
   bits b;
   bits c;
   a.f := 1.0;
   b.f := 0.5;
   c.f := a.f + b.f;
}
```
