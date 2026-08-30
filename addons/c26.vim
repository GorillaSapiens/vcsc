" Vim syntax file
" Language: VCSC C26
" Maintainer: VCSC project
" License: GPL-3.0-or-later
"
" C26 is deliberately C-like, but it is not C.  This file follows the VCSC
" lexer/parser rather than inheriting syntax/c.vim assumptions wholesale.

if exists("b:current_syntax")
  finish
endif

let s:cpo_save = &cpo
set cpo&vim

syn case match

" ---------------------------------------------------------------------------
" Comments, strings, and characters
" ---------------------------------------------------------------------------

syn match   c26Escape contained "\\\%(x\x\{2}\|u\x\{4}\|.\)"
syn region  c26String start=+"+ skip=+\\\\\|\\"+ end=+"+ contains=c26Escape,@Spell
syn region  c26Character start=+'+ skip=+\\\\\|\\'+ end=+'+ contains=c26Escape

" ---------------------------------------------------------------------------
" C26 language words
" ---------------------------------------------------------------------------

syn keyword c26Statement break continue goto return
syn keyword c26Conditional if else switch case default
syn keyword c26Repeat while for do

syn keyword c26StorageClass const extern static inline typedef
syn keyword c26TypeDecl struct union enum type
syn keyword c26Topology mem bank cartridge
syn keyword c26Placement page align writeonly recommend require ref
syn keyword c26Transform xform

" Source/template machinery unique to C26.
syn keyword c26SourceDirective include instantiate alias parameter as

syn keyword c26Builtin sizeof
syn keyword c26Constant true false

" C26 switch ranges use the keyword 'to'.  '..' and '...' are not C26
" operators; flag them as errors below.
syn keyword c26RangeOperator to

" Frequently supplied by libraries/vcs/vcs.c26.  User-defined types are of
" course open-ended; these cover the canonical VCS scalar vocabulary.
syn keyword c26Type void int8_t uint8_t int16_t uint16_t int24_t uint24_t
syn keyword c26Type int32_t uint32_t bcd8_t bcd16_t bcd24_t bcd32_t
syn keyword c26Type int char bool

" ---------------------------------------------------------------------------
" Operators and C26-specific punctuation
" ---------------------------------------------------------------------------

" Put one-character operators first so the later multi-character rules win
" when both can begin at the same byte.
syn match c26Operator "[-+*/%&|^!~<>?`]"
syn match c26Operator "\%(&<\|&>\|==\|!=\|<=\|>=\|<<=\|>>=\|<<\|>>\|++\|--\|+=\|-=\|\*=\|/=\|%=\|&=\||=\|\^=\|&&\||||\|->\|\$\$\)"

" Assignment in C26 is :=, not C's bare =.  A lone '=' is deliberately
" conspicuous because it is a common C-to-C26 typo.
syn match c26InvalidAssignment "\%([:!<>=+*/%&|^-]\)\@<!=\%([=]\)\@!"
syn match c26Assignment ":="

" C26 has no '..' or '...' operator.  Keep this rule before c26Number so a
" valid visual binary literal such as 0b...X.... is consumed as one number and
" its dot glyphs are not mistaken for invalid punctuation.
syn match c26InvalidDots "\.\.\+"

" '$name' and '$name:value' are lexer-level flags used by type/memory/bank
" declarations, e.g. $size:2 or $integer:unsigned.
syn match c26Flag "\$[A-Za-z0-9_]\+\%(:[A-Za-z0-9_]\+\)\?"

" The discard identifier is a real token in C26.
syn match c26Discard "\<_\>"

" ---------------------------------------------------------------------------
" Numeric literals
" ---------------------------------------------------------------------------

" Underscores are allowed between digits.  Binary literals additionally use
" '.' and x/X as visual bit values, e.g. 0b...X.... or 0b1111_0000.
syn match c26Number "\%(^\|[^0-9A-Za-z_]\)\zs0[bB][01.xX]\%(_\?[01.xX]\)*\ze\%([^0-9A-Za-z_]\|$\)"
syn match c26Number "\<0[xX][0-9A-Fa-f]\%(_\?[0-9A-Fa-f]\)*\>"
syn match c26Number "\<0[1-7]\%(_\?[0-7]\)*\>"
syn match c26Number "\<[1-9][0-9]*\%(_[0-9]\+\)*\>"
syn match c26Number "\<0\>"

" ---------------------------------------------------------------------------
" Conditional compilation
" ---------------------------------------------------------------------------

syn region c26PreProc start="^\s*#" end="$" keepend contains=c26PreProcKeyword,c26PreProcDefined,c26Number,c26String,c26Character,c26Operator,c26Comment
syn match  c26PreProcKeyword "^\s*#\s*\zs\%(if\|ifdef\|ifndef\|elif\|else\|endif\)\>" contained
syn keyword c26PreProcDefined contained defined

" ---------------------------------------------------------------------------
" Inline S26 assembler
" ---------------------------------------------------------------------------
"
" The common vcscAsm* highlight groups are intentionally shared with s26.vim.
" This keeps standalone assembler and inline assembler visually identical.

" Start immediately after the 'asm' keyword and stop at C26's statement ';'.
" The body is non-transparent so ordinary C26 identifiers do not leak their
" colors into assembler operands.
syn region c26AsmStatement matchgroup=c26AsmKeyword start="\<asm\>\s\+" end=";" keepend contains=vcscAsmOpcode,vcscAsmRawOpcode,vcscAsmInvalidDots

" 6502/6507 official mnemonics plus the unofficial names enabled by VCSC's
" assembler/illegals.cfg.  Matching is case-insensitive because vcsc-as is.
syn match vcscAsmOpcode "\c\<\%(adc\|ahx\|alr\|anc\|and\|arr\|asl\|asr\|axs\|bcc\|bcs\|beq\|bit\|bmi\|bne\|bpl\|brk\|bvc\|bvs\|clc\|cld\|cli\|clv\|cmp\|cpx\|cpy\|dcp\|dec\|dex\|dey\|eor\|hlt\|inc\|inx\|iny\|isc\|jam\|jmp\|jsr\|kil\|las\|lax\|lda\|ldx\|ldy\|lsr\|nop\|ora\|pha\|php\|pla\|plp\|rla\|rol\|ror\|rra\|rti\|rts\|sax\|sbc\|sbx\|sec\|sed\|sei\|shx\|shy\|slo\|sre\|sta\|stx\|sty\|tas\|tax\|tay\|tsx\|txa\|txs\|tya\|xaa\)\>" contained nextgroup=vcscAsmModifier,vcscAsmArgument skipwhite
syn match vcscAsmRawOpcode "\c\<op[0-9a-f]\{2}\>" contained nextgroup=vcscAsmModifier,vcscAsmArgument skipwhite

" Addressing/branch annotations are colored separately from the mnemonic.
syn match vcscAsmModifier "\c\.\%(z\|zx\|zy\|a\|ax\|ay\|i\|ix\|iy\|flex\|same\|cross\)\>" contained nextgroup=vcscAsmArgument skipwhite

" The rest of an instruction is the operand/argument.  Numbers, registers,
" immediate markers, and operators get nested highlighting while identifiers
" retain the common argument color.
syn match vcscAsmArgument "[^.;][^;]*" contained contains=vcscAsmInvalidDots,vcscAsmNumber,vcscAsmRegister,vcscAsmImmediate,vcscAsmOperator,vcscAsmString,vcscAsmCharacter
syn match vcscAsmInvalidDots "\.\.\+" contained
syn match vcscAsmNumber "\c\$[0-9a-f]\+\|%[01]\+\|\<[0-9]\+\>" contained
syn match vcscAsmRegister "\c\<[axy]\>" contained
syn match vcscAsmImmediate "#" contained
syn match vcscAsmOperator "<<\|>>\|<=\|>=\|==\|!=\|&&\|||\|?=\|[-+*/%<>&|^!~(),]" contained
syn region vcscAsmString start=+"+ skip=+\\.+ end=+"+ contained
syn region vcscAsmCharacter start=+'+ skip=+\\.+ end=+'+ contained

" ---------------------------------------------------------------------------
" Comments
" ---------------------------------------------------------------------------
"
" Define comments after ordinary operators so // and /* win Vim's same-column
" syntax-priority tie against '/' and '*'.  Keep the whole comment -- markers
" and body alike -- in one group with no nested Todo or spell highlighting.
" That makes C26 comments use exactly the same Comment color as S26 comments.
syn region  c26Comment start="/\*" end="\*/" keepend
syn match   c26Comment "//.*$"

" ---------------------------------------------------------------------------
" Highlight links
" ---------------------------------------------------------------------------

hi def link c26Comment Comment
hi def link c26Escape SpecialChar
hi def link c26String String
hi def link c26Character Character

hi def link c26Statement Statement
hi def link c26Conditional Conditional
hi def link c26Repeat Repeat
hi def link c26StorageClass StorageClass
hi def link c26TypeDecl Structure
hi def link c26Topology Structure
hi def link c26Placement StorageClass
hi def link c26Transform Keyword
hi def link c26SourceDirective PreProc
hi def link c26Builtin Operator
hi def link c26Constant Constant
hi def link c26RangeOperator Operator
hi def link c26Type Type

hi def link c26Assignment Operator
hi def link c26InvalidAssignment Error
hi def link c26InvalidDots Error
hi def link c26Operator Operator
hi def link c26Flag Special
hi def link c26Discard Special
hi def link c26Number Number

hi def link c26PreProc PreProc
hi def link c26PreProcKeyword PreProc
hi def link c26PreProcDefined PreProc

hi def link c26AsmKeyword Keyword
hi def link vcscAsmOpcode Statement
hi def link vcscAsmRawOpcode Statement
hi def link vcscAsmModifier Type
hi def link vcscAsmArgument Identifier
hi def link vcscAsmInvalidDots Error
hi def link vcscAsmNumber Number
hi def link vcscAsmRegister Special
hi def link vcscAsmImmediate Operator
hi def link vcscAsmOperator Operator
hi def link vcscAsmString String
hi def link vcscAsmCharacter Character

let b:current_syntax = "c26"

let &cpo = s:cpo_save
unlet s:cpo_save
