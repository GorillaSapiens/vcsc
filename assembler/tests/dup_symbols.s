; dup_symbols.s

start:
   NOP

foo = $20
bar = foo + 1

; duplicate constant
foo = $30

; duplicate label
start:
   BRK

; label collides with constant
bar:
   RTS

; constant collides with label
baz:
   NOP
baz = $44
