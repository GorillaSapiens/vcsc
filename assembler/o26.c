//! @file assembler/o26.c
//! @brief Implements o26 object file emission for the VCSC assembler.
//! @ingroup assembler

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <stdarg.h>

#include "o26.h"
#include "util.h"

symbol_t *find_declared_symbol(symtab_t *tab, const program_ir_t *prog, const stmt_t *stmt, const char *name);

#define O26_SEG_UNDEF 0
#define O26_SEG_ABS   1
#define O26_SEG_TEXT  2
#define O26_SEG_DATA  3
#define O26_SEG_BSS   4
#define O26_SEG_ZP    5

#define O26_RTYPE_LOW  0x20
#define O26_RTYPE_HIGH 0x40
#define O26_RTYPE_WORD 0x80
#define O26_RTYPE_AUX  0x10
#define O26_RTYPE_INDIRECT_JMP 0x08
#define O26_RTYPE_LAYOUT 0x04

#define O26_MODE_ALIGN1 0x0000
#define O26_MODE_OBJECT 0x1000
#define O26_MODE_16BIT  0x0000
#define O26_MODE_6502   0x0000
#define O26_MODE_BREL   0x0000
#define O26_VERSION     2

#define O26_LAYOUT_PAGE_CONTAINED 0x01
#define O26_LAYOUT_INDEX_RANGE    0x02

#define O26_BRANCH_MAGIC "B26\2"
#define O26_BRANCH_MAGIC_SIZE 4

#define DEFAULT_SEGMENT_NAME "__default__"

typedef struct o26_reloc {
   long offset;
   unsigned char type;
   unsigned char segid;
   unsigned short undef_index;
   unsigned short layout_index;
   unsigned char aux_low;
   int has_aux_low;
   int has_layout_index;
   struct o26_reloc *next;
} o26_reloc_t;

typedef struct o26_undef {
   char *name;
   unsigned short index;
   struct o26_undef *next;
} o26_undef_t;

typedef struct o26_export {
   char *name;
   unsigned short value;
   unsigned char segid;
   struct o26_export *next;
} o26_export_t;

typedef struct o26_segment_buf {
   unsigned char *data;
   size_t len;
   size_t cap;
   o26_reloc_t *relocs;
   o26_reloc_t *relocs_tail;
} o26_segment_buf_t;

typedef struct o26_segment_layout {
   char *name;
   unsigned char segid;
   unsigned char image_segid;
   long source_base;
   unsigned short packed_base;
    unsigned short image_base;
   unsigned short used_size;
   unsigned char flags;
   unsigned short index_range_start;
   unsigned short index_range_max;
   struct o26_segment_layout *next;
} o26_segment_layout_t;

typedef struct o26_branch {
   unsigned char segid;
   unsigned short source;
   unsigned short target;
   unsigned char opcode;
   unsigned char page_policy;
   struct o26_branch *next;
} o26_branch_t;

typedef struct o26_writer {
   asm_context_t *ctx;
   o26_segment_buf_t text;
   o26_segment_buf_t data;
   unsigned short bss_len;
   unsigned short zp_len;
   unsigned short seg_lengths[6];
   o26_segment_layout_t *layouts;
   o26_branch_t *branches;
   o26_branch_t *branches_tail;
   o26_undef_t *undefs;
   o26_export_t *exports;
} o26_writer_t;

typedef struct reloc_expr_info {
   int is_reloc;
   int segid;
   unsigned short undef_index;
   unsigned short layout_index;
   long value;
   long reloc_value;
   int part;
   int has_layout_index;
} reloc_expr_info_t;

enum {
   RELOC_PART_NONE = 0,
   RELOC_PART_LOW,
   RELOC_PART_HIGH,
   RELOC_PART_WORD
};

//! @brief Handle writer error logic for assembler o26 object writer.
static void writer_error(asm_context_t *ctx, const stmt_t *stmt, const char *fmt, ...)
{
   va_list ap;

   ctx->error_count++;
   fprintf(stderr, "%s:%d: ", stmt->file ? stmt->file : "<input>", stmt->line);
   va_start(ap, fmt);
   vfprintf(stderr, fmt, ap);
   va_end(ap);
   fprintf(stderr, "\n");
}

//! @brief Handle str ieq logic for assembler o26 object writer.
static int str_ieq(const char *a, const char *b)
{
   unsigned char ca;
   unsigned char cb;

   if (!a || !b)
      return 0;

   while (*a && *b) {
      ca = (unsigned char)toupper((unsigned char)*a++);
      cb = (unsigned char)toupper((unsigned char)*b++);
      if (ca != cb)
         return 0;
   }

   return *a == '\0' && *b == '\0';
}

//! @brief Handle segment name matches logic for assembler o26 object writer.
static int segment_name_matches(const char *name, const char *base)
{
   size_t n;

   if (!name || !base)
      return 0;

   n = strlen(base);
   return strncasecmp(name, base, n) == 0 && (name[n] == '\0' || name[n] == '.');
}

//! @brief Handle segment name to o26 logic for assembler o26 object writer.
static int segment_name_to_o26(const char *name)
{
   if (!name || str_ieq(name, "__default__") || segment_name_matches(name, "TEXT") || segment_name_matches(name, "CODE") || segment_name_matches(name, "RODATA"))
      return O26_SEG_TEXT;
   if (segment_name_matches(name, "DATA"))
      return O26_SEG_DATA;
   if (segment_name_matches(name, "BSS"))
      return O26_SEG_BSS;
   if (segment_name_matches(name, "ZP") || segment_name_matches(name, "ZEROPAGE") || segment_name_matches(name, "ZERO"))
      return O26_SEG_ZP;
   return O26_SEG_TEXT;
}


//! @brief Handle directive name implies zero-page logic for assembler o26 object writer.
static int directive_name_implies_zp(const char *name)
{
   return name && (!strcmp(name, ".importzp") || !strcmp(name, ".exportzp") || !strcmp(name, ".globalzp") ||
                   !strcmp(name, ".zpimport") || !strcmp(name, ".zpexport") || !strcmp(name, ".zpglobal"));
}

//! @brief Return whether directive is export family in assembler o26 object writer.
static int directive_is_export_family(const char *name)
{
   return name && (!strcmp(name, ".global") || !strcmp(name, ".globalzp") || !strcmp(name, ".export") || !strcmp(name, ".exportzp") ||
                   !strcmp(name, ".zpglobal") || !strcmp(name, ".zpexport"));
}



//! @brief Return whether directive is an assembler-time diagnostic directive.
static int directive_is_diagnostic(const char *name)
{
   return name && (!strcmp(name, ".echo") || !strcmp(name, ".error"));
}

//! @brief Return whether directive is conditional assembly control.
static int directive_is_conditional(const char *name)
{
   return name && (!strcmp(name, ".if") || !strcmp(name, ".elif") ||
                   !strcmp(name, ".ifdef") || !strcmp(name, ".ifndef") ||
                   !strcmp(name, ".elifdef") || !strcmp(name, ".elifndef") ||
                   !strcmp(name, ".else") || !strcmp(name, ".endif"));
}

//! @brief Reset mutable assembler-time symbols before sequential o26 emission.
static void reset_mutable_symbols_for_o26(symtab_t *symbols)
{
   symbol_t *sym;

   if (!symbols)
      return;

   for (sym = symbols->head; sym; sym = sym->next) {
      if (sym->mutable)
         sym->defined = 0;
   }
}

//! @brief Apply a .set statement while building o26 data buffers.
static int process_set_statement_o26(o26_writer_t *wr, const stmt_t *stmt)
{
   symbol_t *sym;
   expr_eval_status_t rc;
   long value;

   if (!wr || !stmt || stmt->kind != STMT_CONST || stmt->u.cnst.assign_kind != CONST_ASSIGN_SET)
      return 1;

   sym = find_declared_symbol(&wr->ctx->symbols, wr->ctx->prog, stmt, stmt->u.cnst.name);
   if (!sym || !sym->mutable) {
      writer_error(wr->ctx, stmt, "internal error: missing mutable symbol '%s'", stmt->u.cnst.name);
      return 0;
   }

   rc = expr_eval(stmt->u.cnst.expr, &wr->ctx->symbols, stmt->scope, stmt->file, stmt->address, &value);
   if (rc != EXPR_EVAL_OK) {
      if (rc == EXPR_EVAL_UNRESOLVED)
         writer_error(wr->ctx, stmt, "could not evaluate .set expression for o26 output");
      else
         writer_error(wr->ctx, stmt, "%s", expr_eval_status_message(rc));
      return 0;
   }

   symtab_set_value_segment(sym, value, O26_SEG_ABS);
   return 1;
}

//! @brief Handle stmt emits load image bytes logic for assembler o26 object writer.
static int stmt_emits_load_image_bytes(const stmt_t *stmt)
{
   if (!stmt || !stmt->active)
      return 0;

   switch (stmt->kind) {
      case STMT_INSN:
         return 1;

      case STMT_DIR:
         return !strcmp(stmt->u.dir->name, ".byte") || !strcmp(stmt->u.dir->name, ".word") ||
                !strcmp(stmt->u.dir->name, ".text") || !strcmp(stmt->u.dir->name, ".ascii") ||
                !strcmp(stmt->u.dir->name, ".asciiz");

      default:
         return 0;
   }
}

//! @brief Compute padding needed to make address congruent to offset modulo boundary.
static long align_padding_for_address(long address, long boundary, long offset)
{
   long mod;

   if (boundary <= 0)
      return 0;

   mod = (address - offset) % boundary;
   if (mod < 0)
      mod += boundary;

   return mod ? (boundary - mod) : 0;
}

//! @brief Handle segment needs load image logic for assembler o26 object writer.
static int segment_needs_load_image(const asm_context_t *ctx, const char *name)
{
   const stmt_t *stmt;
   const char *want = name ? name : DEFAULT_SEGMENT_NAME;

   for (stmt = ctx->prog->head; stmt; stmt = stmt->next) {
      const char *stmt_name = stmt->segment ? stmt->segment : DEFAULT_SEGMENT_NAME;

      if (strcmp(stmt_name, want) != 0)
         continue;
      if (stmt_emits_load_image_bytes(stmt))
         return 1;
   }

   return 0;
}

//! @brief Find source segment in assembler o26 object writer tables without transferring ownership.
static const asm_segment_t *find_source_segment(const asm_context_t *ctx, const char *name)
{
   const asm_segment_t *seg;
   const char *want = name ? name : DEFAULT_SEGMENT_NAME;

   for (seg = ctx->segments; seg; seg = seg->next) {
      if (!strcmp(seg->name, want))
         return seg;
   }

   return NULL;
}

//! @brief Find layout in assembler o26 object writer tables without transferring ownership.
static o26_segment_layout_t *find_layout(o26_writer_t *wr, const char *name)
{
   o26_segment_layout_t *layout;
   const char *want = name ? name : DEFAULT_SEGMENT_NAME;

   for (layout = wr->layouts; layout; layout = layout->next) {
      if (!strcmp(layout->name, want))
         return layout;
   }

   return NULL;
}

//! @brief Find layout const in assembler o26 object writer tables without transferring ownership.
static const o26_segment_layout_t *find_layout_const(const o26_writer_t *wr, const char *name)
{
   const o26_segment_layout_t *layout;
   const char *want = name ? name : DEFAULT_SEGMENT_NAME;

   for (layout = wr->layouts; layout; layout = layout->next) {
      if (!strcmp(layout->name, want))
         return layout;
   }

   return NULL;
}

//! @brief Return the serialized layout index for a named source segment.
static int find_layout_index(const o26_writer_t *wr, const char *name, unsigned short *index_out)
{
   const o26_segment_layout_t *layout;
   const char *want = name ? name : DEFAULT_SEGMENT_NAME;
   unsigned int index = 0;

   for (layout = wr->layouts; layout; layout = layout->next, ++index) {
      if (!strcmp(layout->name, want)) {
         if (index > 0xFFFFu)
            return 0;
         *index_out = (unsigned short)index;
         return 1;
      }
   }
   return 0;
}

//! @brief Add layout to assembler o26 object writer state, growing storage or preserving uniqueness as needed.
static int register_layout(o26_writer_t *wr, const char *name)
{
   const asm_segment_t *seg;
   o26_segment_layout_t *layout;
   unsigned int total;
   unsigned int image_total;
   int segid;
   int needs_load_image;
   const char *want = name ? name : DEFAULT_SEGMENT_NAME;

   if (find_layout(wr, want))
      return 1;

   seg = find_source_segment(wr->ctx, want);
   if (!seg)
      return 1;

   segid = segment_name_to_o26(want);
   needs_load_image = (segid == O26_SEG_TEXT || segid == O26_SEG_DATA) ? 1 :
      (segid == O26_SEG_ZP ? segment_needs_load_image(wr->ctx, want) : 0);
   total = wr->seg_lengths[segid] + (unsigned int)((seg->used_size < 0) ? 0 : seg->used_size);
   if (total > 0xFFFFu) {
      fprintf(stderr, "o26 segment '%s' exceeds 64 KiB when packed into output segment %d\n", want, segid);
      return 0;
   }
   image_total = wr->seg_lengths[O26_SEG_DATA] + ((needs_load_image && segid == O26_SEG_ZP) ? (unsigned int)((seg->used_size < 0) ? 0 : seg->used_size) : 0u);
   if (image_total > 0xFFFFu) {
      fprintf(stderr, "o26 data image exceeds 64 KiB after packing segment '%s'\n", want);
      return 0;
   }

   layout = (o26_segment_layout_t *)calloc(1, sizeof(*layout));
   if (!layout) {
      fprintf(stderr, "out of memory\n");
      exit(1);
   }

   layout->name = xstrdup(want);
   layout->segid = (unsigned char)segid;
   layout->image_segid = (unsigned char)((segid == O26_SEG_TEXT) ? O26_SEG_TEXT :
      ((segid == O26_SEG_DATA || (segid == O26_SEG_ZP && needs_load_image)) ? O26_SEG_DATA : segid));
   layout->source_base = seg->base;
   layout->packed_base = wr->seg_lengths[segid];
   layout->image_base = (unsigned short)((layout->image_segid == O26_SEG_DATA && segid == O26_SEG_ZP) ? wr->seg_lengths[O26_SEG_DATA] : layout->packed_base);
   layout->used_size = (unsigned short)((seg->used_size < 0) ? 0 : seg->used_size);
   layout->flags = seg->page_contained ? O26_LAYOUT_PAGE_CONTAINED : 0;
   if (seg->index_range_set) {
      unsigned long range_end = (unsigned long)seg->index_range_start +
                                (unsigned long)seg->index_range_max;
      if (seg->index_range_start < 0 || seg->index_range_max < 0 ||
          seg->index_range_max > 255 || range_end >= layout->used_size) {
         fprintf(stderr, "indexed range for segment '%s' is outside its $%04X-byte layout\n",
                 want, layout->used_size);
         free(layout->name);
         free(layout);
         return 0;
      }
      layout->flags |= O26_LAYOUT_INDEX_RANGE;
      layout->index_range_start = (unsigned short)seg->index_range_start;
      layout->index_range_max = (unsigned short)seg->index_range_max;
   }
   layout->next = NULL;

   if (!wr->layouts)
      wr->layouts = layout;
   else {
      o26_segment_layout_t *tail = wr->layouts;
      while (tail->next)
         tail = tail->next;
      tail->next = layout;
   }

   wr->seg_lengths[segid] = (unsigned short)total;
   if (segid == O26_SEG_ZP && needs_load_image)
      wr->seg_lengths[O26_SEG_DATA] = (unsigned short)image_total;
   return 1;
}

//! @brief Handle build layouts logic for assembler o26 object writer.
static int build_layouts(o26_writer_t *wr)
{
   const stmt_t *stmt;
   const asm_segment_t *seg;

   for (stmt = wr->ctx->prog->head; stmt; stmt = stmt->next) {
      if (!stmt->active)
         continue;
      if (!register_layout(wr, stmt->segment ? stmt->segment : DEFAULT_SEGMENT_NAME))
         return 0;
   }

   for (seg = wr->ctx->segments; seg; seg = seg->next) {
      if (seg->used_size <= 0)
         continue;
      if (!register_layout(wr, seg->name))
         return 0;
   }

   wr->bss_len = wr->seg_lengths[O26_SEG_BSS];
   wr->zp_len = wr->seg_lengths[O26_SEG_ZP];
   return 1;
}

//! @brief Handle packed stmt offset logic for assembler o26 object writer.
static long packed_stmt_offset(o26_writer_t *wr, const stmt_t *stmt)
{
   const o26_segment_layout_t *layout;
   const char *segname = stmt->segment ? stmt->segment : DEFAULT_SEGMENT_NAME;

   layout = find_layout_const(wr, segname);
   if (!layout)
      return stmt->emit_address;

   return (long)layout->packed_base + (stmt->emit_address - layout->source_base);
}

//! @brief Handle packed stmt image offset logic for assembler o26 object writer.
static long packed_stmt_image_offset(o26_writer_t *wr, const stmt_t *stmt)
{
   const o26_segment_layout_t *layout;
   const char *segname = stmt->segment ? stmt->segment : DEFAULT_SEGMENT_NAME;

   layout = find_layout_const(wr, segname);
   if (!layout)
      return stmt->emit_address;

   return (long)layout->image_base + (stmt->emit_address - layout->source_base);
}

//! @brief Handle packed symbol value logic for assembler o26 object writer.
static long packed_symbol_value(const o26_writer_t *wr, const symbol_t *sym)
{
   const o26_segment_layout_t *layout;

   if (!sym || !sym->defined || sym->segment_id == O26_SEG_ABS)
      return sym ? sym->value : 0;

   layout = find_layout_const(wr, sym->segment_name ? sym->segment_name : DEFAULT_SEGMENT_NAME);
   if (!layout)
      return sym->value;

   return (long)layout->packed_base + (sym->value - layout->source_base);
}

//! @brief Find scoped symbol in assembler o26 object writer tables without transferring ownership.
static const symbol_t *find_scoped_symbol(const symtab_t *symtab,
                                          const char *scope,
                                          const char *file_scope,
                                          const char *ident)
{
   char buf[4096];
   const symbol_t *sym;

   if (!symtab || !ident)
      return NULL;

   if (ident[0] == '@') {
      snprintf(buf, sizeof(buf), "%s::%s", scope ? scope : "__root__", ident);
      return symtab_find_const(symtab, buf);
   }

   if (file_scope && *file_scope) {
      snprintf(buf, sizeof(buf), "%s::%s", file_scope, ident);
      sym = symtab_find_const(symtab, buf);
      if (sym)
         return sym;
   }

   return symtab_find_const(symtab, ident);
}

//! @brief Return writer buf for segid data used by assembler o26 object writer; returned pointers alias existing storage unless explicitly allocated by the function name.
static o26_segment_buf_t *writer_buf_for_segid(o26_writer_t *wr, int segid)
{
   if (segid == O26_SEG_TEXT)
      return &wr->text;
   if (segid == O26_SEG_DATA)
      return &wr->data;
   if (segid == O26_SEG_ZP)
      return &wr->data;
   return NULL;
}

//! @brief Handle ensure capacity logic for assembler o26 object writer.
static int ensure_capacity(o26_segment_buf_t *buf, size_t need)
{
   unsigned char *p;
   size_t cap;

   if (need <= buf->cap)
      return 1;

   cap = buf->cap ? buf->cap : 64;
   while (cap < need)
      cap *= 2;

   p = (unsigned char *)realloc(buf->data, cap);
   if (!p)
      return 0;

   memset(p + buf->cap, 0, cap - buf->cap);
   buf->data = p;
   buf->cap = cap;
   return 1;
}

//! @brief Handle buf write byte logic for assembler o26 object writer.
static int buf_write_byte(o26_segment_buf_t *buf, long offset, unsigned char v)
{
   size_t need;

   if (offset < 0 || offset > 0xFFFF)
      return 0;

   need = (size_t)offset + 1;
   if (!ensure_capacity(buf, need))
      return 0;

   buf->data[offset] = v;
   if (need > buf->len)
      buf->len = need;
   return 1;
}

//! @brief Handle buf write word logic for assembler o26 object writer.
static int buf_write_word(o26_segment_buf_t *buf, long offset, unsigned short v)
{
   return buf_write_byte(buf, offset, (unsigned char)(v & 0xFF)) &&
          buf_write_byte(buf, offset + 1, (unsigned char)((v >> 8) & 0xFF));
}

//! @brief Add reloc to assembler o26 object writer state, growing storage or preserving uniqueness as needed.
static int add_reloc(o26_segment_buf_t *buf, long offset, unsigned char type, unsigned char segid, unsigned short undef_index,
                     int has_layout_index, unsigned short layout_index,
                     int has_aux_low, unsigned char aux_low)
{
   o26_reloc_t *r;

   r = (o26_reloc_t *)calloc(1, sizeof(*r));
   if (!r)
      return 0;

   r->offset = offset;
   r->type = type;
   r->segid = segid;
   r->undef_index = undef_index;
   r->has_layout_index = has_layout_index;
   r->layout_index = layout_index;
   r->has_aux_low = has_aux_low;
   r->aux_low = aux_low;

   if (!buf->relocs)
      buf->relocs = r;
   else
      buf->relocs_tail->next = r;
   buf->relocs_tail = r;
   return 1;
}

//! @brief Record one actual relative branch for linker diagnostics.
static int add_branch(o26_writer_t *wr, unsigned char segid, long source, long target,
                      unsigned char opcode, unsigned char page_policy)
{
   o26_branch_t *branch;

   if (source < 0 || source > 0xffffL || target < 0 || target > 0xffffL)
      return 0;

   branch = (o26_branch_t *)calloc(1, sizeof(*branch));
   if (!branch)
      return 0;
   branch->segid = segid;
   branch->source = (unsigned short)source;
   branch->target = (unsigned short)target;
   branch->opcode = opcode;
   branch->page_policy = page_policy;

   if (!wr->branches)
      wr->branches = branch;
   else
      wr->branches_tail->next = branch;
   wr->branches_tail = branch;
   return 1;
}

//! @brief Find undef in assembler o26 object writer tables without transferring ownership.
static o26_undef_t *find_undef(o26_writer_t *wr, const char *name)
{
   o26_undef_t *u;
   for (u = wr->undefs; u; u = u->next) {
      if (!strcmp(u->name, name))
         return u;
   }
   return NULL;
}
//! @brief Create weak export name for assembler o26 object writer. The returned storage is owned by the caller or the object that immediately records it.
static char *make_weak_export_name(const char *name)
{
   size_t n = strlen(name);
   char *out = (char *)malloc(n + 8);
   if (!out) {
      fprintf(stderr, "out of memory\n");
      exit(1);
   }
   memcpy(out, "__weak_", 7);
   memcpy(out + 7, name, n + 1);
   return out;
}

//! @brief Find export in assembler o26 object writer tables without transferring ownership.
static o26_export_t *find_export(o26_writer_t *wr, const char *name)
{
   o26_export_t *e;
   for (e = wr->exports; e; e = e->next) {
      if (!strcmp(e->name, name))
         return e;
   }
   return NULL;
}


//! @brief Handle intern undef logic for assembler o26 object writer.
static unsigned short intern_undef(o26_writer_t *wr, const char *name)
{
   o26_undef_t *u;
   unsigned short idx = 0;

   u = find_undef(wr, name);
   if (u)
      return u->index;

   for (u = wr->undefs; u; u = u->next)
      idx++;

   u = (o26_undef_t *)calloc(1, sizeof(*u));
   if (!u) {
      fprintf(stderr, "out of memory\n");
      exit(1);
   }

   u->name = xstrdup(name);
   u->index = idx;
   u->next = NULL;

   if (!wr->undefs)
      wr->undefs = u;
   else {
      o26_undef_t *tail = wr->undefs;
      while (tail->next)
         tail = tail->next;
      tail->next = u;
   }

   return idx;
}

//! @brief Return whether imported applies in assembler o26 object writer.
static int is_imported(const asm_context_t *ctx, const char *name)
{
   const import_name_t *p;
   for (p = ctx->imports; p; p = p->next) {
      if (!strcmp(p->name, name))
         return 1;
   }
   return 0;
}

//! @brief Handle analyze expr logic for assembler o26 object writer.
static int analyze_expr(o26_writer_t *wr,
                        const stmt_t *stmt,
                        const expr_t *expr,
                        long pc,
                        reloc_expr_info_t *out)
{
   const symbol_t *sym;
   reloc_expr_info_t inner;
   reloc_expr_info_t left;
   reloc_expr_info_t right;

   memset(out, 0, sizeof(*out));

   if (!expr) {
      out->value = 0;
      return 1;
   }

   switch (expr->kind) {
      case EXPR_NUMBER:
         out->value = expr->u.number;
         return 1;

      case EXPR_CHARCONST:
         out->value = expr->u.char_value;
         return 1;

      case EXPR_PC:
         out->value = pc;
         return 1;

      case EXPR_IDENT:
         sym = find_scoped_symbol(&wr->ctx->symbols, stmt->scope, stmt->file, expr->u.ident);
         if (sym && sym->defined) {
            out->is_reloc = (sym->segment_id != O26_SEG_ABS);
            out->segid = sym->segment_id;
            out->value = packed_symbol_value(wr, sym);
            out->reloc_value = out->value;
            out->part = RELOC_PART_WORD;
            if (out->is_reloc) {
               if (!find_layout_index(wr,
                     sym->segment_name ? sym->segment_name : DEFAULT_SEGMENT_NAME,
                     &out->layout_index)) {
                  writer_error(wr->ctx, stmt,
                     "could not identify the o26 layout containing relocatable symbol %s",
                     expr->u.ident);
                  return 0;
               }
               out->has_layout_index = 1;
            }
            return 1;
         }

         if (is_imported(wr->ctx, expr->u.ident)) {
            out->is_reloc = 1;
            out->segid = O26_SEG_UNDEF;
            out->undef_index = intern_undef(wr, expr->u.ident);
            out->value = 0;
            out->reloc_value = 0;
            out->part = RELOC_PART_WORD;
            return 1;
         }

         writer_error(wr->ctx, stmt, "unresolved symbol in o26 output: %s", expr->u.ident);
         return 0;

      case EXPR_UNARY:
         if (!analyze_expr(wr, stmt, expr->u.unary.child, pc, &inner))
            return 0;

         if (expr->u.unary.op == EXPR_UOP_LO || expr->u.unary.op == EXPR_UOP_HI) {
            *out = inner;
            if (expr->u.unary.op == EXPR_UOP_LO) {
               out->value &= 0xFF;
               out->part = RELOC_PART_LOW;
               return 1;
            }
            out->value = (out->value >> 8) & 0xFF;
            out->part = RELOC_PART_HIGH;
            return 1;
         }

         if (inner.is_reloc) {
            writer_error(wr->ctx, stmt, "o26 output does not support unary operators on relocatable expressions");
            return 0;
         }

         if (expr_eval(expr, &wr->ctx->symbols, stmt->scope, stmt->file, pc, &out->value) != EXPR_EVAL_OK) {
            writer_error(wr->ctx, stmt, "could not evaluate expression for o26 output");
            return 0;
         }
         return 1;

      case EXPR_BINARY:
         if (!analyze_expr(wr, stmt, expr->u.binary.left, pc, &left))
            return 0;

         if (expr->u.binary.op == EXPR_BOP_LOG_AND || expr->u.binary.op == EXPR_BOP_LOG_OR) {
            if (left.is_reloc) {
               writer_error(wr->ctx, stmt, "o26 output does not support logical operators on relocatable expressions");
               return 0;
            }
            if (expr->u.binary.op == EXPR_BOP_LOG_AND && !left.value) {
               out->value = 0;
               return 1;
            }
            if (expr->u.binary.op == EXPR_BOP_LOG_OR && left.value) {
               out->value = 1;
               return 1;
            }
         }

         if (!analyze_expr(wr, stmt, expr->u.binary.right, pc, &right))
            return 0;

         if (left.is_reloc && right.is_reloc) {
            writer_error(wr->ctx, stmt, "o26 output only supports one relocatable term per expression");
            return 0;
         }

         switch (expr->u.binary.op) {
            case EXPR_BOP_ADD:
               if (left.is_reloc) {
                  *out = left;
                  out->value += right.value;
                  out->reloc_value += right.value;
                  return 1;
               }
               if (right.is_reloc) {
                  *out = right;
                  out->value += left.value;
                  out->reloc_value += left.value;
                  return 1;
               }
               out->value = left.value + right.value;
               return 1;

            case EXPR_BOP_SUB:
               if (right.is_reloc) {
                  writer_error(wr->ctx, stmt, "o26 output does not support subtracting relocatable expressions");
                  return 0;
               }
               if (left.is_reloc) {
                  *out = left;
                  out->value -= right.value;
                  out->reloc_value -= right.value;
                  return 1;
               }
               out->value = left.value - right.value;
               return 1;

            case EXPR_BOP_MUL:
            case EXPR_BOP_DIV:
            case EXPR_BOP_MOD:
            case EXPR_BOP_SHL:
            case EXPR_BOP_SHR:
            case EXPR_BOP_LT:
            case EXPR_BOP_LE:
            case EXPR_BOP_GT:
            case EXPR_BOP_GE:
            case EXPR_BOP_EQ:
            case EXPR_BOP_NE:
            case EXPR_BOP_BIT_AND:
            case EXPR_BOP_BIT_XOR:
            case EXPR_BOP_BIT_OR:
            case EXPR_BOP_LOG_AND:
            case EXPR_BOP_LOG_OR:
               if (left.is_reloc || right.is_reloc) {
                  writer_error(wr->ctx, stmt, "o26 output does not support this operator on relocatable expressions");
                  return 0;
               }
               {
                  expr_eval_status_t rc;
                  rc = expr_eval(expr, &wr->ctx->symbols, stmt->scope, stmt->file, pc, &out->value);
                  if (rc != EXPR_EVAL_OK) {
                     writer_error(wr->ctx, stmt, "%s", expr_eval_status_message(rc));
                     return 0;
                  }
               }
               return 1;
         }
         return 0;
   }

   return 0;
}

//! @brief Handle maybe add expression reloc logic for assembler o26 object writer.
static int maybe_add_expr_reloc(o26_writer_t *wr,
                                const stmt_t *stmt,
                                o26_segment_buf_t *buf,
                                long offset,
                                const reloc_expr_info_t *info,
                                int width,
                                unsigned char extra_type)
{
   unsigned char type;
   int part;

   if (!info->is_reloc)
      return 1;

   part = info->part;
   if (width == 2 && part == RELOC_PART_NONE)
      part = RELOC_PART_WORD;
   /* A plain relocatable symbol is naturally a word expression, but a
      one-byte instruction operand necessarily requests its low byte. */
   if (width == 1 && (part == RELOC_PART_NONE || part == RELOC_PART_WORD))
      part = RELOC_PART_LOW;

   switch (part) {
      case RELOC_PART_LOW:  type = O26_RTYPE_LOW; break;
      case RELOC_PART_HIGH: type = O26_RTYPE_HIGH; break;
      case RELOC_PART_WORD: type = O26_RTYPE_WORD; break;
      default:
         writer_error(wr->ctx, stmt, "unsupported relocation width/part combination");
         return 0;
   }
   type |= extra_type;
   if (info->has_layout_index)
      type |= O26_RTYPE_LAYOUT;

   /* A one-byte relocation still needs both bytes of its expression value so
      the linker can preserve constant addends.  This applies to imported
      symbols too: (external+8),Y must relocate to the low byte of external+8,
      not merely to the low byte of external. */
   if (width == 1) {
      type |= O26_RTYPE_AUX;
      if (!add_reloc(buf, offset, type, (unsigned char)info->segid, info->undef_index,
                     info->has_layout_index, info->layout_index, 1,
                     (unsigned char)((part == RELOC_PART_LOW) ? ((info->reloc_value >> 8) & 0xFF) : (info->reloc_value & 0xFF)))) {
         writer_error(wr->ctx, stmt, "out of memory recording relocation");
         return 0;
      }
      return 1;
   }

   if (!add_reloc(buf, offset, type, (unsigned char)info->segid, info->undef_index,
                  info->has_layout_index, info->layout_index, 0, 0)) {
      writer_error(wr->ctx, stmt, "out of memory recording relocation");
      return 0;
   }

   return 1;
}

//! @brief Parse escaped string into the normalized representation used by assembler o26 object writer.
static int decode_escaped_string(const char *quoted,
                                 unsigned char *out,
                                 int out_cap,
                                 int *out_len)
{
   size_t i;
   size_t n;
   int len;

   if (!quoted || !out_len)
      return 0;

   n = strlen(quoted);
   if (n < 2 || quoted[0] != '"' || quoted[n - 1] != '"')
      return 0;

   len = 0;
   for (i = 1; i + 1 < n; i++) {
      unsigned char ch;
      if (quoted[i] == '\\' && i + 2 < n) {
         i++;
         switch (quoted[i]) {
            case 'n': ch = '\n'; break;
            case 'r': ch = '\r'; break;
            case 't': ch = '\t'; break;
            case '0': ch = '\0'; break;
            case '\\': ch = '\\'; break;
            case '"': ch = '"'; break;
            case '\'': ch = '\''; break;
            default: ch = (unsigned char)quoted[i]; break;
         }
      } else {
         ch = (unsigned char)quoted[i];
      }
      if (out && len < out_cap)
         out[len] = ch;
      len++;
   }
   *out_len = len;
   return 1;
}

//! @brief Add exports to assembler o26 object writer state, growing storage or preserving uniqueness as needed.
static void add_exports(o26_writer_t *wr)
{
   const stmt_t *stmt;
   const expr_list_node_t *node;

   for (stmt = wr->ctx->prog->head; stmt; stmt = stmt->next) {
      if (stmt->kind != STMT_DIR || !stmt->u.dir)
         continue;
      if (!directive_is_export_family(stmt->u.dir->name))
         continue;

      for (node = stmt->u.dir->exprs; node; node = node->next) {
         const symbol_t *sym;
         o26_export_t *ex;
         const char *name;

         if (!node->expr || node->expr->kind != EXPR_IDENT)
            continue;

         char *export_name;

         name = node->expr->u.ident;
         sym = symtab_find_const(&wr->ctx->symbols, name);
         if (!sym || !sym->defined)
            continue;

         export_name = asm_symbol_is_weak(wr->ctx, name) ? make_weak_export_name(name) : xstrdup(name);

         if (find_export(wr, export_name)) {
            free(export_name);
            continue;
         }

         ex = (o26_export_t *)calloc(1, sizeof(*ex));
         if (!ex) {
            fprintf(stderr, "out of memory\n");
            exit(1);
         }
         ex->name = export_name;
         ex->value = (unsigned short)(packed_symbol_value(wr, sym) & 0xFFFF);
         ex->segid = (unsigned char)sym->segment_id;
         if (directive_name_implies_zp(stmt->u.dir->name) && ex->segid == O26_SEG_ABS)
            ex->segid = O26_SEG_ZP;
         ex->next = wr->exports;
         wr->exports = ex;
      }
   }
}


//! @brief Decode the single quoted string expected by .echo/.error in o26 output.
static int directive_decode_message(o26_writer_t *wr,
                                    const stmt_t *stmt,
                                    const directive_info_t *dir,
                                    char *buf,
                                    int buf_cap)
{
   int len;

   if (!dir || dir->kind != DIRARG_STRING || !dir->string || dir->exprs) {
      writer_error(wr->ctx, stmt, "%s expects exactly one quoted string", dir && dir->name ? dir->name : "directive");
      return 0;
   }

   if (!decode_escaped_string(dir->string, (unsigned char *)buf, buf_cap - 1, &len)) {
      writer_error(wr->ctx, stmt, "malformed quoted string");
      return 0;
   }

   if (len >= buf_cap) {
      writer_error(wr->ctx, stmt, "%s message is too long", dir->name);
      return 0;
   }

   buf[len] = '\0';
   return 1;
}

//! @brief Write segment stmt using the on-disk format expected by assembler o26 object writer.
static int write_segment_stmt(o26_writer_t *wr, const stmt_t *stmt)
{
   int segid;

   if (!stmt->active)
      return 1;

   if (stmt->kind == STMT_CONST && stmt->u.cnst.assign_kind == CONST_ASSIGN_SET)
      return process_set_statement_o26(wr, stmt);

   o26_segment_buf_t *buf;
   long off;
   const expr_list_node_t *node;

   if (stmt->kind == STMT_DIR && stmt->u.dir && directive_is_diagnostic(stmt->u.dir->name)) {
      char msg[4096];

      if (!directive_decode_message(wr, stmt, stmt->u.dir, msg, (int)sizeof(msg)))
         return 0;

      if (!strcmp(stmt->u.dir->name, ".echo")) {
         fprintf(stderr, "%s\n", msg);
      } else {
         writer_error(wr->ctx, stmt, "%s", msg);
         return 0;
      }
      return 1;
   }

   segid = segment_name_to_o26(stmt->segment);
   if (segid == O26_SEG_BSS)
      return 1;

   buf = writer_buf_for_segid(wr, segid);
   if (!buf) {
      writer_error(wr->ctx, stmt, "unsupported o26 segment");
      return 0;
   }

   off = (segid == O26_SEG_ZP) ? packed_stmt_image_offset(wr, stmt) : packed_stmt_offset(wr, stmt);

   switch (stmt->kind) {
      case STMT_LABEL:
      case STMT_CONST:
         return 1;

      case STMT_DIR:
         if (!strcmp(stmt->u.dir->name, ".org") || !strcmp(stmt->u.dir->name, ".rorg") ||
             !strcmp(stmt->u.dir->name, ".rend") || !strcmp(stmt->u.dir->name, ".segment") ||
             !strcmp(stmt->u.dir->name, ".segmentdef") || !strcmp(stmt->u.dir->name, ".global") ||
             !strcmp(stmt->u.dir->name, ".export") || !strcmp(stmt->u.dir->name, ".import") ||
             !strcmp(stmt->u.dir->name, ".globalzp") || !strcmp(stmt->u.dir->name, ".exportzp") ||
             !strcmp(stmt->u.dir->name, ".importzp") || !strcmp(stmt->u.dir->name, ".zpglobal") ||
             !strcmp(stmt->u.dir->name, ".zpexport") || !strcmp(stmt->u.dir->name, ".zpimport") ||
             !strcmp(stmt->u.dir->name, ".weak") || !strcmp(stmt->u.dir->name, ".proc") ||
             !strcmp(stmt->u.dir->name, ".endproc") || directive_is_conditional(stmt->u.dir->name))
            return 1;

         if (!strcmp(stmt->u.dir->name, ".byte")) {
            for (node = stmt->u.dir->exprs; node; node = node->next) {
               reloc_expr_info_t info;
               if (!analyze_expr(wr, stmt, node->expr, off, &info))
                  return 0;
               if (!buf_write_byte(buf, off, (unsigned char)(info.value & 0xFF)) ||
                   !maybe_add_expr_reloc(wr, stmt, buf, off, &info, 1, 0)) {
                  writer_error(wr->ctx, stmt, "failed to write o26 data");
                  return 0;
               }
               off++;
            }
            return 1;
         }

         if (!strcmp(stmt->u.dir->name, ".word")) {
            for (node = stmt->u.dir->exprs; node; node = node->next) {
               reloc_expr_info_t info;
               if (!analyze_expr(wr, stmt, node->expr, off, &info))
                  return 0;
               if (!buf_write_word(buf, off, (unsigned short)(info.value & 0xFFFF)) ||
                   !maybe_add_expr_reloc(wr, stmt, buf, off, &info, 2, 0)) {
                  writer_error(wr->ctx, stmt, "failed to write o26 data");
                  return 0;
               }
               off += 2;
            }
            return 1;
         }

         if (!strcmp(stmt->u.dir->name, ".text") || !strcmp(stmt->u.dir->name, ".ascii") || !strcmp(stmt->u.dir->name, ".asciiz")) {
            unsigned char sbuf[1024];
            int slen = 0;
            int i;
            if (stmt->u.dir->string && !decode_escaped_string(stmt->u.dir->string, sbuf, (int)sizeof(sbuf), &slen)) {
               writer_error(wr->ctx, stmt, "malformed quoted string");
               return 0;
            }
            for (i = 0; i < slen; i++) {
               if (!buf_write_byte(buf, off++, sbuf[i])) {
                  writer_error(wr->ctx, stmt, "failed to write o26 string");
                  return 0;
               }
            }
            if (!strcmp(stmt->u.dir->name, ".asciiz")) {
               if (!buf_write_byte(buf, off++, 0)) {
                  writer_error(wr->ctx, stmt, "failed to terminate o26 string");
                  return 0;
               }
            }
            return 1;
         }

         if (!strcmp(stmt->u.dir->name, ".pagecontain")) {
            if (stmt->u.dir->exprs || stmt->u.dir->string) {
               writer_error(wr->ctx, stmt, ".pagecontain expects no arguments");
               return 0;
            }
            return 1;
         }

         if (!strcmp(stmt->u.dir->name, ".indexrange"))
            return 1;

         if (!strcmp(stmt->u.dir->name, ".align")) {
            const expr_list_node_t *args = stmt->u.dir->exprs;
            long boundary;
            long offset = 0;
            long fill = 0;
            long count;
            const o26_segment_layout_t *layout;

            if (!args || (args->next && args->next->next && args->next->next->next)) {
               writer_error(wr->ctx, stmt, ".align expects one, two, or three expressions");
               return 0;
            }
            if (expr_eval(args->expr, &wr->ctx->symbols, stmt->scope, stmt->file, stmt->address, &boundary) != EXPR_EVAL_OK || boundary <= 0) {
               writer_error(wr->ctx, stmt, "invalid .align boundary in o26 output");
               return 0;
            }
            if (args->next && expr_eval(args->next->expr, &wr->ctx->symbols, stmt->scope, stmt->file, stmt->address, &offset) != EXPR_EVAL_OK) {
               writer_error(wr->ctx, stmt, "invalid .align offset in o26 output");
               return 0;
            }
            if (args->next && args->next->next &&
                expr_eval(args->next->next->expr, &wr->ctx->symbols, stmt->scope, stmt->file, stmt->address, &fill) != EXPR_EVAL_OK) {
               writer_error(wr->ctx, stmt, "invalid .align fill byte in o26 output");
               return 0;
            }
            if (offset < 0 || offset >= boundary) {
               writer_error(wr->ctx, stmt, ".align offset must be from zero through boundary minus one");
               return 0;
            }
            if (fill < 0 || fill > 0xff) {
               writer_error(wr->ctx, stmt, ".align fill byte must be from zero through 255");
               return 0;
            }
            count = align_padding_for_address(stmt->address, boundary, offset);
            layout = find_layout_const(wr, stmt->segment ? stmt->segment : DEFAULT_SEGMENT_NAME);
            if (segid == O26_SEG_ZP && (!layout || layout->image_segid != O26_SEG_DATA))
               return 1;
            while (count-- > 0) {
               if (!buf_write_byte(buf, off++, (unsigned char)fill)) {
                  writer_error(wr->ctx, stmt, "failed to write .align padding");
                  return 0;
               }
            }
            return 1;
         }

         if (!strcmp(stmt->u.dir->name, ".res")) {
            long count;
            const o26_segment_layout_t *layout;
            if (!stmt->u.dir->exprs || stmt->u.dir->exprs->next) {
               writer_error(wr->ctx, stmt, ".res expects exactly one expression");
               return 0;
            }
            if (expr_eval(stmt->u.dir->exprs->expr, &wr->ctx->symbols, stmt->scope, stmt->file, off, &count) != EXPR_EVAL_OK || count < 0) {
               writer_error(wr->ctx, stmt, "invalid .res in o26 output");
               return 0;
            }
            layout = find_layout_const(wr, stmt->segment ? stmt->segment : DEFAULT_SEGMENT_NAME);
            if (segid == O26_SEG_ZP && (!layout || layout->image_segid != O26_SEG_DATA))
               return 1;
            while (count-- > 0) {
               if (!buf_write_byte(buf, off++, 0)) {
                  writer_error(wr->ctx, stmt, "failed to write .res padding");
                  return 0;
               }
            }
            return 1;
         }

         writer_error(wr->ctx, stmt, "directive %s is not supported in o26 output", stmt->u.dir->name);
         return 0;

      case STMT_INSN: {
         reloc_expr_info_t info;
         unsigned char opcode;
         long value;
         long insn_off = off;
         emit_mode_t emode;

         emode = stmt->u.insn.final_mode;
         if (emode == EM_REL_LONG) {
            unsigned char inv_opcode;
            if (!opcode_invert_branch(stmt->u.insn.opcode, &inv_opcode)) {
               writer_error(wr->ctx, stmt, "internal error: no inverse branch for %s", stmt->u.insn.opcode);
               return 0;
            }
            if (!buf_write_byte(buf, off++, inv_opcode) || !buf_write_byte(buf, off++, 0x03)) {
               writer_error(wr->ctx, stmt, "failed to write long branch prefix");
               return 0;
            }
            if (!add_branch(wr, (unsigned char)segid, insn_off, insn_off + 5,
                            inv_opcode, 0)) {
               writer_error(wr->ctx, stmt, "out of memory recording branch metadata");
               return 0;
            }
            if (!opcode_lookup("JMP", EM_ABS, &opcode) || !buf_write_byte(buf, off++, opcode)) {
               writer_error(wr->ctx, stmt, "failed to write long branch jmp opcode");
               return 0;
            }
         } else {
            if (!opcode_lookup(stmt->u.insn.opcode, emode, &opcode)) {
               writer_error(wr->ctx, stmt, "illegal addressing mode for %s%s",
                            stmt->u.insn.opcode, mode_spec_suffix(stmt->u.insn.spec));
               return 0;
            }
            if (!buf_write_byte(buf, off++, opcode)) {
               writer_error(wr->ctx, stmt, "failed to write opcode");
               return 0;
            }
         }

         if (emode == EM_IMPLIED || emode == EM_ACCUMULATOR)
            return 1;

         if (!analyze_expr(wr, stmt, stmt->u.insn.expr, off, &info))
            return 0;
         value = info.value;

         switch (emode) {
            case EM_IMMEDIATE:
            case EM_ZP:
            case EM_ZPX:
            case EM_ZPY:
            case EM_INDX:
            case EM_INDY:
               if (!buf_write_byte(buf, off, (unsigned char)(value & 0xFF)) ||
                   !maybe_add_expr_reloc(wr, stmt, buf, off, &info, 1, 0)) {
                  writer_error(wr->ctx, stmt, "failed to write o26 operand");
                  return 0;
               }
               return 1;

            case EM_REL:
               if (info.is_reloc) {
                  if (info.segid == O26_SEG_UNDEF) {
                     writer_error(wr->ctx, stmt, "o26 output does not support external branch targets");
                     return 0;
                  }
                  if (info.segid != segid) {
                     writer_error(wr->ctx, stmt, "o26 output does not support cross-segment branch targets");
                     return 0;
                  }
               }
               value = value - (off + 1);
               if (value < -128 || value > 127) {
                  writer_error(wr->ctx, stmt, "branch out of range");
                  return 0;
               }
               if (!buf_write_byte(buf, off, (unsigned char)(value & 0xFF))) {
                  writer_error(wr->ctx, stmt, "failed to write branch displacement");
                  return 0;
               }
               unsigned char page_policy = 0;
               if (stmt->u.insn.branch_page == BRANCH_PAGE_SAME)
                  page_policy = 1;
               else if (stmt->u.insn.branch_page == BRANCH_PAGE_CROSS)
                  page_policy = 2;
               if (!add_branch(wr, (unsigned char)segid, insn_off, info.value,
                               opcode, page_policy)) {
                  writer_error(wr->ctx, stmt, "out of memory recording branch metadata");
                  return 0;
               }
               return 1;

            case EM_REL_LONG:
            case EM_ABS:
            case EM_ABSX:
            case EM_ABSY:
            case EM_IND:
               if (emode == EM_IND && !info.is_reloc && (value & 0xff) == 0xff) {
                  writer_error(wr->ctx, stmt,
                     "indirect JMP vector at $%04lX triggers the NMOS 6502/6507 page-wrap bug",
                     value & 0xffff);
                  return 0;
               }
               if (!buf_write_word(buf, off, (unsigned short)(value & 0xFFFF)) ||
                   !maybe_add_expr_reloc(wr, stmt, buf, off, &info, 2,
                      emode == EM_IND ? O26_RTYPE_INDIRECT_JMP : 0)) {
                  writer_error(wr->ctx, stmt, "failed to write o26 address");
                  return 0;
               }
               return 1;

            default:
               writer_error(wr->ctx, stmt, "unsupported instruction mode in o26 output");
               return 0;
         }
      }
   }

   return 1;
}

//! @brief Write 8-bit using the on-disk format expected by assembler o26 object writer.
static int write_u8(FILE *fp, unsigned char v) { return fputc(v, fp) != EOF; }
//! @brief Write 16-bit using the on-disk format expected by assembler o26 object writer.
static int write_u16(FILE *fp, unsigned short v)
{
   return write_u8(fp, (unsigned char)(v & 0xFF)) && write_u8(fp, (unsigned char)((v >> 8) & 0xFF));
}

//! @brief Write C string using the on-disk format expected by assembler o26 object writer.
static int write_cstr(FILE *fp, const char *s)
{
   size_t n = strlen(s) + 1;
   return fwrite(s, 1, n, fp) == n;
}

//! @brief Write reloc table using the on-disk format expected by assembler o26 object writer.
static int write_reloc_table(FILE *fp, const o26_reloc_t *r)
{
   long prev = -1;
   for (; r; r = r->next) {
      long delta = r->offset - prev;
      while (delta > 254) {
         if (!write_u8(fp, 255))
            return 0;
         delta -= 254;
         prev += 254;
      }
      if (!write_u8(fp, (unsigned char)delta) || !write_u8(fp, r->type) || !write_u8(fp, r->segid))
         return 0;
      if (r->segid == O26_SEG_UNDEF && !write_u16(fp, r->undef_index))
         return 0;
      if (r->has_layout_index && !write_u16(fp, r->layout_index))
         return 0;
      if (r->has_aux_low && !write_u8(fp, r->aux_low))
         return 0;
      prev = r->offset;
   }
   return write_u8(fp, 0);
}

//! @brief Write undefs using the on-disk format expected by assembler o26 object writer.
static int write_undefs(FILE *fp, const o26_undef_t *u)
{
   unsigned short count = 0;
   const o26_undef_t *p;
   for (p = u; p; p = p->next)
      count++;
   if (!write_u16(fp, count))
      return 0;
   for (; u; u = u->next) {
      if (!write_cstr(fp, u->name))
         return 0;
   }
   return 1;
}

//! @brief Write exports using the on-disk format expected by assembler o26 object writer.
static int write_exports(FILE *fp, const o26_export_t *e)
{
   unsigned int count = 0;
   const o26_export_t *p;

   for (p = e; p; p = p->next)
      count++;

   if (count > 255) {
      fprintf(stderr, "too many exported symbols for current o26 writer\n");
      return 0;
   }

   if (!write_u16(fp, (unsigned short)count))
      return 0;

   for (; e; e = e->next) {
      if (!write_cstr(fp, e->name) || !write_u8(fp, e->segid) || !write_u16(fp, e->value))
         return 0;
   }
   return 1;
}

//! @brief Write layouts using the on-disk format expected by assembler o26 object writer.
static int write_layouts(FILE *fp, const o26_segment_layout_t *layout)
{
   unsigned int count = 0;
   const o26_segment_layout_t *p;

   for (p = layout; p; p = p->next)
      count++;

   if (count > 0xFFFFu) {
      fprintf(stderr, "too many segment layouts for current o26 writer\n");
      return 0;
   }

   if (!write_u16(fp, (unsigned short)count))
      return 0;

   for (; layout; layout = layout->next) {
      if (!write_cstr(fp, layout->name) || !write_u8(fp, layout->segid) || !write_u16(fp, layout->packed_base) ||
          !write_u16(fp, layout->used_size) || !write_u8(fp, layout->image_segid) || !write_u16(fp, layout->image_base) ||
          !write_u8(fp, layout->flags) || !write_u16(fp, layout->index_range_start) ||
          !write_u16(fp, layout->index_range_max))
         return 0;
   }

   return 1;
}

//! @brief Write relative-branch metadata appended after the layout table.
static int write_branches(FILE *fp, const o26_branch_t *branch)
{
   unsigned int count = 0;
   const o26_branch_t *p;

   for (p = branch; p; p = p->next)
      count++;
   if (count > 0xffffu) {
      fprintf(stderr, "too many relative branches for current o26 writer\n");
      return 0;
   }

   if (fwrite(O26_BRANCH_MAGIC, 1, O26_BRANCH_MAGIC_SIZE, fp) != O26_BRANCH_MAGIC_SIZE ||
       !write_u16(fp, (unsigned short)count))
      return 0;

   for (; branch; branch = branch->next) {
      if (!write_u8(fp, branch->segid) || !write_u16(fp, branch->source) ||
          !write_u16(fp, branch->target) || !write_u8(fp, branch->opcode) ||
          !write_u8(fp, branch->page_policy))
         return 0;
   }
   return 1;
}

//! @brief Release layouts storage owned by assembler o26 object writer.
static void free_layouts(o26_segment_layout_t *layout)
{
   while (layout) {
      o26_segment_layout_t *next = layout->next;
      free(layout->name);
      free(layout);
      layout = next;
   }
}

//! @brief Release relative-branch metadata storage.
static void free_branches(o26_branch_t *branch)
{
   while (branch) {
      o26_branch_t *next = branch->next;
      free(branch);
      branch = next;
   }
}

//! @brief Release relocs storage owned by assembler o26 object writer.
static void free_relocs(o26_reloc_t *r)
{
   while (r) {
      o26_reloc_t *next = r->next;
      free(r);
      r = next;
   }
}

//! @brief Release undefs storage owned by assembler o26 object writer.
static void free_undefs(o26_undef_t *u)
{
   while (u) {
      o26_undef_t *next = u->next;
      free(u->name);
      free(u);
      u = next;
   }
}

//! @brief Release exports storage owned by assembler o26 object writer.
static void free_exports(o26_export_t *e)
{
   while (e) {
      o26_export_t *next = e->next;
      free(e->name);
      free(e);
      e = next;
   }
}

//! @brief Handle o26 write object file logic for assembler o26 object writer.
int o26_write_object_file(FILE *fp, asm_context_t *ctx)
{
   o26_writer_t wr;
   const stmt_t *stmt;
   unsigned short mode;

   memset(&wr, 0, sizeof(wr));
   wr.ctx = ctx;
   if (!build_layouts(&wr))
      goto fail;

   add_exports(&wr);
   reset_mutable_symbols_for_o26(&ctx->symbols);

   for (stmt = ctx->prog->head; stmt; stmt = stmt->next) {
      if (!write_segment_stmt(&wr, stmt))
         break;
   }

   if (ctx->error_count)
      goto fail;

   mode = O26_MODE_OBJECT | O26_MODE_16BIT | O26_MODE_6502 | O26_MODE_BREL | O26_MODE_ALIGN1;

   if (!write_u8(fp, 0x01) || !write_u8(fp, 0x00) ||
       fwrite("o26", 1, 3, fp) != 3 || !write_u8(fp, O26_VERSION) || !write_u16(fp, mode) ||
       !write_u16(fp, 0) || !write_u16(fp, (unsigned short)wr.text.len) ||
       !write_u16(fp, 0) || !write_u16(fp, (unsigned short)wr.data.len) ||
       !write_u16(fp, 0) || !write_u16(fp, wr.bss_len) ||
       !write_u16(fp, 0) || !write_u16(fp, wr.zp_len) ||
       !write_u16(fp, 0) || !write_u8(fp, 0)) {
      fprintf(stderr, "failed writing o26 header\n");
      goto fail;
   }

   if ((wr.text.len && fwrite(wr.text.data, 1, wr.text.len, fp) != wr.text.len) ||
       (wr.data.len && fwrite(wr.data.data, 1, wr.data.len, fp) != wr.data.len) ||
       !write_undefs(fp, wr.undefs) ||
       !write_reloc_table(fp, wr.text.relocs) ||
       !write_reloc_table(fp, wr.data.relocs) ||
       !write_exports(fp, wr.exports) ||
       !write_layouts(fp, wr.layouts) ||
       !write_branches(fp, wr.branches)) {
      fprintf(stderr, "failed writing o26 object contents\n");
      goto fail;
   }

   free(wr.text.data);
   free(wr.data.data);
   free_relocs(wr.text.relocs);
   free_relocs(wr.data.relocs);
   free_undefs(wr.undefs);
   free_exports(wr.exports);
   free_layouts(wr.layouts);
   free_branches(wr.branches);
   return ctx->error_count ? 0 : 1;

fail:
   free(wr.text.data);
   free(wr.data.data);
   free_relocs(wr.text.relocs);
   free_relocs(wr.data.relocs);
   free_undefs(wr.undefs);
   free_exports(wr.exports);
   free_layouts(wr.layouts);
   free_branches(wr.branches);
   return 0;
}
