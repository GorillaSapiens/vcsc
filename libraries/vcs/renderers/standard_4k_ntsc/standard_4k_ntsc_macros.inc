; This file is covered under CC0-1.0. See libraries/LICENSE.txt.
;
; Maintained vcsc-as macros for the standard NTSC compatibility profile.
; Originally derived from the upstream BASIC macro set; the imported upstream
; snapshot and generation dependency have been retired. This file is now
; authoritative VCSC source and is edited/tested directly.
;
; SLEEP duration -- exact legal-instruction cycle delay, duration > 1.
; Odd delays begin with three-cycle BIT VSYNC.  This performs one read from TIA
; read address $00 and changes N/V/Z; every selected-profile use has dead flags.
MACRO SLEEP duration
   .if duration < 2
      .error "MACRO ERROR: 'SLEEP': Duration must be > 1"
   .endif
   .if duration & 1
      BIT VSYNC
      .repeat {duration - 3} / 2
         NOP
      .endrepeat
   .else
      .repeat duration / 2
         NOP
      .endrepeat
   .endif
ENDM

; VERTICAL_SYNC -- retained three-scanline vertical-sync sequence.
MACRO VERTICAL_SYNC
   LDA #$02
   STA WSYNC
   STA VSYNC
   STA WSYNC
   STA WSYNC
   LSR
   STA WSYNC
   STA VSYNC
ENDM

; CLEAN_START -- retained reset-time TIA/RAM/stack clearing sequence.
MACRO CLEAN_START
   SEI
   CLD
   LDX #0
   TXA
   TAY
@clear_stack:
   DEX
   TXS
   PHA
   BNE @clear_stack
ENDM

; SET_POINTER pointer,address -- load an absolute 16-bit address.
MACRO SET_POINTER pointer,address
   LDA #<{address}
   STA pointer
   LDA #>{address}
   STA pointer + 1
ENDM

; RETURN -- ordinary RTS in this deliberately unbanked profile.  The retained
; conditional remains explicit so accidentally defining bankswitch fails at
; assembly time rather than silently selecting an unsupported trampoline.
MACRO RETURN
   .ifdef bankswitch
      .error "standard_4k_ntsc RETURN does not support bankswitch"
   .else
      RTS
   .endif
ENDM
