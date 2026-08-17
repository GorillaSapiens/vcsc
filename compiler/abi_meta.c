//! @file compiler/abi_meta.c
//! @brief Implements ABI metadata emission for the VCSC compiler.
//! @ingroup compiler

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <stdbool.h>
#include <ctype.h>

#include "abi_meta.h"
#include "compile_declarator.h"
#include "compile_function.h"
#include "compile_internal.h"
#include "compile_function_registry.h"
#include "compile_type.h"
#include "emit.h"
#include "messages.h"
#include "lextern.h"
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

static void append_type_fingerprint(StrBuf *fp, StrBuf *detail, const ASTNode *type,
                                    const ASTNode *declarator,
                                    PointerAccessQualifier pointer_access,
                                    FingerprintCtx *ctx);

//! @brief Add storage mode to abi meta state, growing storage or preserving uniqueness as needed.
static void append_storage_mode(StrBuf *fp, StrBuf *detail, const char *mode) {
   sb_appendf(fp, "mode=%s;", mode ? mode : "unknown");
   sb_appendf(detail, "%s ", mode ? mode : "unknown");
}

//! @brief Format the complete symbol-storage ABI mode for one value parameter.
static void function_parameter_storage_mode(const ASTNode *parameter,
                                            char *buf, size_t buf_size) {
   const ASTNode *mods = parameter_decl_specifiers(parameter);
   const ASTNode *modifiers = (mods && mods->count > 0) ? mods->children[0] : NULL;
   const char *memname = find_mem_modifier_name(modifiers);
   unsigned int read_start = 0;
   unsigned int write_start = 0;

   if (!buf || buf_size == 0)
      return;
   if (parameter_is_ref(parameter)) {
      snprintf(buf, buf_size, "ref(access=%s)",
               pointer_access_qualifier_name(parameter_access_qualifier(parameter)));
      return;
   }
   if (mem_decl_split_addresses(find_mem_modifier_node(modifiers),
                                &read_start, &write_start)) {
      snprintf(buf, buf_size, "symbol_split(region=%s,read=%04X,write=%04X)",
               memname ? memname : "?", read_start, write_start);
      return;
   }
   if (memname) {
      snprintf(buf, buf_size, "%s(region=%s)",
               modifiers_imply_zeropage(modifiers) ? "symbol_zp" : "symbol_abs",
               memname);
      return;
   }
   snprintf(buf, buf_size, "%s",
            modifiers_imply_zeropage(modifiers) ? "symbol_zp" : "symbol_abs");
}

//! @brief Format the complete hidden-result storage ABI mode for one function.
static void function_return_storage_mode(const ASTNode *fn, char *buf, size_t buf_size) {
   const ASTNode *ret_type = function_return_type(fn);
   const ASTNode *ret_decl = function_return_declarator_from_callable(function_declarator_node(fn));
   const char *memname = function_result_region_name(fn);
   const ASTNode *mem_decl = function_result_region_node(fn);
   unsigned int read_start = 0;
   unsigned int write_start = 0;

   if (!buf || buf_size == 0) {
      return;
   }
   if (return_type_is_void(ret_type, ret_decl)) {
      snprintf(buf, buf_size, "return_void");
      return;
   }
   if (mem_decl_split_addresses(mem_decl, &read_start, &write_start)) {
      snprintf(buf, buf_size, "return_split(region=%s,read=%04X,write=%04X)",
               memname ? memname : "?", read_start, write_start);
      return;
   }
   if (memname) {
      snprintf(buf, buf_size, "return_region(region=%s,address=%s)",
               memname, mem_decl_is_zeropage(mem_decl) ? "zeropage" : "absolute");
      return;
   }
   snprintf(buf, buf_size, "return_memory");
}

//! @brief Compare region-name pointers by their source spelling.
static int compare_region_names(const void *a, const void *b) {
   const char *const *aname = (const char *const *)a;
   const char *const *bname = (const char *const *)b;
   return strcmp(*aname, *bname);
}

//! @brief Format the order-insensitive code-region set of one function.
static void function_code_region_mode(const ASTNode *fn, char *fp_buf, size_t fp_size,
                                      char *detail_buf, size_t detail_size) {
   FunctionRegionSpec spec;
   StrBuf fp;
   StrBuf detail;
   char *fp_text;
   char *detail_text;

   if (!fp_buf || fp_size == 0 || !detail_buf || detail_size == 0) {
      return;
   }
   sb_init(&fp);
   sb_init(&detail);
   function_region_spec_collect(fn, &spec);
   if (spec.code_region_count > 1) {
      qsort(spec.code_regions, spec.code_region_count, sizeof(*spec.code_regions),
            compare_region_names);
   }
   sb_append(&fp, "regions=[");
   sb_append(&detail, "code regions [");
   for (size_t i = 0; i < spec.code_region_count; i++) {
      sb_appendf(&fp, "%s%s", i ? "," : "", spec.code_regions[i]);
      sb_appendf(&detail, "%s%s", i ? ", " : "", spec.code_regions[i]);
   }
   sb_append(&fp, "]");
   sb_append(&detail, "]");
   fp_text = sb_take(&fp);
   detail_text = sb_take(&detail);
   snprintf(fp_buf, fp_size, "%s", fp_text);
   snprintf(detail_buf, detail_size, "%s", detail_text);
   free(fp_text);
   free(detail_text);
   function_region_spec_release(&spec);
}

//! @brief Return one declaration item's absolute address specification, if any.
static const ASTNode *global_address_spec(const ASTNode *node) {
   const ASTNode *subitem;

   if (!node || node->count < 3)
      return NULL;
   subitem = node->children[2];
   if (!subitem || strcmp(subitem->name, "decl_subitem") || subitem->count < 2)
      return NULL;
   return subitem->children[1];
}

//! @brief Return one read/write address term as source text, or none.
static const char *abi_address_term(const ASTNode *spec, int index) {
   if (!spec || is_empty(spec))
      return NULL;
   if (!strcmp(spec->name, "rw_addr_spec")) {
      if (index < 0 || index >= spec->count || !spec->children[index] ||
          is_empty(spec->children[index]))
         return NULL;
      return spec->children[index]->strval;
   }
   return spec->strval;
}

//! @brief Canonicalize one absolute address term for ABI fingerprints.
static void format_abi_address_term(char *buf, size_t buf_size, const char *text) {
   char *end = NULL;
   unsigned long long value;

   if (!buf || buf_size == 0)
      return;
   if (!text) {
      snprintf(buf, buf_size, "none");
      return;
   }
   value = strtoull(text, &end, 0);
   if (end && *end == '\0' && value <= 0xFFFFull) {
      snprintf(buf, buf_size, "0x%04llX", value);
      return;
   }
   snprintf(buf, buf_size, "%s", text);
}

//! @brief Format the storage ABI mode for a file-scope object or absolute binding.
static void global_storage_mode(const ASTNode *node, bool is_zeropage,
                                char *buf, size_t buf_size) {
   const ASTNode *spec = global_address_spec(node);
   char read_expr[96];
   char write_expr[96];

   if (!buf || buf_size == 0)
      return;
   if (!spec) {
      MemRegionSet regions;
      size_t used;
      mem_region_set_collect(node && node->count > 0 ? node->children[0] : NULL,
                             &regions);
      mem_region_set_sort(&regions);
      if (regions.count > 1) {
         used = (size_t)snprintf(buf, buf_size, "replicated_ro(regions=[");
         for (size_t i = 0; i < regions.count && used < buf_size; ++i) {
            int wrote = snprintf(buf + used, buf_size - used, "%s%s",
                                 i ? "," : "", regions.names[i]);
            if (wrote < 0)
               break;
            used += (size_t)wrote;
         }
         if (used < buf_size)
            snprintf(buf + used, buf_size - used, "])");
         mem_region_set_release(&regions);
         return;
      }
      mem_region_set_release(&regions);
      snprintf(buf, buf_size, "%s", is_zeropage ? "zeropage" : "memory");
      return;
   }
   format_abi_address_term(read_expr, sizeof(read_expr), abi_address_term(spec, 0));
   format_abi_address_term(write_expr, sizeof(write_expr), abi_address_term(spec, 1));
   snprintf(buf, buf_size, "absolute_binding(read=%s,write=%s)", read_expr, write_expr);
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
   const char *sign = type_is_signed_integer(node) ? "signed" : (type_is_unsigned_integer(node) ? "unsigned" : "plain");

   sb_appendf(fp, "ptrmach(sz=%d;sign=%s)", size, sign);
   sb_appendf(detail, "pointer_machine(size=%d, %s, little-endian)", size, sign);
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
      bool is_signed = type_is_signed_integer(node);
      bool is_unsigned = type_is_unsigned_integer(node);
      bool is_bcd = type_is_bcd_integer(node);

      if (!strcmp(name, "void")) {
         sb_appendf(fp, "void(sz=%d", size);
         sb_append(fp, ")");

         sb_appendf(detail, "void(size=%d", size);
         sb_append(detail, ")");
         return;
      }

      sb_appendf(fp, "scalar(sz=%d;kind=%s)", size,
         is_bcd ? "packed_bcd" :
         (is_signed ? "signed_int" : (is_unsigned ? "unsigned_int" : "plain")));

      sb_appendf(detail, "%s(size=%d%s)",
         is_bcd ? "packed_bcd_integer" :
         (is_signed ? "signed_integer" : (is_unsigned ? "unsigned_integer" : "scalar")), size,
         size > 1 ? ", little-endian" : "");
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
         {
            const ASTNode *fmods = (field->count > 0) ? field->children[0] : NULL;
            append_type_fingerprint(&subfp, &subdetail, ftype, fdecl,
                                    declaration_pointer_access(fmods, fdecl), ctx);
         }

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

//! @brief Add type fingerprint to abi meta state, growing storage or preserving uniqueness as needed.
static void append_type_fingerprint(StrBuf *fp, StrBuf *detail, const ASTNode *type,
                                    const ASTNode *declarator,
                                    PointerAccessQualifier pointer_access,
                                    FingerprintCtx *ctx) {
   const ASTNode *next_decl;
   const char *bound;

   if (declarator && declarator_pointer_depth(declarator) > 0) {
      next_decl = declarator_after_deref(declarator);
      sb_appendf(fp, "ptr(access=%s;", pointer_access_qualifier_name(pointer_access));
      sb_appendf(detail, "%s pointer(", pointer_access_qualifier_name(pointer_access));
      append_builtin_pointer_machine(fp, detail);
      sb_append(fp, ";to=");
      sb_append(detail, ", to=");
      append_type_fingerprint(fp, detail, type, next_decl,
                              POINTER_ACCESS_READWRITE, ctx);
      sb_append(fp, ")");
      sb_append(detail, ")");
      return;
   }

   if (declarator && declarator_array_count(declarator) > 0) {
      next_decl = declarator_after_subscript(declarator);
      bound = array_bound_text(declarator);
      sb_appendf(fp, "array(n=%s;of=", bound ? bound : "?");
      sb_appendf(detail, "array[%s] of ", bound ? bound : "?");
      append_type_fingerprint(fp, detail, type, next_decl, pointer_access, ctx);
      sb_append(fp, ")");
      return;
   }

   append_base_type_fingerprint(fp, detail, type, ctx);
}

//! @brief Emit one linker-visible replication record for a logical symbol and ROM region.
void emit_replica_metadata(char kind, const char *symbol, const char *region) {
   char *enc_symbol;
   char *enc_region;
   StrBuf name;

   if ((kind != 'F' && kind != 'O') || !symbol || !*symbol || !region || !*region) {
      return;
   }
   enc_symbol = meta_encode(symbol);
   enc_region = meta_encode(region);
   sb_init(&name);
   sb_append(&name, REPLICA_META_PREFIX);
   sb_append_ch(&name, kind);
   sb_append_ch(&name, '$');
   sb_append(&name, enc_symbol);
   sb_append_ch(&name, '$');
   sb_append(&name, enc_region);

   if (!abi_metadata_symbols)
      abi_metadata_symbols = new_set();
   if (!set_get(abi_metadata_symbols, name.buf)) {
      set_add(abi_metadata_symbols, strdup(name.buf), (void *)1);
      emit(&es_export, ".export %s\n", name.buf);
      emit(&es_export, "%s = 0\n", name.buf);
   }

   free(enc_symbol);
   free(enc_region);
   free(name.buf);
}


//! @brief Export and return one linker-visible label for a coalesced return object.
char *emit_return_coalesce_metadata(const char *function_symbol,
                                    const char *local_name,
                                    const char *return_symbol,
                                    const char *region_name, int size) {
   char *enc_function;
   char *enc_local;
   char *enc_return;
   char *enc_region;
   StrBuf name;

   if (!function_symbol || !*function_symbol || !local_name || !*local_name ||
       !return_symbol || !*return_symbol || size <= 0) {
      return NULL;
   }
   enc_function = meta_encode(function_symbol);
   enc_local = meta_encode(local_name);
   enc_return = meta_encode(return_symbol);
   enc_region = meta_encode(region_name ? region_name : "");
   sb_init(&name);
   sb_append(&name, RETURN_COALESCE_META_PREFIX);
   sb_append(&name, enc_function);
   sb_append_ch(&name, '$');
   sb_append(&name, enc_local);
   sb_append_ch(&name, '$');
   sb_append(&name, enc_return);
   sb_append_ch(&name, '$');
   sb_append(&name, enc_region);
   sb_appendf(&name, "$%d", size);

   if (!abi_metadata_symbols)
      abi_metadata_symbols = new_set();
   if (!set_get(abi_metadata_symbols, name.buf)) {
      set_add(abi_metadata_symbols, strdup(name.buf), (void *)1);
      emit(&es_export, ".export %s\n", name.buf);
   }

   free(enc_function);
   free(enc_local);
   free(enc_return);
   free(enc_region);
   return name.buf;
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

//! @brief Emit one linker-visible absolute-binding range record for MEMORY overlap validation.
void emit_absolute_binding_region_guard_metadata(const ASTNode *node,
                                                 const char *name,
                                                 const char *read_expr,
                                                 const char *write_expr,
                                                 int size) {
   char read_buf[96];
   char write_buf[96];
   StrBuf identity;
   StrBuf fingerprint;
   StrBuf detail;

   format_abi_address_term(read_buf, sizeof(read_buf), read_expr);
   format_abi_address_term(write_buf, sizeof(write_buf), write_expr);

   sb_init(&identity);
   sb_appendf(&identity, "%s@%s:%d:%d",
              name ? name : "<unnamed>",
              node && node->file ? node->file : "?",
              node ? node->line : 0,
              node ? node->column : 0);

   sb_init(&fingerprint);
   sb_appendf(&fingerprint, "read=%s,write=%s,size=%d",
              read_buf, write_buf, size);

   sb_init(&detail);
   sb_appendf(&detail,
              "absolute external binding '%s' declared at %s:%d.%d (read=%s, write=%s, size=%d)",
              name ? name : "<unnamed>",
              node && node->file ? node->file : "?",
              node ? node->line : 0,
              node ? node->column : 0,
              read_buf, write_buf, size);

   emit_metadata_symbol("absolute_binding", "binding", identity.buf,
                        "region_guard", fingerprint.buf, detail.buf);

   free(identity.buf);
   free(fingerprint.buf);
   free(detail.buf);
}

//! @brief Emit type record for abi meta diagnostics or output files.
static void emit_type_record(const char *kind, const char *state, const char *symbol,
                             const char *role, const char *mode, const ASTNode *type,
                             const ASTNode *declarator, const ASTNode *modifiers) {
   StrBuf fp;
   StrBuf detail;
   FingerprintCtx ctx;

   memset(&ctx, 0, sizeof(ctx));
   sb_init(&fp);
   sb_init(&detail);
   append_storage_mode(&fp, &detail, mode);
   append_type_fingerprint(&fp, &detail, type, declarator,
                           declaration_pointer_access(modifiers, declarator), &ctx);
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
   char summary_fp[64];
   char summary_detail[64];

   if (!sym || !*sym || !decl)
      return;

   snprintf(summary_fp, sizeof(summary_fp), "params=%d", fixed_count);
   snprintf(summary_detail, sizeof(summary_detail), "parameters=%d", fixed_count);
   emit_metadata_symbol("function", state, sym, "summary", summary_fp, summary_detail);
   {
      char code_fp[512];
      char code_detail[512];
      function_code_region_mode(fn, code_fp, sizeof(code_fp),
                                code_detail, sizeof(code_detail));
      emit_metadata_symbol("function", state, sym, "code_regions",
                           code_fp, code_detail);
   }
   {
      char return_mode[256];
      function_return_storage_mode(fn, return_mode, sizeof(return_mode));
      emit_type_record("function", state, sym, "return",
                       return_mode, ret_type, ret_decl, function_modifiers_node(fn));
   }

   if (params && !is_empty(params)) {
      int out_index = 0;
      for (int i = 0; i < params->count; i++) {
         const ASTNode *parameter = params->children[i];
         const ASTNode *ptype;
         const ASTNode *pdecl;
         char mode[256];
         char role[32];

         if (!parameter || parameter_is_void(parameter))
            continue;

         ptype = parameter_type(parameter);
         pdecl = call_adjusted_parameter_declarator(parameter_declarator(parameter), parameter_is_ref(parameter));
         function_parameter_storage_mode(parameter, mode, sizeof(mode));
         snprintf(role, sizeof(role), "param%d", out_index++);
         {
            const ASTNode *specs = parameter_decl_specifiers(parameter);
            const ASTNode *mods = (specs && specs->count > 0) ? specs->children[0] : NULL;
            emit_type_record("function", state, sym, role, mode, ptype, pdecl, mods);
         }
      }
   }
}

//! @brief Emit global ABI metadata for abi meta diagnostics or output files.
void emit_global_abi_metadata(const ASTNode *node, const char *symname, bool is_definition, bool is_zeropage) {
   const ASTNode *type;
   const ASTNode *declarator;
   const char *state = is_definition ? "definition" : "declaration";
   char mode[256];

   if (!node || node->count < 3 || !symname || !*symname)
      return;

   type = node->children[1];
   declarator = node->children[2] && !strcmp(node->children[2]->name, "decl_subitem")
      ? node->children[2]->children[0]
      : node->children[2];
   global_storage_mode(node, is_zeropage, mode, sizeof(mode));
   emit_type_record("global", state, symname, "object", mode, type, declarator,
                    node->children[0]);
}


//! @brief Append one complete canonical function signature for use-contract metadata.
static void append_function_contract_fingerprint(StrBuf *fp, StrBuf *detail,
                                                 const ASTNode *fn) {
   const ASTNode *decl = function_declarator_node(fn);
   const ASTNode *params = declarator_parameter_list(decl);
   const ASTNode *ret_type = function_return_type(fn);
   const ASTNode *ret_decl = function_return_declarator_from_callable(decl);
   FingerprintCtx ctx;
   int fixed_count = function_fixed_param_count(fn);
   int out_index = 0;

   memset(&ctx, 0, sizeof(ctx));
   sb_appendf(fp, "function(params=%d;", fixed_count);
   sb_appendf(detail, "function(parameters=%d, ", fixed_count);
   {
      char code_fp[512];
      char code_detail[512];
      function_code_region_mode(fn, code_fp, sizeof(code_fp),
                                code_detail, sizeof(code_detail));
      sb_appendf(fp, "code_%s;return=", code_fp);
      sb_appendf(detail, "%s, return=", code_detail);
   }
   {
      char return_mode[256];
      function_return_storage_mode(fn, return_mode, sizeof(return_mode));
      append_storage_mode(fp, detail, return_mode);
   }
   append_type_fingerprint(fp, detail, ret_type, ret_decl,
                           declaration_pointer_access(function_modifiers_node(fn), ret_decl), &ctx);

   if (params && !is_empty(params)) {
      for (int i = 0; i < params->count; i++) {
         const ASTNode *parameter = params->children[i];
         const ASTNode *ptype;
         const ASTNode *pdecl;
         char mode[256];

         if (!parameter || parameter_is_void(parameter))
            continue;
         ptype = parameter_type(parameter);
         pdecl = call_adjusted_parameter_declarator(parameter_declarator(parameter),
                                                    parameter_is_ref(parameter));
         sb_appendf(fp, ";param%d=", out_index);
         sb_appendf(detail, ", param%d=", out_index);
         function_parameter_storage_mode(parameter, mode, sizeof(mode));
         append_storage_mode(fp, detail, mode);
         {
            const ASTNode *specs = parameter_decl_specifiers(parameter);
            const ASTNode *mods = (specs && specs->count > 0) ? specs->children[0] : NULL;
            append_type_fingerprint(fp, detail, ptype, pdecl,
                                    declaration_pointer_access(mods, pdecl), &ctx);
         }
         out_index++;
      }
   }
   sb_append(fp, ")");
   sb_append(detail, ")");
   free(ctx.names);
   free(ctx.ids);
   free(ctx.active);
}

//! @brief Find template ownership attached to a node or one of its source-token descendants.
static const ASTNode *template_context_node(const ASTNode *node) {
   if (!node)
      return NULL;
   if (node->template_instance && *node->template_instance)
      return node;
   for (int i = 0; i < node->count; i++) {
      const ASTNode *found = template_context_node(node->children[i]);
      if (found)
         return found;
   }
   return NULL;
}

//! @brief Build one stable template invocation identity for linker contract ownership.
static char *template_invocation_identity(const ASTNode *node) {
   const ASTNode *ctx = template_context_node(node);
   StrBuf id;

   if (!ctx)
      return strdup("none");
   sb_init(&id);
   sb_append(&id, ctx->template_instance);
   sb_append_ch(&id, '@');
   sb_append(&id, ctx->template_invoke_file ? ctx->template_invoke_file : "?");
   sb_appendf(&id, ":%d:%d", ctx->template_invoke_line,
              ctx->template_invoke_column);
   return sb_take(&id);
}

//! @brief Emit one linker-visible declaration-use contract record.
static void emit_contract_metadata_symbol(const char *kind,
                                          DeclarationUseContract strength,
                                          const char *symbol,
                                          const ASTNode *origin,
                                          const ASTNode *context_node,
                                          const char *fingerprint,
                                          const char *detail) {
   const char *strength_name = strength == DECL_USE_CONTRACT_REQUIRE
      ? "require" : "recommend";
   const char *owner = root_filename && *root_filename ? root_filename
      : (origin && origin->file ? origin->file : "?");
   const char *file = origin && origin->file ? origin->file : owner;
   int line = origin ? origin->line : 0;
   int column = origin ? origin->column : 0;
   char *enc_symbol = meta_encode(symbol ? symbol : "");
   char *enc_owner = meta_encode(owner);
   char *invoke = template_invocation_identity(context_node);
   char *enc_file = meta_encode(file);
   char *enc_invoke = meta_encode(invoke);
   char *enc_fp = meta_encode(fingerprint ? fingerprint : "");
   char *enc_detail = meta_encode(detail ? detail : "");
   StrBuf name;

   sb_init(&name);
   sb_append(&name, CONTRACT_META_PREFIX);
   sb_append(&name, kind ? kind : "unknown");
   sb_append_ch(&name, '$');
   sb_append(&name, strength_name);
   sb_append_ch(&name, '$');
   sb_append(&name, enc_symbol);
   sb_append(&name, "$owner$");
   sb_append(&name, enc_owner);
   sb_append(&name, "$decl$");
   sb_append(&name, enc_file);
   sb_appendf(&name, "$L%d$C%d$invoke$", line, column);
   sb_append(&name, enc_invoke);
   sb_append(&name, "$type$");
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
   free(enc_owner);
   free(enc_file);
   free(enc_invoke);
   free(invoke);
   free(enc_fp);
   free(enc_detail);
   free(name.buf);
}

//! @brief Emit merged function use-contract metadata, including true inline definitions.
void emit_function_contract_metadata(const ASTNode *fn, const char *sym) {
   const ASTNode *origin = NULL;
   const ASTNode *decl = function_declarator_node(fn);
   const char *name = decl ? declarator_name(decl) : NULL;
   DeclarationUseContract strength;
   StrBuf fp;
   StrBuf detail;

   if (!fn || !sym || !*sym || !name)
      return;
   strength = declaration_symbol_use_contract(DECL_CONTRACT_FUNCTION, name, &origin);
   if (strength == DECL_USE_CONTRACT_NONE)
      return;
   if (!origin)
      origin = fn;

   sb_init(&fp);
   sb_init(&detail);
   append_function_contract_fingerprint(&fp, &detail, fn);
   emit_contract_metadata_symbol("function", strength, sym, origin, fn,
                                 fp.buf ? fp.buf : "", detail.buf ? detail.buf : "");
   free(fp.buf);
   free(detail.buf);
}

//! @brief Return the source spelling of a declared base type for user diagnostics.
static const char *contract_source_type_name(const ASTNode *type) {
   if (!type)
      return NULL;
   if (type->strval && *type->strval)
      return type->strval;
   if (type->count > 0 && type->children[0] &&
       type->children[0]->strval && *type->children[0]->strval)
      return type->children[0]->strval;
   return NULL;
}

//! @brief Append a source-like object type for declaration-contract diagnostics.
static void append_contract_object_display_type(StrBuf *detail,
                                                 const ASTNode *type,
                                                 const ASTNode *declarator) {
   const char *name = contract_source_type_name(type);
   const char *bound = array_bound_text(declarator);
   int pointers = declarator_pointer_depth(declarator);

   sb_append(detail, name ? name : "unknown");
   while (pointers-- > 0)
      sb_append_ch(detail, '*');
   if (declarator_array_count(declarator) > 0) {
      sb_append_ch(detail, '[');
      if (bound)
         sb_append(detail, bound);
      sb_append_ch(detail, ']');
   }
}

//! @brief Emit merged object use-contract metadata with its canonical object type.
void emit_global_contract_metadata(const ASTNode *node, const char *symname,
                                   bool is_zeropage) {
   const ASTNode *origin = NULL;
   const ASTNode *type;
   const ASTNode *declarator;
   const char *name;
   DeclarationUseContract strength;
   FingerprintCtx ctx;
   StrBuf fp;
   StrBuf abi_detail;
   StrBuf detail;
   char mode[256];

   if (!node || node->count < 3 || !symname || !*symname)
      return;
   type = node->children[1];
   declarator = node->children[2] && !strcmp(node->children[2]->name, "decl_subitem")
      ? node->children[2]->children[0] : node->children[2];
   name = declarator_name(declarator);
   if (!name)
      return;
   strength = declaration_symbol_use_contract(DECL_CONTRACT_OBJECT, name, &origin);
   if (strength == DECL_USE_CONTRACT_NONE)
      return;
   if (!origin)
      origin = node;

   memset(&ctx, 0, sizeof(ctx));
   sb_init(&fp);
   sb_init(&abi_detail);
   sb_init(&detail);
   global_storage_mode(node, is_zeropage, mode, sizeof(mode));
   append_storage_mode(&fp, &abi_detail, mode);
   append_type_fingerprint(&fp, &abi_detail, type, declarator,
                           declaration_pointer_access(node->children[0], declarator), &ctx);
   append_contract_object_display_type(&detail, type, declarator);
   emit_contract_metadata_symbol("object", strength, symname, origin, node,
                                 fp.buf ? fp.buf : "", detail.buf ? detail.buf : "");
   free(ctx.names);
   free(ctx.ids);
   free(ctx.active);
   free(fp.buf);
   free(abi_detail.buf);
   free(detail.buf);
}


//! @brief Emit one semantic-use record that survives optimization and inlining.
void emit_semantic_use_metadata(const char *kind, const char *symbol,
                                const char *containing_function,
                                const ASTNode *use_site) {
   const char *owner = root_filename && *root_filename ? root_filename
      : (use_site && use_site->file ? use_site->file : "?");
   const char *file = use_site && use_site->file ? use_site->file : owner;
   int line = use_site ? use_site->line : 0;
   int column = use_site ? use_site->column : 0;
   char *enc_kind;
   char *enc_symbol;
   char *enc_owner;
   char *enc_function;
   char *enc_file;
   char *invoke;
   char *enc_invoke;
   StrBuf name;

   if (!kind || !*kind || !symbol || !*symbol)
      return;

   enc_kind = meta_encode(kind);
   enc_symbol = meta_encode(symbol);
   enc_owner = meta_encode(owner);
   enc_function = meta_encode(containing_function && *containing_function
      ? containing_function : "none");
   enc_file = meta_encode(file);
   invoke = template_invocation_identity(use_site);
   enc_invoke = meta_encode(invoke);

   sb_init(&name);
   sb_append(&name, SEMANTIC_USE_META_PREFIX);
   sb_append(&name, enc_kind);
   sb_append_ch(&name, '$');
   sb_append(&name, enc_symbol);
   sb_append(&name, "$owner$");
   sb_append(&name, enc_owner);
   sb_append(&name, "$function$");
   sb_append(&name, enc_function);
   sb_append(&name, "$use$");
   sb_append(&name, enc_file);
   sb_appendf(&name, "$L%d$C%d$invoke$", line, column);
   sb_append(&name, enc_invoke);

   if (!abi_metadata_symbols)
      abi_metadata_symbols = new_set();
   if (!set_get(abi_metadata_symbols, name.buf)) {
      set_add(abi_metadata_symbols, strdup(name.buf), (void *)1);
      emit(&es_export, ".export %s\n", name.buf);
      emit(&es_export, "%s = 0\n", name.buf);
   }

   free(enc_kind);
   free(enc_symbol);
   free(enc_owner);
   free(enc_function);
   free(enc_file);
   free(enc_invoke);
   free(invoke);
   free(name.buf);
}

//! @brief Emit one deduplicated writable-object frame-phase use record.
void emit_phase_use_metadata(const char *symbol, uint8_t phase_mask) {
   StrBuf name;

   if (!symbol || !*symbol)
      return;

   sb_init(&name);
   sb_append(&name, PHASE_USE_META_PREFIX);
   sb_appendf(&name, "M%02X$", (unsigned)(phase_mask & 0x0Fu));
   sb_append(&name, symbol);

   if (!abi_metadata_symbols)
      abi_metadata_symbols = new_set();
   if (!set_get(abi_metadata_symbols, name.buf)) {
      set_add(abi_metadata_symbols, strdup(name.buf), (void *)1);
      emit(&es_export, ".export %s\n", name.buf);
      emit(&es_export, "%s = 0\n", name.buf);
   }
   free(name.buf);
}

//! @brief Mark one writable object as explicitly disposable outside its inferred frame-phase lifetime.
void emit_phase_workspace_metadata(const char *symbol) {
   StrBuf name;

   if (!symbol || !*symbol)
      return;
   sb_init(&name);
   sb_append(&name, PHASE_WORKSPACE_META_PREFIX);
   sb_append(&name, symbol);
   if (!abi_metadata_symbols)
      abi_metadata_symbols = new_set();
   if (!set_get(abi_metadata_symbols, name.buf)) {
      set_add(abi_metadata_symbols, strdup(name.buf), (void *)1);
      emit(&es_export, ".export %s\n", name.buf);
      emit(&es_export, "%s = 0\n", name.buf);
   }
   free(name.buf);
}
