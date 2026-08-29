//! @file assembler/listing.c
//! @brief Implements assembly listing generation for the VCSC assembler.
//! @ingroup assembler

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include "listing.h"
#include "expr.h"
#include "directive.h"

//! @brief Emit expr list for assembler listing writer diagnostics or output files.
static void render_expr_list(FILE *fp, const expr_list_node_t *node)
{
   int first;

   first = 1;
   while (node) {
      if (!first)
         fprintf(fp, ", ");
      expr_fprint(fp, node->expr);
      first = 0;
      node = node->next;
   }
}

//! @brief Emit stmt text for assembler listing writer diagnostics or output files.
static void render_stmt_text(FILE *fp, const stmt_t *stmt)
{
   if (stmt->label)
      fprintf(fp, "%s: ", stmt->label);

   switch (stmt->kind) {
      case STMT_LABEL:
         if (!stmt->label)
            fprintf(fp, "<label>");
         break;

      case STMT_INSN:
         fprintf(fp, "%s%s%s",
                 stmt->u.insn.opcode,
                 mode_spec_suffix(stmt->u.insn.spec),
                 branch_page_spec_suffix(stmt->u.insn.branch_page));

         if (stmt->u.insn.has_operand) {
            fprintf(fp, " ");
            if (stmt->u.insn.mode == AM_ACCUMULATOR) {
               fprintf(fp, "A");
            } else if (stmt->u.insn.mode == AM_IMMEDIATE) {
               fprintf(fp, "#");
               expr_fprint(fp, stmt->u.insn.expr);
            } else if (stmt->u.insn.mode == AM_INDEXED_INDIRECT) {
               fprintf(fp, "(");
               expr_fprint(fp, stmt->u.insn.expr);
               fprintf(fp, ",X)");
            } else if (stmt->u.insn.mode == AM_INDIRECT_INDEXED) {
               fprintf(fp, "(");
               expr_fprint(fp, stmt->u.insn.expr);
               fprintf(fp, "),Y");
            } else if (stmt->u.insn.mode == AM_INDIRECT) {
               fprintf(fp, "(");
               expr_fprint(fp, stmt->u.insn.expr);
               fprintf(fp, ")");
            } else {
               expr_fprint(fp, stmt->u.insn.expr);
               if (stmt->u.insn.mode == AM_ZPX_OR_ABSX)
                  fprintf(fp, ",X");
               else if (stmt->u.insn.mode == AM_ZPY_OR_ABSY)
                  fprintf(fp, ",Y");
            }
         }
         break;

      case STMT_DIR:
         fprintf(fp, "%s", stmt->u.dir->name);

         switch (stmt->u.dir->kind) {
            case DIRARG_NONE:
               break;

            case DIRARG_EXPR_LIST:
               fprintf(fp, " ");
               render_expr_list(fp, stmt->u.dir->exprs);
               break;

            case DIRARG_STRING:
               fprintf(fp, " %s", stmt->u.dir->string);
               break;

            case DIRARG_STRING_AND_EXPR_LIST:
               fprintf(fp, " %s", stmt->u.dir->string);
               if (stmt->u.dir->exprs) {
                  fprintf(fp, ", ");
                  render_expr_list(fp, stmt->u.dir->exprs);
               }
               break;
         }
         break;

      case STMT_CONST:
         if (stmt->u.cnst.assign_kind == CONST_ASSIGN_SET)
            fprintf(fp, ".set %s = ", stmt->u.cnst.name);
         else if (stmt->u.cnst.assign_kind == CONST_ASSIGN_DEFAULT)
            fprintf(fp, "%s ?= ", stmt->u.cnst.name);
         else
            fprintf(fp, "%s = ", stmt->u.cnst.name);
         expr_fprint(fp, stmt->u.cnst.expr);
         break;
   }
}



typedef struct listing_textbuf {
   char *data;
   size_t len;
   size_t cap;
} listing_textbuf_t;

static void listing_textbuf_appendf(listing_textbuf_t *buf, const char *fmt, ...)
{
   va_list ap;
   va_list copy;
   int need;

   va_start(ap, fmt);
   va_copy(copy, ap);
   need = vsnprintf(NULL, 0, fmt, copy);
   va_end(copy);
   if (need < 0) {
      va_end(ap);
      return;
   }
   if (buf->len + (size_t)need + 1 > buf->cap) {
      size_t cap = buf->cap ? buf->cap : 128;
      while (cap < buf->len + (size_t)need + 1)
         cap *= 2;
      buf->data = (char *)realloc(buf->data, cap);
      if (!buf->data) {
         fprintf(stderr, "out of memory\\n");
         exit(1);
      }
      buf->cap = cap;
   }
   vsnprintf(buf->data + buf->len, buf->cap - buf->len, fmt, ap);
   va_end(ap);
   buf->len += (size_t)need;
}

static void listing_render_expr_buf(listing_textbuf_t *buf, const expr_t *expr)
{
   if (!expr) {
      listing_textbuf_appendf(buf, "<null>");
      return;
   }
   switch (expr->kind) {
      case EXPR_NUMBER: listing_textbuf_appendf(buf, "%ld", expr->u.number); break;
      case EXPR_IDENT: listing_textbuf_appendf(buf, "%s", expr->u.ident); break;
      case EXPR_CHARCONST: listing_textbuf_appendf(buf, "'%d", expr->u.char_value); break;
      case EXPR_PC: listing_textbuf_appendf(buf, "*"); break;
      case EXPR_UNARY: {
         static const char *const ops[] = { "+", "-", "!", "~", "<", ">" };
         listing_textbuf_appendf(buf, "(%s", ops[expr->u.unary.op]);
         listing_render_expr_buf(buf, expr->u.unary.child);
         listing_textbuf_appendf(buf, ")");
         break;
      }
      case EXPR_BINARY: {
         static const char *const ops[] = {
            " + ", " - ", " * ", " / ", " % ", " << ", " >> ",
            " < ", " <= ", " > ", " >= ", " == ", " != ", " & ",
            " ^ ", " | ", " && ", " || "
         };
         listing_textbuf_appendf(buf, "(");
         listing_render_expr_buf(buf, expr->u.binary.left);
         listing_textbuf_appendf(buf, "%s", ops[expr->u.binary.op]);
         listing_render_expr_buf(buf, expr->u.binary.right);
         listing_textbuf_appendf(buf, ")");
         break;
      }
   }
}

static void listing_render_expr_list_buf(listing_textbuf_t *buf, const expr_list_node_t *node)
{
   int first = 1;
   while (node) {
      if (!first)
         listing_textbuf_appendf(buf, ", ");
      listing_render_expr_buf(buf, node->expr);
      first = 0;
      node = node->next;
   }
}

char *listing_render_stmt_alloc(const stmt_t *stmt)
{
   listing_textbuf_t buf = {0};
   if (!stmt)
      return strdup("");
   if (stmt->label)
      listing_textbuf_appendf(&buf, "%s: ", stmt->label);
   switch (stmt->kind) {
      case STMT_LABEL:
         if (!stmt->label) listing_textbuf_appendf(&buf, "<label>");
         break;
      case STMT_INSN:
         listing_textbuf_appendf(&buf, "%s%s%s", stmt->u.insn.opcode,
            mode_spec_suffix(stmt->u.insn.spec),
            branch_page_spec_suffix(stmt->u.insn.branch_page));
         if (stmt->u.insn.has_operand) {
            listing_textbuf_appendf(&buf, " ");
            if (stmt->u.insn.mode == AM_ACCUMULATOR) listing_textbuf_appendf(&buf, "A");
            else if (stmt->u.insn.mode == AM_IMMEDIATE) {
               listing_textbuf_appendf(&buf, "#"); listing_render_expr_buf(&buf, stmt->u.insn.expr);
            } else if (stmt->u.insn.mode == AM_INDEXED_INDIRECT) {
               listing_textbuf_appendf(&buf, "("); listing_render_expr_buf(&buf, stmt->u.insn.expr); listing_textbuf_appendf(&buf, ",X)");
            } else if (stmt->u.insn.mode == AM_INDIRECT_INDEXED) {
               listing_textbuf_appendf(&buf, "("); listing_render_expr_buf(&buf, stmt->u.insn.expr); listing_textbuf_appendf(&buf, "),Y");
            } else if (stmt->u.insn.mode == AM_INDIRECT) {
               listing_textbuf_appendf(&buf, "("); listing_render_expr_buf(&buf, stmt->u.insn.expr); listing_textbuf_appendf(&buf, ")");
            } else {
               listing_render_expr_buf(&buf, stmt->u.insn.expr);
               if (stmt->u.insn.mode == AM_ZPX_OR_ABSX) listing_textbuf_appendf(&buf, ",X");
               else if (stmt->u.insn.mode == AM_ZPY_OR_ABSY) listing_textbuf_appendf(&buf, ",Y");
            }
         }
         break;
      case STMT_DIR:
         listing_textbuf_appendf(&buf, "%s", stmt->u.dir->name);
         if (stmt->u.dir->kind == DIRARG_EXPR_LIST) {
            listing_textbuf_appendf(&buf, " "); listing_render_expr_list_buf(&buf, stmt->u.dir->exprs);
         } else if (stmt->u.dir->kind == DIRARG_STRING) {
            listing_textbuf_appendf(&buf, " %s", stmt->u.dir->string);
         } else if (stmt->u.dir->kind == DIRARG_STRING_AND_EXPR_LIST) {
            listing_textbuf_appendf(&buf, " %s", stmt->u.dir->string);
            if (stmt->u.dir->exprs) { listing_textbuf_appendf(&buf, ", "); listing_render_expr_list_buf(&buf, stmt->u.dir->exprs); }
         }
         break;
      case STMT_CONST:
         if (stmt->u.cnst.assign_kind == CONST_ASSIGN_SET) listing_textbuf_appendf(&buf, ".set %s = ", stmt->u.cnst.name);
         else if (stmt->u.cnst.assign_kind == CONST_ASSIGN_DEFAULT) listing_textbuf_appendf(&buf, "%s ?= ", stmt->u.cnst.name);
         else listing_textbuf_appendf(&buf, "%s = ", stmt->u.cnst.name);
         listing_render_expr_buf(&buf, stmt->u.cnst.expr);
         break;
   }
   if (!buf.data)
      return strdup("");
   return buf.data;
}

//! @brief Handle listing open logic for assembler listing writer.
int listing_open(listing_writer_t *lst, const char *path)
{
   lst->fp = fopen(path, "w");
   return lst->fp != NULL;
}

//! @brief Handle listing close logic for assembler listing writer.
void listing_close(listing_writer_t *lst)
{
   if (lst->fp) {
      fclose(lst->fp);
      lst->fp = NULL;
   }
}

//! @brief Handle listing write record logic for assembler listing writer.
void listing_write_record(listing_writer_t *lst,
                          const stmt_t *stmt,
                          long addr,
                          const unsigned char *bytes,
                          int byte_count)
{
   int i;

   if (!lst || !lst->fp || !stmt)
      return;

   fprintf(lst->fp, "%-24s %04lX  ",
           stmt->file ? stmt->file : "<input>",
           addr & 0xFFFF);

   for (i = 0; i < 6; i++) {
      if (i < byte_count)
         fprintf(lst->fp, "%02X ", bytes[i]);
      else
         fprintf(lst->fp, "   ");
   }

   fprintf(lst->fp, " %5d  ", stmt->line);
   render_stmt_text(lst->fp, stmt);
   fprintf(lst->fp, "\n");
}

//! @brief Handle listing write no bytes logic for assembler listing writer.
void listing_write_no_bytes(listing_writer_t *lst, const stmt_t *stmt)
{
   if (!lst || !lst->fp || !stmt)
      return;

   fprintf(lst->fp, "%-24s ----  %-18s %5d  ",
           stmt->file ? stmt->file : "<input>",
           "",
           stmt->line);
   render_stmt_text(lst->fp, stmt);
   fprintf(lst->fp, "\n");
}
