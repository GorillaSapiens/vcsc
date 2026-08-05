//! @file compiler/compile_expr_slot.c
//! @brief Implements expression-to-storage-slot lowering for the VCSC compiler.
//! @ingroup compiler

#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <stdbool.h>
#include <stdint.h>
#include <ctype.h>
#include <limits.h>

#include "ast.h"
#include "compile.h"
#include "compile_call.h"
#include "compile_expr.h"
#include "compile_expr_flow.h"
#include "compile_expr_info.h"
#include "compile_function.h"
#include "compile_init.h"
#include "compile_internal.h"
#include "compile_lvalue.h"
#include "compile_function_registry.h"
#include "compile_support.h"
#include "compile_type.h"
#include "emit.h"
#include "integer.h"
#include "memname.h"
#include "messages.h"
#include "pair.h"
#include "set.h"
#include "typename.h"
#include "xray.h"
#include "lextern.h"

#include "compile_expr_ops.h"
#include "compile_expr_slot.h"
static int cast_expr_target_size(const ASTNode *expr);

static const ASTNode *expr_lvalue_base_identifier_node(ASTNode *expr);

typedef CompilerScratchLease SlotFixedScratch;

//! @brief Begin and activate fixed-address slot scratch.
static void slot_fixed_scratch_begin(Context *ctx, int reserved,
                                     SlotFixedScratch *scratch) {
   compiler_scratch_acquire(ctx, reserved, scratch);
   compiler_scratch_activate(ctx, scratch);
}

//! @brief Deactivate the slot scratch lease live for copy-out.
static void slot_fixed_scratch_deactivate(Context *ctx, SlotFixedScratch *scratch) {
   compiler_scratch_deactivate(ctx, scratch);
}

//! @brief Release one inactive slot scratch lease.
static void slot_fixed_scratch_finish(SlotFixedScratch *scratch) {
   compiler_scratch_release(scratch);
}

//! @brief Deactivate and release a slot scratch lease on an error path.
static void slot_fixed_scratch_abort(Context *ctx, SlotFixedScratch *scratch) {
   compiler_scratch_deactivate(ctx, scratch);
   compiler_scratch_release(scratch);
}

//! @brief Copy a converted slot-scratch result into the caller destination.
static void emit_slot_fixed_scratch_result(Context *ctx, const SlotFixedScratch *scratch,
                                           int src_offset, int src_size, const ASTNode *src_type,
                                           ContextEntry *dst) {
   char dst_symbol[256];
   if (!dst || dst->size <= 0) {
      return;
   }
   if ((dst->is_static || dst->is_zeropage || dst->is_global) &&
       entry_symbol_name(ctx, dst, dst_symbol, sizeof(dst_symbol))) {
      emit_copy_symbol_to_symbol_convert_offset(dst_symbol, 0, dst->size, dst->type,
                                                scratch->symbol, src_offset, src_size, src_type);
   }
   else {
      emit_copy_symbol_to_scratch_convert_offset(dst->offset, dst->size, dst->type,
                                            scratch->symbol, src_offset, src_size, src_type);
   }
}

//! @brief Store a preserved assignment value into its lvalue without forcing a readback.
static bool emit_preserved_assignment_value(Context *ctx, const LValueRef *dst,
                                            const char *symbol, int size) {
   return emit_copy_preserved_symbol_to_lvalue(ctx, dst, symbol, size);
}

#define SIMPLE_ASSIGN_CHAIN_MAX 64

//! @brief Lower a right-associated simple assignment chain with one shared value slot.
//!
//! The old recursive lowering leased one scratch object for every nesting level
//! and copied the value outward through all of them.  Flattening the chain keeps
//! one converted value live, stores it to each lvalue from inside to outside,
//! and converts that same slot in place when adjacent target types differ.
static bool compile_simple_assignment_chain_to_slot(ASTNode *expr, Context *ctx,
                                                    ContextEntry *dst) {
   LValueRef targets[SIMPLE_ASSIGN_CHAIN_MAX];
   ASTNode *assignments[SIMPLE_ASSIGN_CHAIN_MAX];
   ASTNode *cursor = (ASTNode *) unwrap_expr_node(expr);
   ASTNode *rhs;
   SlotFixedScratch scratch;
   ContextEntry value;
   int sizes[SIMPLE_ASSIGN_CHAIN_MAX];
   int count = 0;
   int max_size = 0;
   int current_size;
   const ASTNode *current_type;

   while (cursor && !strcmp(cursor->name, "assign_expr") && cursor->count == 3) {
      const char *op = cursor->children[0] ? cursor->children[0]->strval : NULL;
      ASTNode *next_rhs = cursor->children[2];
      int value_size;

      if ((op && strcmp(op, ":=")) || initializer_is_list(unwrap_expr_node(next_rhs)) ||
          count >= SIMPLE_ASSIGN_CHAIN_MAX ||
          !resolve_lvalue(ctx, cursor->children[1], &targets[count]) ||
          targets[count].is_bitfield) {
         return false;
      }
      if (targets[count].is_absolute_ref &&
          (!targets[count].write_expr || !*targets[count].write_expr)) {
         error_user("[%s:%d.%d] absolute external binding '%s' is read-only",
                    cursor->file ? cursor->file : "<unknown>", cursor->line,
                    cursor->column,
                    targets[count].name ? targets[count].name : "<unnamed>");
      }

      value_size = targets[count].size;
      if (value_size <= 0) {
         value_size = declarator_storage_size(targets[count].type,
                                               targets[count].declarator);
      }
      if (value_size <= 0) {
         value_size = type_size_from_node(targets[count].type);
      }
      if (value_size <= 0) {
         return false;
      }
      sizes[count] = value_size;
      if (value_size > max_size) {
         max_size = value_size;
      }
      assignments[count++] = cursor;
      cursor = (ASTNode *) unwrap_expr_node(next_rhs);
   }

   if (count < 2 || !cursor) {
      return false;
   }
   rhs = cursor;

   for (int i = count - 2; i >= 0; i--) {
      if (!bcd_implicit_conversion_allowed(targets[i].type,
                                           targets[i].declarator,
                                           targets[i + 1].type,
                                           targets[i + 1].declarator,
                                           assignments[i + 1])) {
         error_user("[%s:%d.%d] packed-BCD and binary integer values cannot be mixed implicitly",
                    assignments[i]->file ? assignments[i]->file : "<unknown>",
                    assignments[i]->line, assignments[i]->column);
      }
   }

   slot_fixed_scratch_begin(ctx, max_size, &scratch);
   value = (ContextEntry){ .name = "$assign_chain", .type = targets[count - 1].type,
                           .declarator = targets[count - 1].declarator,
                           .is_static = false, .is_zeropage = false,
                           .is_global = false, .target_typed = true,
                           .offset = 0, .size = sizes[count - 1] };
   if (!compile_expr_to_slot(rhs, ctx, &value)) {
      slot_fixed_scratch_abort(ctx, &scratch);
      return false;
   }
   slot_fixed_scratch_deactivate(ctx, &scratch);

   current_size = sizes[count - 1];
   current_type = targets[count - 1].type;
   for (int i = count - 1; i >= 0; i--) {
      if (i != count - 1) {
         compiler_scratch_activate(ctx, &scratch);
         emit_copy_scratch_to_scratch_convert(0, sizes[i], targets[i].type,
                                              0, current_size, current_type);
         compiler_scratch_deactivate(ctx, &scratch);
         current_size = sizes[i];
         current_type = targets[i].type;
      }
      emit_lvalue_semantic_use(ctx, &targets[i], "write");
      if (!emit_preserved_assignment_value(ctx, &targets[i], scratch.symbol,
                                           current_size)) {
         slot_fixed_scratch_finish(&scratch);
         return false;
      }
   }

   emit_slot_fixed_scratch_result(ctx, &scratch, 0, current_size, current_type, dst);
   slot_fixed_scratch_finish(&scratch);
   return true;
}

//! @brief Return lvalue base identifier node data used by compile expr slot; returned pointers alias existing storage unless explicitly allocated by the function name.
static const ASTNode *lvalue_base_identifier_node(ASTNode *base) {
   if (!base) {
      return NULL;
   }
   if (!strcmp(base->name, "lvalue_base")) {
      if (base->count <= 0 || !base->children[0] || base->children[0]->kind != AST_IDENTIFIER) {
         return NULL;
      }
      return base->children[0];
   }
   if (!strcmp(base->name, "*") && base->count > 0) {
      return expr_lvalue_base_identifier_node(base->children[0]);
   }
   return NULL;
}

//! @brief Return expr lvalue base identifier node data used by compile expr slot; returned pointers alias existing storage unless explicitly allocated by the function name.
static const ASTNode *expr_lvalue_base_identifier_node(ASTNode *expr) {
   expr = (ASTNode *) unwrap_expr_node(expr);
   if (!expr || is_empty(expr)) {
      return NULL;
   }
   if (expr->kind == AST_IDENTIFIER) {
      return expr;
   }
   if (strcmp(expr->name, "lvalue") || expr->count < 1) {
      return NULL;
   }
   return lvalue_base_identifier_node(expr->children[0]);
}

//! @brief Return expr bare identifier node data used by compile expr slot; returned pointers alias existing storage unless explicitly allocated by the function name.
static const ASTNode *expr_bare_identifier_node(ASTNode *expr) {
   expr = (ASTNode *) unwrap_expr_node(expr);
   if (!expr || is_empty(expr)) {
      return NULL;
   }
   if (expr->kind == AST_IDENTIFIER) {
      return expr;
   }
   if (strcmp(expr->name, "lvalue") || expr->count != 2) {
      return NULL;
   }
   if (!expr->children[1] || !is_empty(expr->children[1])) {
      return NULL;
   }
   return lvalue_base_identifier_node(expr->children[0]);
}


//! @brief Lower constant expression to slot from AST/semantic state into generated assembly or linker-visible metadata.
bool compile_constant_expr_to_slot(ASTNode *expr, Context *ctx, ContextEntry *dst) {
   InitConstValue value = {0};
   unsigned char *bytes;
   (void) ctx;

   if (!dst || !eval_constant_initializer_expr(expr, &value)) {
      return false;
   }

   if (value.kind != INIT_CONST_INT) {
      return false;
   }

   bytes = (unsigned char *) calloc(dst->size ? dst->size : 1, sizeof(unsigned char));
   if (!bytes) {
      error_unreachable("out of memory");
   }
   if (!encode_init_const_int_value(&value, bytes, dst->size, dst->type)) {
      free(bytes);
      return false;
   }
   emit_store_immediate_to_scratch(dst->offset, bytes, dst->size);
   free(bytes);
   return true;
}




//! @brief Return whether declarator is not pointer in compile expr slot.
static bool declarator_is_not_pointer(const ASTNode *declarator) {
   return declarator_pointer_depth(declarator) == 0;
}

//! @brief Return whether type node is plain void in compile expr slot.
static bool type_node_is_plain_void(const ASTNode *type, const ASTNode *declarator) {
   const char *name = type_name_from_node(type);
   return name && !strcmp(name, "void") && declarator_is_not_pointer(declarator);
}

//! @brief Return whether expr is plain void cast in compile expr slot.
static bool expr_is_plain_void_cast(ASTNode *expr) {
   const ASTNode *target_type;
   const ASTNode *target_decl;

   expr = (ASTNode *) unwrap_expr_node(expr);
   if (!expr || strcmp(expr->name, "cast")) {
      return false;
   }
   target_type = cast_expr_target_type(expr);
   target_decl = cast_expr_target_declarator(expr);
   return type_node_is_plain_void(target_type, target_decl);
}

//! @brief Handle cast expression target size logic for compile expr slot.
static int cast_expr_target_size(const ASTNode *expr) {
   const ASTNode *type = cast_expr_target_type(expr);
   const ASTNode *declarator = cast_expr_target_declarator(expr);
   int size;

   if (!type) {
      return 0;
   }

   size = declarator_storage_size(type, declarator);
   if (size <= 0) {
      size = type_size_from_node(type);
   }
   return size;
}

//! @brief Report unknown identifier node diagnostics with the location/context expected by compile expr slot callers.
static void error_unknown_identifier_node(const ASTNode *idnode, const ASTNode *fallback, const char *ident) {
   const char *file = idnode && idnode->file ? idnode->file : (fallback && fallback->file ? fallback->file : "<unknown>");
   int line = idnode ? idnode->line : (fallback ? fallback->line : 0);
   int column = idnode ? idnode->column : (fallback ? fallback->column : 0);

   if (ident && !strcmp(ident, "$$")) {
      error_user("[%s:%d.%d] '$$' is the current function's return object, so it is only valid inside a function that returns a value. "
                 "Use it in a non-void function body, for example '$$.field := value; return;', or use 'return <expr>;' to have the compiler write the return object for you.",
                 file, line, column);
   }

   error_user("[%s:%d.%d] unknown identifier '%s'", file, line, column, ident ? ident : "<unknown>");
}

//! @brief Report an unresolved assignment target while preserving the most specific identifier diagnostic.
static void error_unresolved_assignment_target(Context *ctx, ASTNode *target, ASTNode *fallback) {
   const ASTNode *idnode = expr_lvalue_base_identifier_node(target);
   const char *ident = idnode ? idnode->strval : NULL;

   if (ident && !ctx_lookup(ctx, ident) && !global_decl_lookup(ident)) {
      error_unknown_identifier_node(idnode, target, ident);
   }
   error_user("[%s:%d.%d] invalid assignment target",
         target && target->file ? target->file : (fallback && fallback->file ? fallback->file : "<unknown>"),
         target ? target->line : (fallback ? fallback->line : 0),
         target ? target->column : (fallback ? fallback->column : 0));
}

//! @brief Handle sizeof operand size logic for compile expr slot.
static int sizeof_operand_size(const ASTNode *operand, Context *ctx) {
   operand = unwrap_expr_node(operand);
   if (!operand || is_empty(operand)) {
      return 0;
   }
   if (!strcmp(operand->name, "sizeof_expr") && operand->count > 0) {
      ASTNode *value = (ASTNode *) operand->children[0];
      const char *ident = expr_bare_identifier_name(value);
      int size;
      if (ident && !ctx_lookup(ctx, ident) && !global_decl_lookup(ident) && !resolve_function_designator_target(ident)) {
         error_unknown_identifier_node(expr_bare_identifier_node(value), value, ident);
      }
      size = expr_value_size(value, ctx);
      if (size <= 0) {
         error_user("[%s:%d.%d] invalid operand to sizeof",
               value && value->file ? value->file : (operand->file ? operand->file : "<unknown>"),
               value ? value->line : operand->line,
               value ? value->column : operand->column);
      }
      return size;
   }
   if (!strcmp(operand->name, "sizeof_type") && operand->count > 0) {
      const ASTNode *cast_type = operand->children[0];
      const ASTNode *specifiers;
      const ASTNode *type;
      const ASTNode *declarator;
      const char *type_name;
      int size;
      if (!cast_type || strcmp(cast_type->name, "cast_type") || cast_type->count < 2) {
         return 0;
      }
      specifiers = cast_type->children[0];
      if (!specifiers || specifiers->count < 2) {
         return 0;
      }
      type = specifiers->children[1];
      declarator = cast_type->children[1];
      type_name = type_name_from_node(type);
      if (type_name && !strcmp(type_name, "void") && declarator_pointer_depth(declarator) == 0) {
         error_user("[%s:%d.%d] invalid application of sizeof to void type",
               type && type->file ? type->file : (operand->file ? operand->file : "<unknown>"),
               type ? type->line : operand->line,
               type ? type->column : operand->column);
      }
      size = declarator_storage_size(type, declarator);
      if (size <= 0) {
         size = type_size_from_node(type);
      }
      if (size <= 0) {
         error_user("[%s:%d.%d] invalid application of sizeof to incomplete type '%s'",
               type && type->file ? type->file : (operand->file ? operand->file : "<unknown>"),
               type ? type->line : operand->line,
               type ? type->column : operand->column,
               type_name ? type_name : "<unknown>");
      }
      return size;
   }
   return 0;
}






//! @brief Lower expr to slot from AST/semantic state into generated assembly or linker-visible metadata.
bool compile_expr_to_slot(ASTNode *expr, Context *ctx, ContextEntry *dst) {
   expr = (ASTNode *) unwrap_expr_node(expr);

   if (!expr || is_empty(expr)) {
      return true;
   }

   if (dst && dst->target_typed && dst->declarator &&
       declarator_pointer_depth(dst->declarator) > 0 &&
       !integer_literal_is_zero_expr(expr)) {
      const ASTNode *src_type = NULL;
      const ASTNode *src_decl = NULL;
      expr_match_signature(expr, ctx, &src_type, &src_decl);
      if (src_type && src_decl && declarator_pointer_depth(src_decl) > 0) {
         validate_pointer_access_conversion(expr, dst->pointer_access,
                                            expr_pointer_access(expr, ctx),
                                            "pointer value");
      }
   }

   if (dst && dst->type && (!dst->declarator || declarator_is_plain_value(dst->declarator))) {
      const ASTNode *literal_type = literal_annotation_type(expr);
      bool constant_without_bcd_type = expr_is_integer_constant_expr(expr, NULL) &&
                                       (!literal_type || !type_is_bcd_integer(literal_type));

      /* Untyped constants adopt the destination representation.  Avoid asking
       * expr_value_type() for their legacy int16_t default because freestanding
       * machine descriptions are allowed to use different integer type names. */
      if (type_is_bcd_integer(dst->type) || !constant_without_bcd_type) {
         const ASTNode *src_type = expr_value_type(expr, ctx);
         const ASTNode *src_decl = expr_value_declarator(expr, ctx);

         if (!bcd_implicit_conversion_allowed(dst->type, dst->declarator,
                                              src_type, src_decl, expr)) {
            error_user("[%s:%d.%d] packed-BCD and binary integer values cannot be mixed implicitly",
                       expr->file ? expr->file : "<unknown>", expr->line, expr->column);
         }
      }
   }

   if (dst && dst->declarator && declarator_pointer_depth(dst->declarator) > 0) {
      const ASTNode *src_decl = expr_value_declarator(expr, ctx);
      if (src_decl && declarator_pointer_depth(src_decl) == 0 && declarator_array_count(src_decl) > 0) {
         LValueRef lv;
         if (resolve_ref_argument_lvalue(ctx, expr, &lv)) {
            if (!emit_prepare_lvalue_ptr(ctx, &lv, LVALUE_ACCESS_ADDRESS)) {
               return false;
            }
            emit_store_ptr_to_scratch(dst->offset, 0, dst->size);
            return true;
         }
      }
   }

   if (!strcmp(expr->name, "assign_expr") && expr->count == 3) {
      LValueRef lv;
      const char *op = expr->children[0] ? expr->children[0]->strval : NULL;
      ASTNode *rhs = expr->children[2];
      int load_size;

      if (compile_simple_assignment_chain_to_slot(expr, ctx, dst)) {
         return true;
      }

      if (!resolve_lvalue(ctx, expr->children[1], &lv)) {
         error_unresolved_assignment_target(ctx, expr->children[1], expr);
      }

      /* A simple assignment expression has the converted value written to its
       * left operand.  Preserve that value while it is still in compiler
       * scratch instead of storing it and then reading the lvalue back.  The
       * readback is both unnecessary and invalid for write-only absolute external bindings
       * such as TIA registers.  Bitfields retain the store/readback path below
       * because their expression value must reflect width truncation and signed
       * extension performed by the bitfield accessors. */
      if ((!op || !strcmp(op, ":=")) && !lv.is_bitfield &&
          !initializer_is_list(unwrap_expr_node(rhs))) {
         SlotFixedScratch scratch;
         ContextEntry value;
         int value_size = lv.size;

         if (lv.is_absolute_ref && (!lv.write_expr || !*lv.write_expr)) {
            error_user("[%s:%d.%d] absolute external binding '%s' is read-only",
                       expr->file ? expr->file : "<unknown>", expr->line, expr->column,
                       lv.name ? lv.name : "<unnamed>");
         }
         if (value_size <= 0) {
            value_size = declarator_storage_size(lv.type, lv.declarator);
         }
         if (value_size <= 0) {
            value_size = type_size_from_node(lv.type);
         }
         if (value_size <= 0) {
            return false;
         }

         slot_fixed_scratch_begin(ctx, value_size, &scratch);
         value = (ContextEntry){ .name = "$assign", .type = lv.type,
                                 .declarator = lv.declarator,
                                 .is_static = false, .is_zeropage = false,
                                 .is_global = false, .target_typed = true,
                                 .pointer_access = lv.pointer_access,
                                 .offset = 0, .size = value_size };
         if (!compile_expr_to_slot(rhs, ctx, &value)) {
            slot_fixed_scratch_abort(ctx, &scratch);
            return false;
         }
         slot_fixed_scratch_deactivate(ctx, &scratch);
         emit_lvalue_semantic_use(ctx, &lv, "write");
         if (!emit_preserved_assignment_value(ctx, &lv, scratch.symbol, value_size)) {
            slot_fixed_scratch_finish(&scratch);
            return false;
         }
         emit_slot_fixed_scratch_result(ctx, &scratch, 0, value_size, lv.type, dst);
         slot_fixed_scratch_finish(&scratch);
         return true;
      }

      compile_expr(expr, ctx);

      load_size = lv.size < dst->size ? lv.size : dst->size;
      if (load_size <= 0) {
         load_size = dst->size > 0 ? dst->size : lv.size;
      }
      if (load_size <= 0) {
         return false;
      }

      if (!emit_copy_lvalue_to_scratch(ctx, dst->offset, &lv, load_size)) {
         return false;
      }
      emit_copy_scratch_to_scratch_convert(dst->offset, dst->size, dst->type, dst->offset, load_size, lv.type);
      return true;
   }

   if (!strcmp(expr->name, "()")) {
      return compile_call_expr_to_slot(expr, ctx, dst);
   }

   if (!strcmp(expr->name, "cast") || !strcmp(expr->name, "flag_cast")) {
      const ASTNode *target_type = !strcmp(expr->name, "cast") ? cast_expr_target_type(expr) : flag_cast_target_type(expr, ctx);
      const ASTNode *target_decl = !strcmp(expr->name, "cast") ? cast_expr_target_declarator(expr) : flag_cast_target_declarator(expr, ctx);
      int target_size = !strcmp(expr->name, "cast") ? cast_expr_target_size(expr) : flag_cast_target_size(expr, ctx);
      SlotFixedScratch scratch;
      ContextEntry tmp;
      if (expr_is_plain_void_cast(expr)) {
         error_user("[%s:%d.%d] void expression has no value",
               expr->file ? expr->file : "<unknown>", expr->line, expr->column);
      }
      if (!target_type || target_size <= 0 || expr->count < 2) {
         error_user("[%s:%d.%d] invalid cast target type",
               expr->file ? expr->file : "<unknown>", expr->line, expr->column);
      }
      slot_fixed_scratch_begin(ctx, target_size, &scratch);
      tmp = (ContextEntry){ .name = "$cast", .type = target_type, .declarator = target_decl,
                            .is_static = false, .is_zeropage = false, .is_global = false,
                            .target_typed = true, .offset = 0, .size = target_size };
      if (!compile_expr_to_slot(expr->children[1], ctx, &tmp)) {
         slot_fixed_scratch_abort(ctx, &scratch);
         return false;
      }
      slot_fixed_scratch_deactivate(ctx, &scratch);
      emit_slot_fixed_scratch_result(ctx, &scratch, 0, tmp.size, tmp.type, dst);
      slot_fixed_scratch_finish(&scratch);
      return true;
   }

   if (!strcmp(expr->name, "sizeof")) {
      int size_value = sizeof_operand_size(expr->children[0], ctx);
      unsigned char *bytes;
      if (size_value <= 0) {
         return false;
      }
      bytes = (unsigned char *) calloc(dst->size ? dst->size : 1, sizeof(unsigned char));
      if (!bytes) {
         error_unreachable("out of memory");
      }
      if (!encode_integer_initializer_value(size_value, bytes, dst->size, dst->type)) {
         free(bytes);
         return false;
      }
      emit_store_immediate_to_scratch(dst->offset, bytes, dst->size);
      free(bytes);
      return true;
   }

   if (expr->kind == AST_INTEGER) {
      unsigned char *bytes = (unsigned char *) calloc(dst->size ? dst->size : 1, sizeof(unsigned char));
      if (!encode_integer_literal_text(expr->strval, bytes, dst->size, dst->type)) {
         free(bytes);
         return false;
      }
      emit_store_immediate_to_scratch(dst->offset, bytes, dst->size);
      free(bytes);
      return true;
   }

   if (expr->kind == AST_STRING) {
      long long ch_value = 0;

      if (decode_char_constant_value(expr->strval, &ch_value)) {
         unsigned char *bytes = (unsigned char *) calloc(dst->size ? dst->size : 1, sizeof(unsigned char));
         if (!encode_integer_initializer_value(ch_value, bytes, dst->size, dst->type)) {
            free(bytes);
            return false;
         }
         emit_store_immediate_to_scratch(dst->offset, bytes, dst->size);
         free(bytes);
      }
      else {
         const char *label = emit_pointer_initializer_backing_object(dst ? dst->type : NULL,
               dst ? dst->declarator : NULL, expr);
         if (!label) {
            label = remember_string_literal(expr->strval);
         }
         emit_store_label_address_to_scratch(dst->offset, dst->size, label);
      }
      return true;
   }

   {
      const char *ident = expr_bare_identifier_name(expr);
      if (ident) {
         ContextEntry *entry = ctx_lookup(ctx, ident);
         if (entry && entry_is_absolute_ref(entry)) {
            LValueRef lv = { .name = entry->name, .type = entry->type, .declarator = entry->declarator, .base_type = entry->type, .base_declarator = entry->declarator, .is_static = entry->is_static, .is_zeropage = entry->is_zeropage, .is_global = entry->is_global, .is_ref = entry->is_ref, .is_absolute_ref = entry->is_absolute_ref, .read_expr = entry->read_expr, .write_expr = entry->write_expr, .has_split_alias_delta = entry->has_split_alias_delta, .split_alias_delta = entry->split_alias_delta, .offset = entry->offset, .size = entry->size, .use_site = expr };
            if (!entry_has_read_address(entry)) {
               error_user("[%s:%d.%d] absolute external binding '%s' is write-only", expr->file, expr->line, expr->column, ident);
            }
            if (dst->size == lv.size && dst->type == lv.type) {
               return emit_copy_lvalue_to_scratch(ctx, dst->offset, &lv, lv.size);
            }
            {
               SlotFixedScratch scratch;
               slot_fixed_scratch_begin(ctx, lv.size, &scratch);
               if (!emit_copy_lvalue_to_scratch(ctx, 0, &lv, lv.size)) {
                  slot_fixed_scratch_abort(ctx, &scratch);
                  return false;
               }
               slot_fixed_scratch_deactivate(ctx, &scratch);
               emit_slot_fixed_scratch_result(ctx, &scratch, 0, lv.size, lv.type, dst);
               slot_fixed_scratch_finish(&scratch);
               return true;
            }
         }
         if (entry && entry->is_ref) {
            int value_size = declarator_storage_size(entry->type, entry->declarator);
            LValueRef lv = {
               .name = entry->name,
               .type = entry->type,
               .declarator = entry->declarator,
               .base_type = entry->type,
               .base_declarator = entry->declarator,
               .is_static = entry->is_static,
               .is_zeropage = entry->is_zeropage,
               .is_global = entry->is_global,
               .is_ref = true,
               .is_absolute_ref = false,
               .read_expr = entry->read_expr,
               .write_expr = entry->write_expr,
               .offset = entry->offset,
               .size = value_size,
               .use_site = expr
            };
            if (dst->size == value_size && dst->type == entry->type) {
               return emit_copy_lvalue_to_scratch(ctx, dst->offset, &lv, value_size);
            }
            {
               SlotFixedScratch scratch;
               slot_fixed_scratch_begin(ctx, value_size, &scratch);
               if (!emit_copy_lvalue_to_scratch(ctx, 0, &lv, value_size)) {
                  slot_fixed_scratch_abort(ctx, &scratch);
                  return false;
               }
               slot_fixed_scratch_deactivate(ctx, &scratch);
               emit_slot_fixed_scratch_result(ctx, &scratch, 0, value_size, entry->type, dst);
               slot_fixed_scratch_finish(&scratch);
               return true;
            }
         }
         if (entry && !entry->is_static && !entry->is_zeropage) {
            emit_copy_scratch_to_scratch_convert(dst->offset, dst->size, dst->type, entry->offset, entry->size, entry->type);
            return true;
         }
         if (entry) {
            char sym[256];
            if (entry_symbol_name(ctx, entry, sym, sizeof(sym))) {
               LValueRef lv = {
                  .name = entry->name ? entry->name : ident,
                  .type = entry->type,
                  .declarator = entry->declarator,
                  .base_type = entry->type,
                  .base_declarator = entry->declarator,
                  .is_static = entry->is_static,
                  .is_zeropage = entry->is_zeropage,
                  .is_global = entry->is_global,
                  .is_ref = entry->is_ref,
                  .is_absolute_ref = entry->is_absolute_ref,
                  .read_expr = entry->read_expr,
                  .write_expr = entry->write_expr,
                  .has_split_alias_delta = entry->has_split_alias_delta,
                  .split_alias_delta = entry->split_alias_delta,
                  .base_offset = entry->offset,
                  .offset = entry->offset,
                  .size = entry->size,
                  .use_site = expr
               };
               emit_lvalue_semantic_use(ctx, &lv, "read");
               emit_copy_symbol_to_scratch_convert(dst->offset, dst->size, dst->type, sym, entry->size, entry->type);
               return true;
            }
         }
         {
            const ASTNode *g = global_decl_lookup(ident);
            if (g && g->count >= 3) {
               ContextEntry gentry;
               if (init_context_entry_from_global_decl(&gentry, ident, g) && entry_is_absolute_ref(&gentry)) {
                  LValueRef lv = { .name = gentry.name, .type = gentry.type, .declarator = gentry.declarator, .base_type = gentry.type, .base_declarator = gentry.declarator, .is_static = gentry.is_static, .is_zeropage = gentry.is_zeropage, .is_global = gentry.is_global, .is_ref = gentry.is_ref, .is_absolute_ref = gentry.is_absolute_ref, .read_expr = gentry.read_expr, .write_expr = gentry.write_expr, .offset = gentry.offset, .size = gentry.size, .use_site = expr };
                  if (!entry_has_read_address(&gentry)) {
                     error_user("[%s:%d.%d] absolute external binding '%s' is write-only", expr->file, expr->line, expr->column, ident);
                  }
                  if (dst->size == lv.size && dst->type == lv.type) {
                     return emit_copy_lvalue_to_scratch(ctx, dst->offset, &lv, lv.size);
                  }
                  {
                     SlotFixedScratch scratch;
                     slot_fixed_scratch_begin(ctx, lv.size, &scratch);
                     if (!emit_copy_lvalue_to_scratch(ctx, 0, &lv, lv.size)) {
                        slot_fixed_scratch_abort(ctx, &scratch);
                        return false;
                     }
                     slot_fixed_scratch_deactivate(ctx, &scratch);
                     emit_slot_fixed_scratch_result(ctx, &scratch, 0, lv.size, lv.type, dst);
                     slot_fixed_scratch_finish(&scratch);
                     return true;
                  }
               }
               else {
                  char sym[256];
                  int gsize = declarator_storage_size(g->children[1], decl_node_declarator(g));
                  LValueRef lv = {
                     .name = ident,
                     .type = g->children[1],
                     .declarator = decl_node_declarator(g),
                     .base_type = g->children[1],
                     .base_declarator = decl_node_declarator(g),
                     .is_global = true,
                     .base_offset = 0,
                     .offset = 0,
                     .size = gsize,
                     .use_site = expr
                  };
                  format_user_asm_symbol(ident, sym, sizeof(sym));
                  emit_lvalue_semantic_use(ctx, &lv, "read");
                  emit_copy_symbol_to_scratch_convert(dst->offset, dst->size, dst->type, sym, gsize, g->children[1]);
                  return true;
               }
            }
         }
         {
            const ASTNode *fn = resolve_function_designator_target(ident);
            if (fn) {
               error_user("[%s:%d.%d] function pointers are not supported; call '%s' directly",
                          expr->file, expr->line, expr->column, ident);
            }
         }
         error_unknown_identifier_node(expr_bare_identifier_node(expr), expr, ident);
      }
   }

   if (expr->count == 1 && !strcmp(expr->name, "&")) {
      LValueRef lv;
      ASTNode *inner = (ASTNode *) unwrap_expr_node(expr->children[0]);
      if (inner && !strcmp(inner->name, "lvalue") && resolve_lvalue(ctx, inner, &lv)) {
         if (!emit_prepare_lvalue_ptr(ctx, &lv, LVALUE_ACCESS_ADDRESS)) {
            if (lv.is_absolute_ref) {
               error_user("[%s:%d.%d] absolute external binding '%s' does not have a single address", inner->file, inner->line, inner->column, lv.name ? lv.name : "<unnamed>");
            }
            return false;
         }
         emit_store_ptr_to_scratch(dst->offset, 0, dst->size);
         return true;
      }
      {
         const char *ident = expr_bare_identifier_name(inner);
         if (ident) {
            const ASTNode *fn = resolve_function_designator_target(ident);
            if (fn) {
               error_user("[%s:%d.%d] function pointers are not supported; call '%s' directly",
                          inner->file, inner->line, inner->column, ident);
            }
            if (!ctx_lookup(ctx, ident) && !global_decl_lookup(ident)) {
               error_unknown_identifier_node(expr_bare_identifier_node(inner), inner, ident);
            }
         }
      }
      {
         const char *label = emit_pointer_initializer_backing_object(dst ? dst->type : NULL,
               dst ? dst->declarator : NULL, expr);
         InitConstValue value = {0};
         if (label) {
            emit_store_label_address_to_scratch(dst->offset, dst->size, label);
            return true;
         }
         if (eval_constant_initializer_expr(inner, &value) && value.kind == INIT_CONST_INT) {
            unsigned char *bytes = (unsigned char *) calloc(dst->size ? dst->size : 1, sizeof(unsigned char));
            char tmp[64];
            snprintf(tmp, sizeof(tmp), "%lld", value.i);
            make_le_int(tmp, bytes, dst->size);
            emit_store_immediate_to_scratch(dst->offset, bytes, dst->size);
            free(bytes);
            return true;
         }
      }
   }



   if (compile_expr_operator_to_slot(expr, ctx, dst)) {
      return true;
   }

   if (!strcmp(expr->name, "lvalue") && expr->count > 0) {
      LValueRef lv;
      if (resolve_lvalue(ctx, expr, &lv)) {
         int load_size = lv.size < dst->size ? lv.size : dst->size;
         if (lv.size == dst->size && !strcmp(type_name_from_node(lv.type), type_name_from_node(dst->type)) &&
             declarator_pointer_depth(lv.declarator) == declarator_pointer_depth(dst->declarator) &&
             declarator_array_count(lv.declarator) == declarator_array_count(dst->declarator)) {
            return emit_copy_lvalue_to_scratch(ctx, dst->offset, &lv, lv.size);
         }
         if (!emit_copy_lvalue_to_scratch(ctx, dst->offset, &lv, load_size)) {
            return false;
         }
         emit_copy_scratch_to_scratch_convert(dst->offset, dst->size, dst->type, dst->offset, load_size, lv.type);
         return true;
      }
      {
         const ASTNode *idnode = expr_lvalue_base_identifier_node(expr);
         const char *ident = idnode ? idnode->strval : NULL;
         if (ident && !ctx_lookup(ctx, ident) && !global_decl_lookup(ident)) {
            error_unknown_identifier_node(idnode, expr, ident);
         }
      }
      error_user("[%s:%d.%d] invalid lvalue expression",
            expr->file ? expr->file : "<unknown>", expr->line, expr->column);
   }

   if (!strcmp(expr->name, "comma_expr") && expr->count > 0) {
      for (int i = 0; i < expr->count - 1; i++) {
         compile_expr(expr->children[i], ctx);
      }
      return compile_expr_to_slot(expr->children[expr->count - 1], ctx, dst);
   }

   if (expr_is_ternary_node(expr)) {
      ASTNode *test_expr = expr_ternary_test(expr);
      ASTNode *true_expr = expr_ternary_true(expr);
      ASTNode *false_expr = expr_ternary_false(expr);
      const char *false_label = next_label("ternary_false");
      const char *end_label = next_label("ternary_end");
      bool ok;
      if (!test_expr || !true_expr || !false_expr || !false_label || !end_label) {
         free((void *) false_label);
         free((void *) end_label);
         return false;
      }
      if (!compile_condition_branch_false(test_expr, ctx, false_label)) {
         free((void *) false_label);
         free((void *) end_label);
         return false;
      }
      ok = compile_expr_to_slot(true_expr, ctx, dst);
      emit(&es_code, "    jmp %s\n", end_label);
      emit(&es_code, "%s:\n", false_label);
      if (ok) {
         ok = compile_expr_to_slot(false_expr, ctx, dst);
      }
      emit(&es_code, "%s:\n", end_label);
      free((void *) false_label);
      free((void *) end_label);
      return ok;
   }



   return false;
}




