//! @file assembler/opcode.h
//! @brief Declares 6502 opcode tables and lookup for the n65 assembler.
//! @ingroup assembler

#ifndef OPCODE_H
#define OPCODE_H

//! Final 6502 addressing form used to choose an opcode byte and instruction size.
typedef enum emit_mode {
   EM_IMPLIED = 0,
   EM_ACCUMULATOR,
   EM_IMMEDIATE,
   EM_ZP,
   EM_ZPX,
   EM_ZPY,
   EM_ABS,
   EM_ABSX,
   EM_ABSY,
   EM_IND,
   EM_INDX,
   EM_INDY,
   EM_REL,
   EM_REL_LONG
} emit_mode_t;

void opcode_registry_reset(void);
void opcode_registry_free(void);
int opcode_load_config_file(const char *path);
int opcode_mnemonic_known(const char *mnemonic);
int opcode_token_is_mnemonic(const char *token);
int opcode_has_mode(const char *mnemonic, emit_mode_t mode);
int opcode_lookup(const char *mnemonic, emit_mode_t mode, unsigned char *opcode_out);
int opcode_raw_expected_mode(unsigned char opcode, emit_mode_t *mode_out);
const char *emit_mode_name(emit_mode_t mode);
int emit_mode_size(emit_mode_t mode);
int opcode_is_conditional_branch(const char *mnemonic);
int opcode_invert_branch(const char *mnemonic, unsigned char *opcode_out);
int opcode_parse_raw_byte(const char *mnemonic, unsigned char *opcode_out);
int opcode_raw_is_conditional_branch(unsigned char opcode);
int opcode_raw_is_accumulator_shorthand(unsigned char opcode);

#endif
