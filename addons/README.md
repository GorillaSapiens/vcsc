```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# VCSC Vim syntax files

`c26.vim` and `s26.vim` provide Vim/Neovim syntax highlighting for VCSC source
and assembler files.

They are intentionally based on the VCSC lexers rather than treating `.c26` as
ordinary C.  In particular, the C26 highlighter understands:

- C26 assignment with `:=` rather than C's `=`; a lone `=` is highlighted as an error;
- source/template words such as `include`, `instantiate`, `as`, `alias`, and
  `parameter`;
- VCSC declaration/topology words including `mem`, `bank`, `cartridge`,
  `recommend`, `require`, `ref`, `page`, `align`, `writeonly`, and `xform`;
- switch ranges using `to`; `..` and `...` are highlighted as errors because
  neither is valid C26 syntax;
- hexadecimal, octal, decimal, and binary literals with optional `_`
  separators;
- visual binary literals such as `0b...X....`, where `.`, `x`, and `X` are
  accepted binary glyphs by the C26 lexer;
- `$flag` and `$flag:value` declaration flags;
- the C26 conditional-compilation directives `#if`, `#ifdef`, `#ifndef`,
  `#elif`, `#else`, and `#endif`;
- inline `asm ...;` with separate colors for the opcode, opcode/addressing
  modifier, and operand.

The S26 highlighter follows the VCSC assembler syntax, including labels,
directives, official and enabled unofficial opcodes, raw `opXX` opcodes, and
VCSC opcode modifiers.  It likewise highlights `..` and `...` as errors:

```text
.z .zx .zy .a .ax .ay .i .ix .iy .same .cross .flex
```

Inline assembler in `c26.vim` and standalone assembler in `s26.vim` use the
same `vcscAsm*` highlight groups, so the colors match by construction:

- opcode -> `Statement`
- opcode modifier -> `Type`
- symbolic operand/argument -> `Identifier`
- numeric operand -> `Number`
- A/X/Y register -> `Special`
- immediate marker and expression punctuation -> `Operator`

## Vim installation

Copy or symlink the syntax files into `~/.vim/syntax/`:

```sh
mkdir -p ~/.vim/syntax ~/.vim/ftdetect
ln -s /path/to/vcsc/addons/c26.vim ~/.vim/syntax/c26.vim
ln -s /path/to/vcsc/addons/s26.vim ~/.vim/syntax/s26.vim
```

Then create `~/.vim/ftdetect/vcsc.vim` containing:

```vim
augroup filetypedetect
  autocmd BufRead,BufNewFile *.c26 setfiletype c26
  autocmd BufRead,BufNewFile *.s26 setfiletype s26
augroup END
```

For Neovim, use `~/.config/nvim/syntax/` and
`~/.config/nvim/ftdetect/vcsc.vim` instead.

For a one-off buffer, either of these also works:

```vim
:set syntax=c26
:set syntax=s26
```

The files use standard Vim highlight groups rather than hard-coded colors, so
they follow the active colorscheme.
