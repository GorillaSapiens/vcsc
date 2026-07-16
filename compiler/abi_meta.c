//! @file compiler/abi_meta.c
//! @brief Implements ABI metadata emission for the n65 compiler.
//! @ingroup compiler

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <stdbool.h>
#include <ctype.h>

#include "abi_meta.h"
#include "compile_declarator.h"
#include "compile_internal.h"
#include "compile_overload.h"
#include "compile_type.h"
#include "emit.h"
#include "messages.h"
#include "set.h"
#include "typename.h"

extern Pair *enumbackings;

typedef struct {
   char *buf;
   size_t len;
   size_t cap;
} StrBuf;

typedef struct {
   const char **names;
   int *ids;
   int *active;
   int count;
   int cap;
   int next_id;
} FingerprintCtx;

//! @brief Handle sb init logic for abi meta.
static void sb_init(StrBuf *sb) {
   sb->buf = NULL;
   sb->len = 0;
   sb->cap = 0;
}

//! @brief Handle sb reserve logic for abi meta.
static void sb_reserve(StrBuf *sb, size_t add) {
   size_t need = sb->len + add + 1;
   char *next;

   if (need <= sb->cap)
      return;

   sb->cap = sb->cap ? sb->cap : 128;
   while (sb->cap < need)
      sb->cap *= 2;

   next = (char *)realloc(sb->buf, sb->cap);
   if (!next)
      error_unreachable("out of memory");
   sb->buf = next;
}

//! @brief Handle sb append logic for abi meta.
static void sb_append(StrBuf *sb, const char *text) {
   size_t n;
   if (!text)
      return;
   n = strlen(text);
   sb_reserve(sb, n);
   memcpy(sb->buf + sb->len, text, n);
   sb->len += n;
   sb->buf[sb->len] = '\0';
}

//! @brief Handle sb append ch logic for abi meta.
static void sb_append_ch(StrBuf *sb, char ch) {
   sb_reserve(sb, 1);
   sb->buf[sb->len++] = ch;
   sb->buf[sb->len] = '\0';
}

//! @brief Handle sb appendf logic for abi meta.
static void sb_appendf(StrBuf *sb, const char *fmt, ...) {
   va_list ap;
   va_list ap2;
   int need;

   while (1) {
      size_t avail;
      sb_reserve(sb, 64);
      avail = sb->cap - sb->len;
      va_start(ap, fmt);
      va_copy(ap2, ap);
      need = vsnprintf(sb->buf + sb->len, avail, fmt, ap2);
      va_end(ap2);
      va_end(ap);
      if (need < 0)
         error_unreachable("vsnprintf failed");
      if ((size_t)need < avail) {
         sb->len += (size_t)need;
         return;
      }
      sb_reserve(sb, (size_t)need + 1);
   }
}

//! @brief Return sb take data used by abi meta; returned pointers alias existing storage unless explicitly allocated by the function name.
static char *sb_take(StrBuf *sb) {
   char *ret;
   if (!sb->buf) {
      ret = strdup("");
      if (!ret)
         error_unreachable("out of memory");
      return ret;
   }
   ret = sb->buf;
   sb->buf = NULL;
   sb->len = 0;
   sb->cap = 0;
   return ret;
}

//! @brief Handle meta safe char logic for abi meta.
static bool meta_safe_char(unsigned char ch) {
   return isalnum(ch) || ch == '_';
}

//! @brief Return meta encode data used by abi meta; returned pointers alias existing storage unless explicitly allocated by the function name.
static char *meta_encode(const char *text) {
   StrBuf sb;
   const unsigned char *p = (const unsigned char *)(text ? text : "");
   sb_init(&sb);

   while (*p) {
      if (meta_safe_char(*p) && *p != 'Q') {
         sb_append_ch(&sb, (char)*p);
      }
      else {
         sb_appendf(&sb, "Q%02X", (unsigned)*p);
      }
      p++;
   }

   return sb_take(&sb);
}

//! @brief Handle fpctx find logic for abi meta.
static int fpctx_find(FingerprintCtx *ctx, const char *name) {
   for (int i = 0; i < ctx->count; i++) {
      if (!strcmp(ctx->names[i], name))
         return i;
   }
   return -1;
}

//! @brief Handle fpctx get id logic for abi meta.
static int fpctx_get_id(FingerprintCtx *ctx, const char *name, bool *active_out, bool *is_new_out) {
   int idx = fpctx_find(ctx, name);
   if (idx >= 0) {
      if (active_out)
         *active_out = ctx->active[idx] != 0;
      if (is_new_out)
         *is_new_out = false;
      return ctx->ids[idx];
   }

   if (ctx->count == ctx->cap) {
      int new_cap = ctx->cap ? ctx->cap * 2 : 8;
      ctx->names = (const char **)realloc(ctx->names, (size_t)new_cap * sizeof(*ctx->names));
      ctx->ids = (int *)realloc(ctx->ids, (size_t)new_cap * sizeof(*ctx->ids));
      ctx->active = (int *)realloc(ctx->active, (size_t)new_cap * sizeof(*ctx->active));
      if (!ctx->names || !ctx->ids || !ctx->active)
         error_unreachable("out of memory");
      ctx->cap = new_cap;
   }

   idx = ctx->count++;
   ctx->names[idx] = name;
   ctx->ids[idx] = ++ctx->next_id;
   ctx->active[idx] = 0;
   if (active_out)
      *active_out = false;
   if (is_new_out)
      *is_new_out = true;
   return ctx->ids[idx];
}

//! @brief Handle fpctx set active logic for abi meta.
static void fpctx_set_active(FingerprintCtx *ctx, const char *name, bool active) {
   int idx = fpctx_find(ctx, name);
   if (idx >= 0)
      ctx->active[idx] = active ? 1 : 0;
}

//! @brief Return effective base type name data used by abi meta; returned pointers alias existing storage unless explicitly allocated by the function name.
static const char *effective_base_type_name(const ASTNode *type) {
   const char *name;
   const char *backing;

   if (!type)
      return NULL;
   name = type_name_from_node(type);
   backing = enum_backing_type_name(name);
   return backing ? backing : name;
}

//! @brief Return effective base type node data used by abi meta; returned pointers alias existing storage unless explicitly allocated by the function name.
static const ASTNode *effective_base_type_node(const ASTNode *type) {
   const char *name = effective_base_type_name(type);
   return name ? get_typename_node(name) : NULL;
}

static void append_type_fingerprint(StrBuf *fp, StrBuf *detail, const ASTNode *type, const ASTNode *declarator, FingerprintCtx *ctx);

//! @brief Add storage mode to abi meta state, growing storage or preserving uniqueness as needed.
static void append_storage_mode(StrBuf *fp, StrBuf *detail, const char *mode) {
   sb_appendf(fp, "mode=%s;", mode ? mode : "unknown");
   sb_appendf(detail, "%s ", mode ? mode : "unknown");
}

//! @brief Return parameter storage mode data used by abi meta; returned pointers alias existing storage unless explicitly allocated by the function name.
static const char *parameter_storage_mode(const ASTNode *parameter) {
   const ASTNode *mods = parameter_decl_specifiers(parameter);
   const ASTNode *modifiers = (mods && mods->count > 0) ? mods->children[0] : NULL;

   if (parameter_is_ref(parameter))
      return "ref";
   if (parameter_has_symbol_storage(parameter))
      return modifiers_imply_zeropage(modifiers) ? "symbol_zp" : "symbol_abs";
   return "stack_value";
}

//! @brief Return global storage mode data used by abi meta; returned pointers alias existing storage unless explicitly allocated by the function name.
static const char *global_storage_mode(const ASTNode *node, bool is_zeropage) {
   const ASTNode *modifiers = node && node->count > 0 ? node->children[0] : NULL;
   if (modifiers && has_modifier((ASTNode *)modifiers, "ref"))
      return "absolute_ref";
   return is_zeropage ? "zeropage" : "memory";
}

//! @brief Return array bound text data used by abi meta; returned pointers alias existing storage unless explicitly allocated by the function name.
static const char *array_bound_text(const ASTNode *declarator) {
   const ASTNode *value_decl = declarator_value_declarator(declarator);
   int start = declarator_suffix_start_index(value_decl ? value_decl : declarator);

   if (!value_decl)
      return NULL;

   for (int i = start; i < value_decl->count; i++) {
      const ASTNode *child = value_decl->children[i];
      if (child && child->kind == AST_INTEGER && child->strval)
         return child->strval;
   }
   return NULL;
}

//! @brief Add builtin pointer machine to abi meta state, growing storage or preserving uniqueness as needed.
static void append_builtin_pointer_machine(StrBuf *fp, StrBuf *detail) {
   const ASTNode *node = required_typename_node("*");
   int size = type_size_from_node(node);
   const char *endian = type_endian_name(node);
   const char *sign = type_is_signed_integer(node) ? "signed" : (type_is_unsigned_integer(node) ? "unsigned" : "plain");

   sb_appendf(fp, "ptrmach(sz=%d;sign=%s", size, sign);
   if (endian)
      sb_appendf(fp, ";end=%s", endian);
   sb_append(fp, ")");

   sb_appendf(detail, "pointer_machine(size=%d, %s", size, sign);
   if (endian)
      sb_appendf(detail, ", %s-endian", endian);
   sb_append(detail, ")");
}

//! @brief Add base type fingerprint to abi meta state, growing storage or preserving uniqueness as needed.
static void append_base_type_fingerprint(StrBuf *fp, StrBuf *detail, const ASTNode *type, FingerprintCtx *ctx) {
   const char *name = effective_base_type_name(type);
   const ASTNode *node = effective_base_type_node(type);
   int size;

   if (!name || !node) {
      sb_append(fp, "unknown");
      sb_append(detail, "unknown");
      return;
   }

   if (!strcmp(name, "*")) {
      append_builtin_pointer_machine(fp, detail);
      return;
   }

   size = type_size_from_node(node);

   if (!strcmp(node->name, "type_decl_stmt")) {
      const char *endian = type_endian_name(node);
      const char *float_style = type_float_style(node);
      bool is_float = type_is_float_like(node);
      bool is_signed = type_is_signed_integer(node);
      bool is_unsigned = type_is_unsigned_integer(node);
      bool exactops = has_flag(name, "$exactops");

      if (!strcmp(name, "void")) {
         sb_appendf(fp, "void(sz=%d", size);
         if (exactops)
            sb_append(fp, ";exactops=1");
         sb_append(fp, ")");

         sb_appendf(detail, "void(size=%d", size);
         if (exactops)
            sb_append(detail, ", exactops");
         sb_append(detail, ")");
         return;
      }

      if (is_float) {
         sb_appendf(fp, "float(sz=%d;style=%s", size, float_style ? float_style : "unknown");
         if (endian)
            sb_appendf(fp, ";end=%s", endian);
         sb_appendf(fp, ";exp=%d", type_float_expbits(node));
         if (exactops)
            sb_append(fp, ";exactops=1");
         sb_append(fp, ")");

         sb_appendf(detail, "float_like(size=%d, style=%s", size, float_style ? float_style : "unknown");
         if (endian)
            sb_appendf(detail, ", %s-endian", endian);
         sb_appendf(detail, ", expbits=%d", type_float_expbits(node));
         if (exactops)
            sb_append(detail, ", exactops");
         sb_append(detail, ")");
         return;
      }

      sb_appendf(fp, "scalar(sz=%d;kind=%s", size,
         is_signed ? "signed_int" : (is_unsigned ? "unsigned_int" : "plain"));
      if (endian)
         sb_appendf(fp, ";end=%s", endian);
      if (exactops)
         sb_append(fp, ";exactops=1");
      sb_append(fp, ")");

      sb_appendf(detail, "%s(size=%d",
         is_signed ? "signed_integer" : (is_unsigned ? "unsigned_integer" : "scalar"), size);
      if (endian)
         sb_appendf(detail, ", %s-endian", endian);
      if (exactops)
         sb_append(detail, ", exactops");
      sb_append(detail, ")");
      return;
   }

   if (!strcmp(node->name, "struct_decl_stmt") || !strcmp(node->name, "union_decl_stmt")) {
      bool was_active = false;
      bool is_new = false;
      bool is_union = !strcmp(node->name, "union_decl_stmt");
      int agg_id = fpctx_get_id(ctx, name, &was_active, &is_new);
      int bit_cursor = 0;

      if (was_active) {
         sb_appendf(fp, "ref#%d", agg_id);
         sb_appendf(detail, "ref#%d", agg_id);
         return;
      }

      fpctx_set_active(ctx, name, true);
      sb_appendf(fp, "%s#%d(sz=%d;members=[", is_union ? "union" : "struct", agg_id, size);
      sb_appendf(detail, "%s#%d(size=%d){", is_union ? "union" : "struct", agg_id, size);

      for (int i = 1; i < node->count; i++) {
         const ASTNode *field = node->children[i];
         const ASTNode *ftype;
         const ASTNode *fdecl;
         const char *fname;
         int fsize;
         int bit_width;
         int byte_offset;
         int bit_offset;
         int storage_size;
         StrBuf subfp;
         StrBuf subdetail;

         if (!field || field->count < 3)
            continue;

         ftype = field->children[1];
         fdecl = field->children[2];
         fname = declarator_name(fdecl);
         fsize = declarator_storage_size(ftype, fdecl);
         bit_width = declarator_bitfield_width(fdecl);

         if (is_union) {
            byte_offset = 0;
            bit_offset = 0;
         }
         else if (bit_width > 0) {
            byte_offset = bit_cursor / 8;
            bit_offset = bit_cursor % 8;
         }
         else {
            if (bit_cursor % 8)
               bit_cursor = ((bit_cursor + 7) / 8) * 8;
            byte_offset = bit_cursor / 8;
            bit_offset = 0;
         }

         storage_size = bit_width > 0 ? ((bit_offset + bit_width + 7) / 8) : fsize;

         sb_init(&subfp);
         sb_init(&subdetail);
         append_type_fingerprint(&subfp, &subdetail, ftype, fdecl, ctx);

         if (i > 1) {
            sb_append(fp, ",");
            sb_append(detail, "; ");
         }

         sb_appendf(fp, "off=%d", byte_offset);
         if (bit_width > 0)
            sb_appendf(fp, ".%d:w=%d:store=%d:", bit_offset, bit_width, storage_size);
         else
            sb_appendf(fp, ":store=%d:", storage_size);
         sb_append(fp, subfp.buf ? subfp.buf : "");

         if (fname && *fname)
            sb_appendf(detail, "%s ", fname);
         sb_appendf(detail, "@%d", byte_offset);
         if (bit_width > 0)
            sb_appendf(detail, ".%d bitfield(width=%d, storage=%d) ", bit_offset, bit_width, storage_size);
         else
            sb_appendf(detail, " storage=%d ", storage_size);
         sb_append(detail, subdetail.buf ? subdetail.buf : "");

         free(subfp.buf);
         free(subdetail.buf);

         if (!is_union) {
            if (bit_width > 0)
               bit_cursor += bit_width;
            else
               bit_cursor += fsize * 8;
         }
      }

      sb_append(fp, "])");
      sb_append(detail, "}");
      fpctx_set_active(ctx, name, false);
      (void)is_new;
      return;
   }

   sb_appendf(fp, "named(%s;sz=%d)", name, size);
   sb_appendf(detail, "named_type(%s,size=%d)", name, size);
}

//! @brief Add callable signature to abi meta state, growing storage or preserving uniqueness as needed.
static void append_callable_signature(StrBuf *fp, StrBuf *detail, const ASTNode *base_type, const ASTNode *callable_decl, FingerprintCtx *ctx) {
   const ASTNode *params = declarator_parameter_list(callable_decl);
   const ASTNode *ret_decl = function_return_declarator_from_callable(callable_decl);
   bool variadic = parameter_list_is_variadic(params);
   int fixed_count = 0;

   sb_append(fp, "fn(");
   sb_append(detail, "function(");

   sb_append(fp, "ret=");
   append_type_fingerprint(fp, detail, base_type, ret_decl, ctx);

   sb_appendf(fp, ";variadic=%d;params=[", variadic ? 1 : 0);
   sb_appendf(detail, ", variadic=%s, params=[", variadic ? "yes" : "no");

   if (params && !is_empty(params)) {
      for (int i = 0; i < params->count; i++) {
         const ASTNode *parameter = params->children[i];
         const ASTNode *ptype;
         const ASTNode *pdecl;
         const char *mode;
         StrBuf subfp;
         StrBuf subdetail;

         if (!parameter || parameter_is_void(parameter) || parameter_is_ellipsis(parameter))
            continue;

         ptype = parameter_type(parameter);
         pdecl = call_adjusted_parameter_declarator(parameter_declarator(parameter), parameter_is_ref(parameter));
         mode = parameter_storage_mode(parameter);
         fixed_count++;

         if (fixed_count > 1) {
            sb_append(fp, ",");
            sb_append(detail, "; ");
         }

         sb_init(&subfp);
         sb_init(&subdetail);
         append_type_fingerprint(&subfp, &subdetail, ptype, pdecl, ctx);

         sb_appendf(fp, "%s:", mode);
         sb_append(fp, subfp.buf ? subfp.buf : "");
         sb_appendf(detail, "%s ", mode);
         sb_append(detail, subdetail.buf ? subdetail.buf : "");

         free(subfp.buf);
         free(subdetail.buf);
      }
   }

   if (fixed_count == 0)
      sb_append(detail, "void");

   sb_append(fp, "])");
   sb_append(detail, "])");
}

//! @brief Add type fingerprint to abi meta state, growing storage or preserving uniqueness as needed.
static void append_type_fingerprint(StrBuf *fp, StrBuf *detail, const ASTNode *type, const ASTNode *declarator, FingerprintCtx *ctx) {
   const ASTNode *next_decl;
   const char *bound;

   if (declarator && declarator_has_parameter_list(declarator) && declarator_function_pointer_depth(declarator) > 0) {
      sb_append(fp, "fnptr(");
      sb_append(detail, "function_pointer(");
      append_builtin_pointer_machine(fp, detail);
      sb_append(fp, ";sig=");
      sb_append(detail, ", sig=");
      append_callable_signature(fp, detail, type, declarator, ctx);
      sb_append(fp, ")");
      sb_append(detail, ")");
      return;
   }

   if (declarator && declarator_pointer_depth(declarator) > 0) {
      next_decl = declarator_after_deref(declarator);
      sb_append(fp, "ptr(");
      sb_append(detail, "pointer(");
      append_builtin_pointer_machine(fp, detail);
      sb_append(fp, ";to=");
      sb_append(detail, ", to=");
      append_type_fingerprint(fp, detail, type, next_decl, ctx);
      sb_append(fp, ")");
      sb_append(detail, ")");
      return;
   }

   if (declarator && declarator_array_count(declarator) > 0) {
      next_decl = declarator_after_subscript(declarator);
      bound = array_bound_text(declarator);
      sb_appendf(fp, "array(n=%s;of=", bound ? bound : "?");
      sb_appendf(detail, "array[%s] of ", bound ? bound : "?");
      append_type_fingerprint(fp, detail, type, next_decl, ctx);
      sb_append(fp, ")");
      return;
   }

   append_base_type_fingerprint(fp, detail, type, ctx);
}

//! @brief Emit metadata symbol for abi meta diagnostics or output files.
static void emit_metadata_symbol(const char *kind, const char *state, const char *symbol,
                                 const char *role, const char *fingerprint, const char *detail) {
   char *enc_symbol = meta_encode(symbol ? symbol : "");
   char *enc_fp = meta_encode(fingerprint ? fingerprint : "");
   char *enc_detail = meta_encode(detail ? detail : "");
   StrBuf name;

   sb_init(&name);
   sb_append(&name, ABI_META_PREFIX);
   sb_append(&name, kind ? kind : "unknown");
   sb_append_ch(&name, '$');
   sb_append(&name, state ? state : "unknown");
   sb_append_ch(&name, '$');
   sb_append(&name, enc_symbol);
   sb_append_ch(&name, '$');
   sb_append(&name, role ? role : "unknown");
   sb_append_ch(&name, '$');
   sb_append(&name, enc_fp);
   sb_append_ch(&name, '$');
   sb_append(&name, enc_detail);

   if (!abi_metadata_symbols)
      abi_metadata_symbols = new_set();
   if (!set_get(abi_metadata_symbols, name.buf)) {
      set_add(abi_metadata_symbols, strdup(name.buf), (void *)1);
      emit(&es_export, ".export %s\n", name.buf);
      emit(&es_export, "%s = 0\n", name.buf);
   }

   free(enc_symbol);
   free(enc_fp);
   free(enc_detail);
   free(name.buf);
}

//! @brief Emit type record for abi meta diagnostics or output files.
static void emit_type_record(const char *kind, const char *state, const char *symbol,
                             const char *role, const char *mode, const ASTNode *type,
                             const ASTNode *declarator) {
   StrBuf fp;
   StrBuf detail;
   FingerprintCtx ctx;

   memset(&ctx, 0, sizeof(ctx));
   sb_init(&fp);
   sb_init(&detail);
   append_storage_mode(&fp, &detail, mode);
   append_type_fingerprint(&fp, &detail, type, declarator, &ctx);
   emit_metadata_symbol(kind, state, symbol, role, fp.buf ? fp.buf : "", detail.buf ? detail.buf : "");

   free(ctx.names);
   free(ctx.ids);
   free(ctx.active);
   free(fp.buf);
   free(detail.buf);
}

//! @brief Emit function ABI metadata for abi meta diagnostics or output files.
void emit_function_abi_metadata(const ASTNode *fn, const char *sym, bool is_definition) {
   const ASTNode *decl = function_declarator_node(fn);
   const ASTNode *params = declarator_parameter_list(decl);
   const ASTNode *ret_type = function_return_type(fn);
   const ASTNode *ret_decl = function_return_declarator_from_callable(decl);
   const char *state = is_definition ? "definition" : "declaration";
   int fixed_count = function_fixed_param_count(fn);
   bool variadic = function_is_variadic(fn);
   char summary_fp[64];
   char summary_detail[64];

   if (!sym || !*sym || !decl)
      return;

   snprintf(summary_fp, sizeof(summary_fp), "params=%d;variadic=%d", fixed_count, variadic ? 1 : 0);
   snprintf(summary_detail, sizeof(summary_detail), "parameters=%d variadic=%s", fixed_count, variadic ? "yes" : "no");
   emit_metadata_symbol("function", state, sym, "summary", summary_fp, summary_detail);
   emit_type_record("function", state, sym, "return", "return_value", ret_type, ret_decl);

   if (params && !is_empty(params)) {
      int out_index = 0;
      for (int i = 0; i < params->count; i++) {
         const ASTNode *parameter = params->children[i];
         const ASTNode *ptype;
         const ASTNode *pdecl;
         const char *mode;
         char role[32];

         if (!parameter || parameter_is_void(parameter) || parameter_is_ellipsis(parameter))
            continue;

         ptype = parameter_type(parameter);
         pdecl = call_adjusted_parameter_declarator(parameter_declarator(parameter), parameter_is_ref(parameter));
         mode = parameter_storage_mode(parameter);
         snprintf(role, sizeof(role), "param%d", out_index++);
         emit_type_record("function", state, sym, role, mode, ptype, pdecl);
      }
   }
}

//! @brief Emit global ABI metadata for abi meta diagnostics or output files.
void emit_global_abi_metadata(const ASTNode *node, const char *symname, bool is_definition, bool is_zeropage) {
   const ASTNode *type;
   const ASTNode *declarator;
   const char *state = is_definition ? "definition" : "declaration";
   const char *mode;

   if (!node || node->count < 3 || !symname || !*symname)
      return;

   type = node->children[1];
   declarator = node->children[2] && !strcmp(node->children[2]->name, "decl_subitem")
      ? node->children[2]->children[0]
      : node->children[2];
   mode = global_storage_mode(node, is_zeropage);
   emit_type_record("global", state, symname, "object", mode, type, declarator);
}
