//! @file compiler/compile_literal.h
//! @brief Declares literal lowering for the n65 compiler.
//! @ingroup compiler

#ifndef _INCLUDE_COMPILE_LITERAL_H_
#define _INCLUDE_COMPILE_LITERAL_H_

#include <stdbool.h>
#include "ast.h"

bool string_literal_is_char_constant(const char *text);
bool decode_char_constant_value(const char *text, long long *value_out);
const char *remember_string_literal(const char *text);
bool pointer_initializer_uses_backing_object(const ASTNode *type, const ASTNode *declarator, const ASTNode *expr);
const char *emit_pointer_initializer_backing_object(const ASTNode *type, const ASTNode *declarator, const ASTNode *expr);
void emit_store_label_address_to_fp(int dst_offset, int dst_size, const char *label);
bool emit_string_initializer_to_fp(const ASTNode *type, const ASTNode *declarator, int base_offset, int total_size, const char *text);
bool emit_string_initializer_bytes(unsigned char *buf, int buf_size, int base_offset, const ASTNode *type, const ASTNode *declarator, int total_size, const char *text);

#endif
