//! @file compiler/compile_lvalue.h
//! @brief Declares lvalue resolution and storage access for the n65 compiler.
//! @ingroup compiler

#ifndef _INCLUDE_COMPILE_LVALUE_H_
#define _INCLUDE_COMPILE_LVALUE_H_

#include <stdbool.h>
#include "ast.h"
#include "compile_internal.h"

typedef enum LValueAccessMode {
   LVALUE_ACCESS_READ = 0,
   LVALUE_ACCESS_WRITE,
   LVALUE_ACCESS_ADDRESS
} LValueAccessMode;

bool find_aggregate_member_info(const ASTNode *type, const char *member, AggregateMemberInfo *out);
void emit_load_ptr_from_fpvar(int ptrno, int src_offset);
void emit_store_ptr_to_fp(int dst_offset, int ptrno, int size);
bool compile_ref_argument_to_slot(ASTNode *expr, Context *ctx, int dst_offset, int dst_size);
bool emit_prepare_lvalue_ptr(Context *ctx, const LValueRef *lv, LValueAccessMode mode);
bool emit_copy_lvalue_to_fp(Context *ctx, int dst_offset, const LValueRef *src, int size);

#endif
