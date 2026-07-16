//! @file assembler/listing.c
//! @brief Implements assembly listing generation for the n65 assembler.
//! @ingroup assembler

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
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
         fprintf(fp, "%s%s",
                 stmt->u.insn.opcode,
                 mode_spec_suffix(stmt->u.insn.spec));

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
