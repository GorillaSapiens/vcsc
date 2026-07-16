//! @file compiler/compile_literal.c
//! @brief Implements literal lowering for the n65 compiler.
//! @ingroup compiler

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>

#include "ast.h"
#include "compile_init.h"
#include "compile_internal.h"
#include "compile_literal.h"
#include "compile_overload.h"
#include "compile_type.h"
#include "emit.h"
#include "messages.h"
#include "set.h"

//! @brief Parse string literal bytes into the normalized representation used by compile literal.
static unsigned char *decode_string_literal_bytes(const char *text, int *out_len) {
   size_t raw_len;
   unsigned char *buf;

   if (!text) {
      text = "";
   }
   raw_len = strlen(text);
   buf = (unsigned char *) malloc(raw_len + 1);
   if (!buf) {
      error_unreachable("out of memory");
   }
   if (raw_len > 0) {
      memcpy(buf, text, raw_len);
   }
   buf[raw_len] = 0;

   if (out_len) {
      *out_len = (int) raw_len;
   }
   return buf;
}

//! @brief Return whether string literal is char constant in compile literal.
bool string_literal_is_char_constant(const char *text) {
   size_t len;

   if (!text) {
      return false;
   }
   len = strlen(text);
   return len >= 2 && text[0] == '\'' && text[len - 1] == '\'';
}

//! @brief Parse char constant value into the normalized representation used by compile literal.
bool decode_char_constant_value(const char *text, long long *value_out) {
   unsigned char *bytes;
   char *raw;
   size_t len;
   int count = 0;
   bool ok = false;

   if (!string_literal_is_char_constant(text) || !value_out) {
      return false;
   }
   len = strlen(text);
   raw = (char *) malloc(len > 1 ? len - 1 : 1);
   if (!raw) {
      error_unreachable("out of memory");
   }
   memcpy(raw, text + 1, len - 2);
   raw[len - 2] = '\0';
   bytes = decode_string_literal_bytes(raw, &count);
   free(raw);
   if (bytes && count == 1) {
      *value_out = bytes[0];
      ok = true;
   }
   free(bytes);
   return ok;
}

//! @brief Emit data literal object for compile literal diagnostics or output files.
static const char *emit_data_literal_object(const unsigned char *bytes, int size) {
   char *label;

   if (size < 0) {
      return NULL;
   }

   label = (char *) malloc(64);
   if (!label) {
      error_unreachable("out of memory");
   }
   snprintf(label, 64, "__data_%d", label_counter++);
   emit(&es_data, "%s:\n", label);
   if (size <= 0) {
      emit(&es_data, "\t.byte $00\n");
      return label;
   }
   emit_initializer_bytes_line(&es_data, bytes, size);
   return label;
}

//! @brief Emit data string object for compile literal diagnostics or output files.
static const char *emit_data_string_object(const char *text) {
   unsigned char *bytes;
   unsigned char *buf;
   const char *label;
   int n = 0;

   if (!text) {
      text = "";
   }
   bytes = decode_string_literal_bytes(text, &n);
   buf = (unsigned char *) calloc((size_t) n + 1u, 1);
   if (!buf) {
      free(bytes);
      error_unreachable("out of memory");
   }
   if (n > 0) {
      memcpy(buf, bytes, (size_t) n);
   }
   free(bytes);
   label = emit_data_literal_object(buf, n + 1);
   free(buf);
   return label;
}

//! @brief Add string literal to compile literal state, growing storage or preserving uniqueness as needed.
const char *remember_string_literal(const char *text) {
   const char *existing;
   char *label;
   unsigned char *bytes;
   int n = 0;

   if (!text) {
      text = "";
   }
   if (!string_literals) {
      string_literals = new_set();
   }
   existing = (const char *) set_get(string_literals, text);
   if (existing) {
      return existing;
   }
   label = (char *) malloc(64);
   if (!label) {
      error_unreachable("out of memory");
   }
   snprintf(label, 64, "__str_%d", label_counter++);
   set_add(string_literals, strdup(text), label);
   emit(&es_rodata, "%s:\n", label);

   bytes = decode_string_literal_bytes(text, &n);
   if (n <= 0) {
      emit(&es_rodata, "\t.byte $00\n");
   }
   else {
      emit(&es_rodata, "\t.byte $%02x", (unsigned int) bytes[0]);
      for (int i = 1; i < n; i++) {
         emit(&es_rodata, ", $%02x", (unsigned int) bytes[i]);
      }
      emit(&es_rodata, ", $00\n");
   }
   free(bytes);
   return label;
}

//! @brief Return whether pointer initializer uses backing object in compile literal.
bool pointer_initializer_uses_backing_object(const ASTNode *type, const ASTNode *declarator, const ASTNode *expr) {
   const ASTNode *uexpr = unwrap_expr_node((ASTNode *) expr);

   (void) type;
   if (!uexpr || is_empty(uexpr) || !declarator) {
      return false;
   }
   if (declarator_function_pointer_depth(declarator) > 0) {
      return false;
   }
   if (declarator_pointer_depth(declarator) <= 0 && (!type || strcmp(type_name_from_node(type), "*"))) {
      return false;
   }
   if (uexpr->kind == AST_STRING && !string_literal_is_char_constant(uexpr->strval)) {
      return true;
   }
   if (uexpr->count == 1 && !strcmp(uexpr->name, "&")) {
      ASTNode *inner = (ASTNode *) unwrap_expr_node(uexpr->children[0]);
      InitConstValue value = {0};
      const char *ident = expr_bare_identifier_name(inner);

      if (inner && !strcmp(inner->name, "lvalue")) {
         return false;
      }
      if (ident && resolve_function_designator_target(ident, NULL, NULL)) {
         return false;
      }
      return eval_constant_initializer_expr(inner, &value) && value.kind == INIT_CONST_INT;
   }
   return false;
}

//! @brief Emit pointer initializer backing object for compile literal diagnostics or output files.
const char *emit_pointer_initializer_backing_object(const ASTNode *type, const ASTNode *declarator, const ASTNode *expr) {
   const ASTNode *uexpr = unwrap_expr_node((ASTNode *) expr);

   if (!pointer_initializer_uses_backing_object(type, declarator, uexpr)) {
      return NULL;
   }

   if (uexpr->kind == AST_STRING) {
      return emit_data_string_object(uexpr->strval);
   }

   if (uexpr->count == 1 && !strcmp(uexpr->name, "&")) {
      ASTNode *inner = (ASTNode *) unwrap_expr_node(uexpr->children[0]);
      InitConstValue value = {0};
      const ASTNode *obj_type = NULL;
      const ASTNode *obj_decl = NULL;
      const ASTNode *annotated = NULL;
      const char *obj_name = NULL;
      unsigned char *bytes;
      int obj_size = 0;

      if (!eval_constant_initializer_expr(inner, &value) || value.kind != INIT_CONST_INT) {
         return NULL;
      }

      if (declarator && declarator_pointer_depth(declarator) > 0) {
         obj_decl = declarator_after_deref(declarator);
         obj_type = type;
         obj_name = type ? type_name_from_node(type) : NULL;
         if (!obj_name || !strcmp(obj_name, "void") || !strcmp(obj_name, "*")) {
            obj_type = NULL;
            obj_decl = NULL;
         }
      }
      if (!obj_type) {
         annotated = literal_annotation_type(inner);
         if (annotated && type_size_from_node(annotated) > 0) {
            obj_type = annotated;
         }
         else {
            obj_type = required_typename_node("int");
         }
      }
      if (obj_decl) {
         obj_size = declarator_storage_size(obj_type, obj_decl);
      }
      else {
         obj_size = type_size_from_node(obj_type);
      }
      if (obj_size <= 0) {
         obj_type = required_typename_node("int");
         obj_decl = NULL;
         obj_size = type_size_from_node(obj_type);
      }
      bytes = (unsigned char *) calloc((size_t) obj_size, 1);
      if (!bytes) {
         error_unreachable("out of memory");
      }
      if (!encode_init_const_int_value(&value, bytes, obj_size, obj_type)) {
         free(bytes);
         return NULL;
      }
      {
         const char *label = emit_data_literal_object(bytes, obj_size);
         free(bytes);
         return label;
      }
   }

   return NULL;
}

//! @brief Emit store label address to frame pointer for compile literal diagnostics or output files.
void emit_store_label_address_to_fp(int dst_offset, int dst_size, const char *label) {
   if (!label || dst_size <= 0) {
      return;
   }
   emit(&es_code, "    lda #<%s\n", label);
   emit(&es_code, "    ldy #%d\n", dst_offset);
   emit(&es_code, "    sta (fp),y\n");
   if (dst_size > 1) {
      emit(&es_code, "    lda #>%s\n", label);
      emit(&es_code, "    ldy #%d\n", dst_offset + 1);
      emit(&es_code, "    sta (fp),y\n");
   }
   if (dst_size > 2) {
      emit_fill_fp_bytes(dst_offset, 2, dst_size - 2, 0);
   }
}

//! @brief Emit string initializer to frame pointer for compile literal diagnostics or output files.
bool emit_string_initializer_to_fp(const ASTNode *type, const ASTNode *declarator, int base_offset, int total_size, const char *text) {
   int elem_count, elem_size, copy_len;
   (void) total_size;
   if (!text) {
      text = "";
   }
   if (declarator && declarator_array_count(declarator) > 0 && declarator_pointer_depth(declarator) == 0) {
      elem_count = atoi(declarator->children[2]->strval);
      elem_size = declarator_first_element_size(type, declarator);
      if (elem_size != 1 || elem_count <= 0) {
         return false;
      }
      copy_len = (int) strlen(text) + 1;
      if (copy_len > elem_count) {
         copy_len = elem_count;
      }
      for (int i = 0; i < copy_len; i++) {
         unsigned char b = (unsigned char) (i < (int) strlen(text) ? text[i] : 0);
         emit(&es_code, "    lda #$%02x\n", (unsigned int) b);
         emit(&es_code, "    ldy #%d\n", base_offset + i);
         emit(&es_code, "    sta (fp),y\n");
      }
      return true;
   }
   if (declarator_pointer_depth(declarator) > 0 || (type && !strcmp(type_name_from_node(type), "*"))) {
      const char *label = emit_data_string_object(text);
      emit_store_label_address_to_fp(base_offset, total_size > 0 ? total_size : declarator_storage_size(type, declarator), label);
      return true;
   }
   return false;
}

//! @brief Emit string initializer bytes for compile literal diagnostics or output files.
bool emit_string_initializer_bytes(unsigned char *buf, int buf_size, int base_offset, const ASTNode *type, const ASTNode *declarator, int total_size, const char *text) {
   int elem_count, elem_size, copy_len, bytes_len = 0;
   unsigned char *bytes;
   (void) total_size;
   if (!buf || !text) {
      return false;
   }
   bytes = decode_string_literal_bytes(text, &bytes_len);
   if (declarator && declarator_array_count(declarator) > 0 && declarator_pointer_depth(declarator) == 0) {
      elem_count = atoi(declarator->children[2]->strval);
      elem_size = declarator_first_element_size(type, declarator);
      if (elem_size != 1 || elem_count <= 0) {
         free(bytes);
         return false;
      }
      copy_len = bytes_len + 1;
      if (copy_len > elem_count) {
         copy_len = elem_count;
      }
      if (base_offset < 0 || base_offset + elem_count > buf_size) {
         free(bytes);
         return false;
      }
      if (copy_len > 1) {
         memcpy(buf + base_offset, bytes, (size_t) (copy_len - 1));
      }
      if (copy_len > 0) {
         buf[base_offset + copy_len - 1] = 0;
      }
      free(bytes);
      return true;
   }
   free(bytes);
   return false;
}
