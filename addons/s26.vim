" Vim syntax file
" Language: VCSC S26 assembler
" Maintainer: VCSC project
" License: GPL-3.0-or-later
"
" The vcscAsm* groups intentionally match addons/c26.vim's inline-assembler
" colors exactly.

if exists("b:current_syntax")
  finish
endif

let s:cpo_save = &cpo
set cpo&vim

syn case ignore

" ---------------------------------------------------------------------------
" Comments, strings, characters, labels
" ---------------------------------------------------------------------------

syn keyword s26Todo contained TODO FIXME XXX NOTE BUG HACK
syn match   s26Comment ";.*$" contains=s26Todo,@Spell
syn region  s26String start=+"+ skip=+\\.+ end=+"+
syn region  s26Character start=+'+ skip=+\\.+ end=+'+

" Labels may use VCSC's @/? local-symbol spelling and may prefix a directive or
" instruction on the same line.
syn match s26Label "^\s*\zs[A-Za-z_@?][A-Za-z0-9_@?$]*\ze\s*:"

" ---------------------------------------------------------------------------
" Directives and constants
" ---------------------------------------------------------------------------

" Known directives get normal directive coloring.  The generic statement-start
" match also colors future/extension directives without confusing opcode
" suffixes such as .same or .z.
syn match s26Directive "\.\%(align\|ascii\|asciiz\|byte\|callstackextra\|def\|endif\|endproc\|export\|exportzp\|global\|if\|import\|importzp\|include\|org\|proc\|res\|segment\|segmentalign\|segmentdef\|segmentprivate\|segmentregion\|set\|text\|weak\|word\|zpexport\|zpimport\)\>"
syn match s26Directive "^\s*\%([A-Za-z_@?][A-Za-z0-9_@?$]*\s*:\s*\)\?\zs\.[A-Za-z_][A-Za-z0-9_]*\>"

syn match s26Assignment "?=\|="

" S26 has no '..' or '...' punctuation/operator form.
syn match s26InvalidDots "\.\.\+"

" ---------------------------------------------------------------------------
" Instructions
" ---------------------------------------------------------------------------

" These common vcscAsm* groups are the same groups used by c26.vim inside
" 'asm ...;' statements, so standalone and inline assembly share colors.
syn match vcscAsmOpcode "\c^\s*\%([A-Za-z_@?][A-Za-z0-9_@?$]*\s*:\s*\)\?\zs\%(adc\|ahx\|alr\|anc\|and\|arr\|asl\|asr\|axs\|bcc\|bcs\|beq\|bit\|bmi\|bne\|bpl\|brk\|bvc\|bvs\|clc\|cld\|cli\|clv\|cmp\|cpx\|cpy\|dcp\|dec\|dex\|dey\|eor\|hlt\|inc\|inx\|iny\|isc\|jam\|jmp\|jsr\|kil\|las\|lax\|lda\|ldx\|ldy\|lsr\|nop\|ora\|pha\|php\|pla\|plp\|rla\|rol\|ror\|rra\|rti\|rts\|sax\|sbc\|sbx\|sec\|sed\|sei\|shx\|shy\|slo\|sre\|sta\|stx\|sty\|tas\|tax\|tay\|tsx\|txa\|txs\|tya\|xaa\)\>" nextgroup=vcscAsmModifier,vcscAsmArgument skipwhite
syn match vcscAsmRawOpcode "\c^\s*\%([A-Za-z_@?][A-Za-z0-9_@?$]*\s*:\s*\)\?\zsop[0-9a-f]\{2}\>" nextgroup=vcscAsmModifier,vcscAsmArgument skipwhite

syn match vcscAsmModifier "\c\.\%(z\|zx\|zy\|a\|ax\|ay\|i\|ix\|iy\|flex\|same\|cross\)\>" contained nextgroup=vcscAsmArgument skipwhite
syn match vcscAsmArgument "[^.;][^;]*" contained contains=vcscAsmInvalidDots,vcscAsmNumber,vcscAsmRegister,vcscAsmImmediate,vcscAsmOperator,s26String,s26Character
syn match vcscAsmInvalidDots "\.\.\+" contained
syn match vcscAsmNumber "\c\$[0-9a-f]\+\|%[01]\+\|\<[0-9]\+\>" contained
syn match vcscAsmRegister "\c\<[axy]\>" contained
syn match vcscAsmImmediate "#" contained
syn match vcscAsmOperator "<<\|>>\|<=\|>=\|==\|!=\|&&\|||\|?=\|[-+*/%<>&|^!~(),]" contained

" Standalone expression/constant numbers outside instruction operands.
syn match s26Number "\c\$[0-9a-f]\+\|%[01]\+\|\<[0-9]\+\>"
syn match s26Register "\c\<[axy]\>"

" ---------------------------------------------------------------------------
" Highlight links -- keep vcscAsm* in lockstep with c26.vim
" ---------------------------------------------------------------------------

hi def link s26Todo Todo
hi def link s26Comment Comment
hi def link s26String String
hi def link s26Character Character
hi def link s26Label Label
hi def link s26Directive PreProc
hi def link s26Assignment Operator
hi def link s26InvalidDots Error
hi def link s26Number Number
hi def link s26Register Special

hi def link vcscAsmOpcode Statement
hi def link vcscAsmRawOpcode Statement
hi def link vcscAsmModifier Type
hi def link vcscAsmArgument Identifier
hi def link vcscAsmInvalidDots Error
hi def link vcscAsmNumber Number
hi def link vcscAsmRegister Special
hi def link vcscAsmImmediate Operator
hi def link vcscAsmOperator Operator

let b:current_syntax = "s26"

let &cpo = s:cpo_save
unlet s:cpo_save
