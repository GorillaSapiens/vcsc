//! @file assembler/asm_pass.c
//! @brief Implements assembly pass orchestration for the VCSC assembler.
//! @ingroup assembler

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <stdarg.h>
#include "asm_pass.h"
#include "asm_state.h"
#include "opcode.h"
#include "util.h"
#include "xray.h"


//! @brief Parse escaped string into the normalized representation used by assembler pass and relaxation engine.
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
            case 'n':
               ch = '\n';
               break;
            case 'r':
               ch = '\r';
               break;
            case 't':
               ch = '\t';
               break;
            case '0':
               ch = '\0';
               break;
            case '\\':
               ch = '\\';
               break;
            case '"':
               ch = '"';
               break;
            case '\'':
               ch = '\'';
               break;
            default:
               ch = (unsigned char)quoted[i];
               break;
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


//! @brief Return whether branch opcode applies in assembler pass and relaxation engine.
static int is_branch_opcode(const char *opcode)
{
   return !strcmp(opcode, "BCC") ||
          !strcmp(opcode, "BCS") ||
          !strcmp(opcode, "BEQ") ||
          !strcmp(opcode, "BMI") ||
          !strcmp(opcode, "BNE") ||
          !strcmp(opcode, "BPL") ||
          !strcmp(opcode, "BVC") ||
          !strcmp(opcode, "BVS");
}

//! @brief Return whether accum shorthand opcode applies in assembler pass and relaxation engine.
static int is_accum_shorthand_opcode(const char *opcode)
{
   return !strcmp(opcode, "ASL") ||
          !strcmp(opcode, "LSR") ||
          !strcmp(opcode, "ROL") ||
          !strcmp(opcode, "ROR");
}

//! @brief Compute mode and update assembler pass and relaxation engine state once prerequisite pass data is available.
static addr_mode_t normalize_mode(const char *opcode, addr_mode_t mode)
{
   unsigned char raw_opcode;

   if ((is_branch_opcode(opcode) ||
        (opcode_parse_raw_byte(opcode, &raw_opcode) && opcode_raw_is_conditional_branch(raw_opcode))) &&
       mode == AM_ZP_OR_ABS)
      return AM_RELATIVE;

   if ((is_accum_shorthand_opcode(opcode) ||
        (opcode_parse_raw_byte(opcode, &raw_opcode) && opcode_raw_is_accumulator_shorthand(raw_opcode))) &&
       mode == AM_IMPLIED)
      return AM_ACCUMULATOR;

   return mode;
}

//! @brief Handle spec to emit mode logic for assembler pass and relaxation engine.
static int spec_to_emit_mode(mode_spec_t spec, emit_mode_t *out_mode)
{
   switch (spec) {
      case MODE_SPEC_Z:
         *out_mode = EM_ZP;
         return 1;

      case MODE_SPEC_ZX:
         *out_mode = EM_ZPX;
         return 1;

      case MODE_SPEC_ZY:
         *out_mode = EM_ZPY;
         return 1;

      case MODE_SPEC_A:
         *out_mode = EM_ABS;
         return 1;

      case MODE_SPEC_AX:
         *out_mode = EM_ABSX;
         return 1;

      case MODE_SPEC_AY:
         *out_mode = EM_ABSY;
         return 1;

      case MODE_SPEC_I:
         *out_mode = EM_IND;
         return 1;

      case MODE_SPEC_IX:
         *out_mode = EM_INDX;
         return 1;

      case MODE_SPEC_IY:
         *out_mode = EM_INDY;
         return 1;

      default:
         break;
   }

   return 0;
}

//! @brief Handle parsed mode accepts spec logic for assembler pass and relaxation engine.
static int parsed_mode_accepts_spec(addr_mode_t parsed_mode, mode_spec_t spec)
{
   parsed_mode = normalize_mode("", parsed_mode);

   switch (spec) {
      case MODE_SPEC_Z:
      case MODE_SPEC_A:
         return parsed_mode == AM_ZP_OR_ABS;

      case MODE_SPEC_ZX:
      case MODE_SPEC_AX:
         return parsed_mode == AM_ZPX_OR_ABSX;

      case MODE_SPEC_ZY:
      case MODE_SPEC_AY:
         return parsed_mode == AM_ZPY_OR_ABSY;

      case MODE_SPEC_I:
         return parsed_mode == AM_INDIRECT;

      case MODE_SPEC_IX:
         return parsed_mode == AM_INDEXED_INDIRECT;

      case MODE_SPEC_IY:
         return parsed_mode == AM_INDIRECT_INDEXED;

      case MODE_SPEC_NONE:
         return 1;
   }

   return 0;
}


//! @brief Return whether a raw opcode's configured mode accepts the operand shape without a suffix.
static int raw_expected_mode_accepts_operand_shape(emit_mode_t expected_mode, addr_mode_t parsed_mode)
{
   switch (expected_mode) {
      case EM_IMPLIED:
         return parsed_mode == AM_IMPLIED;

      case EM_ACCUMULATOR:
         return parsed_mode == AM_ACCUMULATOR;

      case EM_IMMEDIATE:
         return parsed_mode == AM_IMMEDIATE;

      case EM_ZP:
      case EM_ABS:
         return parsed_mode == AM_ZP_OR_ABS;

      case EM_ZPX:
      case EM_ABSX:
         return parsed_mode == AM_ZPX_OR_ABSX;

      case EM_ZPY:
      case EM_ABSY:
         return parsed_mode == AM_ZPY_OR_ABSY;

      case EM_IND:
         return parsed_mode == AM_INDIRECT;

      case EM_INDX:
         return parsed_mode == AM_INDEXED_INDIRECT;

      case EM_INDY:
         return parsed_mode == AM_INDIRECT_INDEXED;

      case EM_REL:
         return parsed_mode == AM_RELATIVE;

      case EM_REL_LONG:
         return 0;
   }

   return 0;
}

//! @brief Return whether expr is 8-bit value in assembler pass and relaxation engine.
static int expr_is_u8_value(long value)
{
   return value >= 0 && value <= 0xFF;
}

//! @brief Return whether expr is s8 or 8-bit value in assembler pass and relaxation engine.
static int expr_is_s8_or_u8_value(long value)
{
   return value >= -128 && value <= 0xFF;
}

//! @brief Return whether insn is long branch candidate in assembler pass and relaxation engine.
static int insn_is_long_branch_candidate(const insn_info_t *insn, emit_mode_t mode)
{
   return mode == EM_REL && opcode_is_conditional_branch(insn->opcode);
}

//! @brief Return whether insn can relax long branch in assembler pass and relaxation engine.
static int insn_can_relax_long_branch(const stmt_t *stmt, const asm_context_t *ctx)
{
   long value;
   long disp;

   if (!stmt || stmt->kind != STMT_INSN)
      return 0;

   if (stmt->u.insn.final_mode != EM_REL_LONG || !stmt->u.insn.expr)
      return 0;

   if (expr_eval(stmt->u.insn.expr, &ctx->symbols, stmt->scope, stmt->file, stmt->address + 1, &value) != EXPR_EVAL_OK)
      return 0;

   disp = value - (stmt->address + 2);
   return disp >= -128 && disp <= 127;
}


//! @brief Return whether an expression contains any identifier term.
static int expr_contains_ident(const expr_t *expr)
{
   if (!expr)
      return 0;
   switch (expr->kind) {
      case EXPR_IDENT:
         return 1;
      case EXPR_UNARY:
         return expr_contains_ident(expr->u.unary.child);
      case EXPR_BINARY:
         return expr_contains_ident(expr->u.binary.left) ||
                expr_contains_ident(expr->u.binary.right);
      case EXPR_NUMBER:
      case EXPR_CHARCONST:
      case EXPR_PC:
         return 0;
   }
   return 0;
}

//! @brief Return the imported base in a symbol-plus/minus-constant expression.
static const char *expr_reloc_ident(const expr_t *expr)
{
   const char *base;

   if (!expr)
      return NULL;

   switch (expr->kind) {
      case EXPR_IDENT:
         return expr->u.ident;

      case EXPR_UNARY:
         return expr->u.unary.op == EXPR_UOP_POS
            ? expr_reloc_ident(expr->u.unary.child) : NULL;

      case EXPR_BINARY:
         if (expr->u.binary.op == EXPR_BOP_ADD) {
            base = expr_reloc_ident(expr->u.binary.left);
            if (base && !expr_contains_ident(expr->u.binary.right))
               return base;
            base = expr_reloc_ident(expr->u.binary.right);
            if (base && !expr_contains_ident(expr->u.binary.left))
               return base;
         }
         if (expr->u.binary.op == EXPR_BOP_SUB) {
            base = expr_reloc_ident(expr->u.binary.left);
            if (base && !expr_contains_ident(expr->u.binary.right))
               return base;
         }
         return NULL;

      case EXPR_NUMBER:
      case EXPR_CHARCONST:
      case EXPR_PC:
         return NULL;
   }

   return NULL;
}

//! @brief Return whether an operand expression is based on a zero-page import.
static int expr_is_zp_import(const asm_context_t *ctx, const expr_t *expr)
{
   const char *name = expr_reloc_ident(expr);
   return name && import_is_zp(ctx, name);
}

//! @brief Handle choose initial emit mode logic for assembler pass and relaxation engine.
static int choose_initial_emit_mode(const asm_context_t *ctx, const insn_info_t *insn,
                                    emit_mode_t *out_mode, const char **why)
{
   addr_mode_t mode;
   unsigned char dummy;
   int is_raw_opcode;
   int have_raw_expected_mode;
   emit_mode_t raw_expected_mode;
   static char raw_why[160];

   mode = normalize_mode(insn->opcode, insn->mode);
   is_raw_opcode = opcode_parse_raw_byte(insn->opcode, &dummy);
   have_raw_expected_mode = is_raw_opcode && opcode_raw_expected_mode(dummy, &raw_expected_mode);

   if (insn->spec != MODE_SPEC_NONE) {
      if (!parsed_mode_accepts_spec(mode, insn->spec)) {
         if (why)
            *why = "specifier is incompatible with the operand shape";
         return 0;
      }

      if (!spec_to_emit_mode(insn->spec, out_mode)) {
         if (why)
            *why = "unknown addressing-mode specifier";
         return 0;
      }

      if (have_raw_expected_mode && raw_expected_mode != *out_mode) {
         if (why) {
            snprintf(raw_why, sizeof(raw_why),
                     "specifier selects %s but opcode byte expects %s",
                     emit_mode_name(*out_mode), emit_mode_name(raw_expected_mode));
            *why = raw_why;
         }
         return 0;
      }

      return 1;
   }

   if (have_raw_expected_mode) {
      if (!raw_expected_mode_accepts_operand_shape(raw_expected_mode, mode)) {
         if (why) {
            snprintf(raw_why, sizeof(raw_why),
                     "operand shape does not match opcode byte's %s mode",
                     emit_mode_name(raw_expected_mode));
            *why = raw_why;
         }
         return 0;
      }

      *out_mode = raw_expected_mode;
      return 1;
   }

   switch (mode) {
      case AM_IMPLIED:
         *out_mode = EM_IMPLIED;
         return 1;

      case AM_ACCUMULATOR:
         *out_mode = EM_ACCUMULATOR;
         return 1;

      case AM_IMMEDIATE:
         *out_mode = EM_IMMEDIATE;
         return 1;

      case AM_INDEXED_INDIRECT:
         *out_mode = EM_INDX;
         return 1;

      case AM_INDIRECT_INDEXED:
         *out_mode = EM_INDY;
         return 1;

      case AM_INDIRECT:
         *out_mode = EM_IND;
         return 1;

      case AM_RELATIVE:
         *out_mode = EM_REL;
         if (insn_is_long_branch_candidate(insn, *out_mode))
            *out_mode = EM_REL_LONG;
         return 1;

      case AM_ZP_OR_ABS:
         if (expr_is_zp_import(ctx, insn->expr) && opcode_lookup(insn->opcode, EM_ZP, &dummy)) {
            *out_mode = EM_ZP;
            return 1;
         }
         if (is_raw_opcode) {
            if (why)
               *why = "raw opcodes need an explicit mode suffix (.z/.a/.i) for ambiguous operand shapes";
            return 0;
         }
         if (opcode_lookup(insn->opcode, EM_ABS, &dummy)) {
            *out_mode = EM_ABS;
            return 1;
         }
         if (opcode_lookup(insn->opcode, EM_ZP, &dummy)) {
            *out_mode = EM_ZP;
            return 1;
         }
         break;

      case AM_ZPX_OR_ABSX:
         if (expr_is_zp_import(ctx, insn->expr) && opcode_lookup(insn->opcode, EM_ZPX, &dummy)) {
            *out_mode = EM_ZPX;
            return 1;
         }
         if (is_raw_opcode) {
            if (why)
               *why = "raw opcodes need an explicit mode suffix (.zx/.ax) for indexed ambiguous operand shapes";
            return 0;
         }
         if (opcode_lookup(insn->opcode, EM_ABSX, &dummy)) {
            *out_mode = EM_ABSX;
            return 1;
         }
         if (opcode_lookup(insn->opcode, EM_ZPX, &dummy)) {
            *out_mode = EM_ZPX;
            return 1;
         }
         break;

      case AM_ZPY_OR_ABSY:
         if (expr_is_zp_import(ctx, insn->expr) && opcode_lookup(insn->opcode, EM_ZPY, &dummy)) {
            *out_mode = EM_ZPY;
            return 1;
         }
         if (is_raw_opcode) {
            if (why)
               *why = "raw opcodes need an explicit mode suffix (.zy/.ay) for indexed ambiguous operand shapes";
            return 0;
         }
         if (opcode_lookup(insn->opcode, EM_ABSY, &dummy)) {
            *out_mode = EM_ABSY;
            return 1;
         }
         if (opcode_lookup(insn->opcode, EM_ZPY, &dummy)) {
            *out_mode = EM_ZPY;
            return 1;
         }
         break;

      default:
         break;
   }

   if (why)
      *why = "unsupported addressing mode";

   return 0;
}

//! @brief Extract insn size from mode for assembler pass and relaxation engine.
static int insn_size_from_mode(emit_mode_t mode)
{
   return emit_mode_size(mode);
}

//! @brief Handle eval or report logic for assembler pass and relaxation engine.
static int eval_or_report(asm_context_t *ctx,
                          const expr_t *expr,
                          const symtab_t *symbols,
                          const char *scope,
                          const char *file_scope,
                          long pc,
                          long *value,
                          const stmt_t *stmt)
{
   expr_eval_status_t rc;

   rc = expr_eval(expr, symbols, scope, file_scope, pc, value);
   if (rc == EXPR_EVAL_OK)
      return 0;

   if (rc != EXPR_EVAL_UNRESOLVED) {
      asm_error(ctx, stmt, "%s", expr_eval_status_message(rc));
   } else {
      fprintf(stderr, "%s:%d: ", stmt->file ? stmt->file : "<input>", stmt->line);
      expr_fprint(stderr, expr);
      fprintf(stderr, " -> unresolved expression\n");
      ctx->error_count++;
   }

   return 1;
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

//! @brief Return the logical/runtime PC for a segment.
static long segment_logical_pc(const asm_segment_t *seg)
{
   if (seg->rorg_active)
      return seg->rorg_pc;

   return seg->base + seg->pc;
}


typedef struct cond_frame {
   int parent_active;
   int branch_active;
   int any_true;
   int saw_else;
   const stmt_t *start;
   struct cond_frame *next;
} cond_frame_t;


//! @brief Return whether directive is an assembler-time diagnostic directive.
static int directive_is_diagnostic(const char *name)
{
   return name && (!strcmp(name, ".echo") || !strcmp(name, ".error"));
}

//! @brief Decode the single quoted string expected by .echo/.error.
static int directive_decode_message(asm_context_t *ctx,
                                    const stmt_t *stmt,
                                    const directive_info_t *dir,
                                    char *buf,
                                    int buf_cap)
{
   int len;

   if (!dir || dir->kind != DIRARG_STRING || !dir->string || dir->exprs) {
      asm_error(ctx, stmt, "%s expects exactly one quoted string", dir && dir->name ? dir->name : "directive");
      return 0;
   }

   if (!decode_escaped_string(dir->string, (unsigned char *)buf, buf_cap - 1, &len)) {
      asm_error(ctx, stmt, "malformed quoted string");
      return 0;
   }

   if (len >= buf_cap) {
      asm_error(ctx, stmt, "%s message is too long", dir->name);
      return 0;
   }

   buf[len] = '\0';
   return 1;
}

//! @brief Return whether directive name is part of conditional assembly control.
static int directive_is_conditional(const char *name)
{
   return name && (!strcmp(name, ".if") ||
                   !strcmp(name, ".elif") ||
                   !strcmp(name, ".ifdef") ||
                   !strcmp(name, ".ifndef") ||
                   !strcmp(name, ".elifdef") ||
                   !strcmp(name, ".elifndef") ||
                   !strcmp(name, ".else") ||
                   !strcmp(name, ".endif"));
}

//! @brief Return whether condition stack selects ordinary statements for assembly.
static int cond_current_active(const cond_frame_t *stack)
{
   if (!stack)
      return 1;
   return stack->parent_active && stack->branch_active;
}

//! @brief Return whether directive has no arguments.
static int directive_has_no_args(const directive_info_t *dir)
{
   return dir && !dir->exprs && !dir->string;
}

//! @brief Return sole expression argument for a directive.
static expr_t *directive_single_expr(const directive_info_t *dir)
{
   if (!dir || dir->string || !dir->exprs || dir->exprs->next)
      return NULL;
   return dir->exprs->expr;
}

//! @brief Return whether a scoped symbol is defined at this point in the pass.
static int conditional_symbol_defined(asm_context_t *ctx, const stmt_t *stmt, const char *name)
{
   const symbol_t *sym;
   symbol_t *mut;

   if (!ctx || !stmt || !name)
      return 0;

   mut = find_declared_symbol(&ctx->symbols, ctx->prog, stmt, name);
   if (mut && mut->defined)
      return 1;

   sym = symtab_find_const(&ctx->symbols, name);
   return sym && sym->defined;
}

//! @brief Evaluate .if expression to a boolean.
static int conditional_eval_expr(asm_context_t *ctx,
                                 const stmt_t *stmt,
                                 const directive_info_t *dir,
                                 long pc,
                                 int parent_active,
                                 int *truth_out)
{
   expr_t *expr;
   long value;

   *truth_out = 0;
   expr = directive_single_expr(dir);
   if (!expr) {
      asm_error(ctx, stmt, "%s expects exactly one expression", dir->name);
      return 0;
   }

   if (!parent_active)
      return 1;

   if (eval_or_report(ctx, expr, &ctx->symbols, stmt->scope, stmt->file, pc, &value, stmt))
      return 0;

   *truth_out = value != 0;
   return 1;
}

//! @brief Evaluate .ifdef/.ifndef-style symbol condition to a boolean.
static int conditional_eval_defined(asm_context_t *ctx,
                                    const stmt_t *stmt,
                                    const directive_info_t *dir,
                                    int want_defined,
                                    int parent_active,
                                    int *truth_out)
{
   expr_t *expr;
   int is_defined;

   *truth_out = 0;
   expr = directive_single_expr(dir);
   if (!expr || expr->kind != EXPR_IDENT) {
      asm_error(ctx, stmt, "%s expects exactly one symbol name", dir->name);
      return 0;
   }

   if (!parent_active)
      return 1;

   is_defined = conditional_symbol_defined(ctx, stmt, expr->u.ident);
   *truth_out = want_defined ? is_defined : !is_defined;
   return 1;
}

//! @brief Process conditional assembly directive in pass1 and update active stack.
static int conditional_process_directive(asm_context_t *ctx,
                                         stmt_t *stmt,
                                         const directive_info_t *dir,
                                         long pc,
                                         cond_frame_t **stack_io)
{
   cond_frame_t *frame;
   int parent_active;
   int truth;

   if (!dir || !directive_is_conditional(dir->name))
      return 0;

   stmt->active = 1;

   if (!strcmp(dir->name, ".if") ||
       !strcmp(dir->name, ".ifdef") ||
       !strcmp(dir->name, ".ifndef")) {
      parent_active = cond_current_active(*stack_io);
      truth = 0;

      if (!strcmp(dir->name, ".if")) {
         conditional_eval_expr(ctx, stmt, dir, pc, parent_active, &truth);
      } else if (!strcmp(dir->name, ".ifdef")) {
         conditional_eval_defined(ctx, stmt, dir, 1, parent_active, &truth);
      } else {
         conditional_eval_defined(ctx, stmt, dir, 0, parent_active, &truth);
      }

      frame = (cond_frame_t *)calloc(1, sizeof(*frame));
      if (!frame) {
         fprintf(stderr, "out of memory\n");
         exit(1);
      }
      frame->parent_active = parent_active;
      frame->branch_active = truth ? 1 : 0;
      frame->any_true = truth ? 1 : 0;
      frame->saw_else = 0;
      frame->start = stmt;
      frame->next = *stack_io;
      *stack_io = frame;
      return 1;
   }

   if (!strcmp(dir->name, ".elif") ||
       !strcmp(dir->name, ".elifdef") ||
       !strcmp(dir->name, ".elifndef")) {
      frame = *stack_io;
      if (!frame) {
         asm_error(ctx, stmt, "%s without matching .if/.ifdef/.ifndef", dir->name);
         return 1;
      }
      if (frame->saw_else) {
         asm_error(ctx, stmt, "%s after .else", dir->name);
         frame->branch_active = 0;
         return 1;
      }

      truth = 0;
      if (!frame->parent_active || frame->any_true) {
         /* Validate argument shape without evaluating inactive branches. */
         if (!strcmp(dir->name, ".elif")) {
            if (!directive_single_expr(dir))
               asm_error(ctx, stmt, ".elif expects exactly one expression");
         } else {
            expr_t *expr = directive_single_expr(dir);
            if (!expr || expr->kind != EXPR_IDENT)
               asm_error(ctx, stmt, "%s expects exactly one symbol name", dir->name);
         }
         frame->branch_active = 0;
         return 1;
      }

      if (!strcmp(dir->name, ".elif")) {
         conditional_eval_expr(ctx, stmt, dir, pc, 1, &truth);
      } else if (!strcmp(dir->name, ".elifdef")) {
         conditional_eval_defined(ctx, stmt, dir, 1, 1, &truth);
      } else {
         conditional_eval_defined(ctx, stmt, dir, 0, 1, &truth);
      }

      frame->branch_active = truth ? 1 : 0;
      if (truth)
         frame->any_true = 1;
      return 1;
   }

   if (!strcmp(dir->name, ".else")) {
      frame = *stack_io;
      if (!frame) {
         asm_error(ctx, stmt, ".else without matching .if/.ifdef/.ifndef");
         return 1;
      }
      if (!directive_has_no_args(dir))
         asm_error(ctx, stmt, ".else expects no arguments");
      if (frame->saw_else) {
         asm_error(ctx, stmt, "duplicate .else");
         frame->branch_active = 0;
         return 1;
      }

      frame->saw_else = 1;
      frame->branch_active = frame->parent_active && !frame->any_true;
      frame->any_true = 1;
      return 1;
   }

   if (!strcmp(dir->name, ".endif")) {
      frame = *stack_io;
      if (!frame) {
         asm_error(ctx, stmt, ".endif without matching .if/.ifdef/.ifndef");
         return 1;
      }
      if (!directive_has_no_args(dir))
         asm_error(ctx, stmt, ".endif expects no arguments");
      *stack_io = frame->next;
      free(frame);
      return 1;
   }

   return 0;
}

//! @brief Handle segment advance logic for assembler pass and relaxation engine.
static void segment_advance(asm_context_t *ctx, asm_segment_t *seg, const stmt_t *stmt, long amount)
{
   if (amount < 0) {
      asm_error(ctx, stmt, "negative segment advance");
      return;
   }

   seg->pc += amount;
   if (seg->rorg_active)
      seg->rorg_pc += amount;

   if (seg->size >= 0 && seg->pc > seg->size && !seg->overflow_warned) {
      asm_warning(stmt,
                  "segment '%s' overflowed: used $%lX bytes, declared size $%lX",
                  seg->name, seg->pc, seg->size);
      seg->overflow_warned = 1;
   }
}

typedef struct asm_pass_stats {
   int insn_count;
   int dir_count;
   int label_count;
   int const_count;
   int total_bytes;
   int zp_like;
   int abs_like;
   int long_count;
   int long_relax_count;
   int error_count;
} asm_pass_stats_t;

//! @brief Collect pass stats from existing assembler pass and relaxation engine state for a later pass.
static void collect_pass_stats(const asm_context_t *ctx, asm_pass_stats_t *stats)
{
   const stmt_t *stmt;

   memset(stats, 0, sizeof(*stats));

   for (stmt = ctx->prog->head; stmt; stmt = stmt->next) {
      if (!stmt->active)
         continue;

      switch (stmt->kind) {
         case STMT_LABEL:
            stats->label_count++;
            break;

         case STMT_DIR:
            stats->dir_count++;
            break;

         case STMT_CONST:
            stats->const_count++;
            break;

         case STMT_INSN:
            stats->insn_count++;
            stats->total_bytes += stmt->u.insn.size;

            switch (stmt->u.insn.final_mode) {
               case EM_ZP:
               case EM_ZPX:
               case EM_ZPY:
                  stats->zp_like++;
                  break;

               case EM_ABS:
               case EM_ABSX:
               case EM_ABSY:
                  stats->abs_like++;
                  break;

               case EM_REL_LONG:
                  stats->long_count++;
                  if (insn_can_relax_long_branch(stmt, ctx))
                     stats->long_relax_count++;
                  break;

               default:
                  break;
            }
            break;
      }
   }

   stats->error_count = ctx->error_count;
}

//! @brief Emit pass sizes for assembler pass and relaxation engine diagnostics or output files.
static void print_pass_sizes(const asm_pass_stats_t *stats)
{
   printf("   bytes: %d\n", stats->total_bytes);
   printf("   instructions: %d\n", stats->insn_count);
   printf("   directives: %d\n", stats->dir_count);
   printf("   labels: %d\n", stats->label_count);
   printf("   constants: %d\n", stats->const_count);
   printf("   zero-page encodings: %d\n", stats->zp_like);
   printf("   absolute encodings: %d\n", stats->abs_like);
   printf("   long branches: %d\n", stats->long_count);
   printf("   still relaxable: %d\n", stats->long_relax_count);
   printf("   errors: %d\n", stats->error_count);
}

//! @brief Emit change line for assembler pass and relaxation engine diagnostics or output files.
static void print_change_line(const char *label, int before, int after)
{
   int delta;

   if (before == after)
      return;

   delta = after - before;
   printf("   %s: %d -> %d (%+d)\n", label, before, after, delta);
}

//! @brief Emit pass changes for assembler pass and relaxation engine diagnostics or output files.
static void print_pass_changes(const asm_pass_stats_t *before, const asm_pass_stats_t *after)
{
   print_change_line("bytes", before->total_bytes, after->total_bytes);
   print_change_line("instructions", before->insn_count, after->insn_count);
   print_change_line("directives", before->dir_count, after->dir_count);
   print_change_line("labels", before->label_count, after->label_count);
   print_change_line("constants", before->const_count, after->const_count);
   print_change_line("zero-page encodings", before->zp_like, after->zp_like);
   print_change_line("absolute encodings", before->abs_like, after->abs_like);
   print_change_line("long branches", before->long_count, after->long_count);
   print_change_line("still relaxable", before->long_relax_count, after->long_relax_count);
   print_change_line("errors", before->error_count, after->error_count);
}

//! @brief Handle trace pass begin logic for assembler pass and relaxation engine.
static void trace_pass_begin(int pass_index)
{
   if (!assembler_get_xray(ASM_XRAY_PASSES))
      return;

   printf("pass %03d: begin\n", pass_index);
}

//! @brief Handle pass stats differ logic for assembler pass and relaxation engine.
static int pass_stats_differ(const asm_pass_stats_t *before, const asm_pass_stats_t *after)
{
   return memcmp(before, after, sizeof(*before)) != 0;
}

//! @brief Handle trace pass initial sizes logic for assembler pass and relaxation engine.
static void trace_pass_initial_sizes(const asm_pass_stats_t *stats)
{
   if (!assembler_get_xray(ASM_XRAY_PASSES))
      return;

   print_pass_sizes(stats);
}

//! @brief Handle trace pass changes logic for assembler pass and relaxation engine.
static void trace_pass_changes(const asm_pass_stats_t *before, const asm_pass_stats_t *after)
{
   if (!assembler_get_xray(ASM_XRAY_PASSES))
      return;

   print_pass_changes(before, after);
}

//! @brief Handle trace pass stable logic for assembler pass and relaxation engine.
static void trace_pass_stable(int pass_index, const asm_pass_stats_t *stats)
{
   if (!assembler_get_xray(ASM_XRAY_PASSES))
      return;

   printf("pass %03d: stable\n", pass_index);
   print_pass_sizes(stats);
}

//! @brief Handle asm context init logic for assembler pass and relaxation engine.
void asm_context_init(asm_context_t *ctx, program_ir_t *prog, listing_writer_t *listing, int object_mode_o26)
{
   stmt_t *stmt;
   const char *why;

   ctx->prog = prog;
   ctx->origin = 0;
   symtab_init(&ctx->symbols);
   ihex_image_init(&ctx->image);
   ctx->listing = listing;
   ctx->error_count = 0;
   ctx->object_mode_o26 = object_mode_o26;
   ctx->imports = NULL;
   ctx->weaks = NULL;
   ctx->segments = NULL;

   asm_prepare_context_state(ctx);
   /* Addressing-mode selection happens before the first relaxation pass, so
      collect .importzp/.zpimport declarations now.  Otherwise unresolved
      zero-page imports default to absolute modes and cycle-counted modules gain
      an extra byte and often an extra cycle per access. */
   gather_imports(ctx);

   for (stmt = prog->head; stmt; stmt = stmt->next) {
      if (stmt->kind != STMT_INSN)
         continue;

      if (!choose_initial_emit_mode(ctx, &stmt->u.insn, &stmt->u.insn.final_mode, &why)) {
         asm_error(ctx, stmt, "%s%s ... %s",
                   stmt->u.insn.opcode,
                   mode_spec_suffix(stmt->u.insn.spec),
                   why);
         stmt->u.insn.final_mode = EM_IMPLIED;
         stmt->u.insn.size = 1;
      } else {
         stmt->u.insn.size = insn_size_from_mode(stmt->u.insn.final_mode);
      }
   }
}

//! @brief Release context free storage owned by assembler pass and relaxation engine.
void asm_context_free(asm_context_t *ctx)
{
   symtab_free(&ctx->symbols);
   asm_free_context_state(ctx);
}


//! @brief Return whether a constant-like statement should participate in deferred resolution.
static int const_stmt_deferred_resolution_applies(const stmt_t *stmt)
{
   return stmt && stmt->kind == STMT_CONST && stmt->active &&
          stmt->u.cnst.assign_kind != CONST_ASSIGN_SET && stmt->u.cnst.applied;
}

//! @brief Process an immutable, default, or mutable assembler symbol statement in pass 1.
static void process_const_statement_pass1(asm_context_t *ctx, stmt_t *stmt, long pc_logical)
{
   symbol_t *sym;
   long value;

   if (!ctx || !stmt || stmt->kind != STMT_CONST)
      return;

   stmt->u.cnst.applied = 1;

   if (stmt->u.cnst.assign_kind == CONST_ASSIGN_DEFAULT) {
      sym = find_declared_symbol(&ctx->symbols, ctx->prog, stmt, stmt->u.cnst.name);
      if (sym) {
         stmt->u.cnst.applied = 0;
         return;
      }

      if (!sym) {
         if (!declare_symbol_or_report(ctx, stmt->u.cnst.name, stmt)) {
            stmt->u.cnst.applied = 0;
            return;
         }
         sym = find_declared_symbol(&ctx->symbols, ctx->prog, stmt, stmt->u.cnst.name);
      }

      if (sym && expr_eval(stmt->u.cnst.expr, &ctx->symbols, stmt->scope, stmt->file, pc_logical, &value) == EXPR_EVAL_OK)
         symtab_set_value_segment(sym, value, O26_SEG_ABS);
      return;
   }

   if (stmt->u.cnst.assign_kind == CONST_ASSIGN_SET) {
      sym = find_declared_symbol(&ctx->symbols, ctx->prog, stmt, stmt->u.cnst.name);
      if (sym && !sym->mutable) {
         asm_error(ctx, stmt, ".set cannot update immutable symbol '%s'", stmt->u.cnst.name);
         return;
      }

      if (!sym) {
         if (!declare_symbol_or_report(ctx, stmt->u.cnst.name, stmt))
            return;
         sym = find_declared_symbol(&ctx->symbols, ctx->prog, stmt, stmt->u.cnst.name);
      }

      if (!sym)
         return;

      symtab_set_mutable(sym, 1);
      if (eval_or_report(ctx, stmt->u.cnst.expr, &ctx->symbols, stmt->scope, stmt->file, pc_logical, &value, stmt))
         return;
      symtab_set_value_segment(sym, value, O26_SEG_ABS);
      return;
   }

   if (declare_symbol_or_report(ctx, stmt->u.cnst.name, stmt)) {
      sym = find_declared_symbol(&ctx->symbols, ctx->prog, stmt, stmt->u.cnst.name);
      if (sym && expr_eval(stmt->u.cnst.expr, &ctx->symbols, stmt->scope, stmt->file, pc_logical, &value) == EXPR_EVAL_OK)
         symtab_set_value_segment(sym, value, O26_SEG_ABS);
   }
}

//! @brief Compute constants and update assembler pass and relaxation engine state once prerequisite pass data is available.
static int resolve_constants(asm_context_t *ctx)
{
   int iter;
   int changed;
   stmt_t *stmt;

   for (iter = 0; iter < 64; iter++) {
      changed = 0;

      for (stmt = ctx->prog->head; stmt; stmt = stmt->next) {
         const symbol_t *sym;
         long value;
         symbol_t *mut;

         if (!const_stmt_deferred_resolution_applies(stmt))
            continue;

         if (expr_eval(stmt->u.cnst.expr, &ctx->symbols, stmt->scope, stmt->file, stmt->address, &value) != EXPR_EVAL_OK)
            continue;

         sym = find_declared_symbol(&ctx->symbols, ctx->prog, stmt, stmt->u.cnst.name);
         if (!sym)
            continue;

         if (!sym->defined || sym->value != value) {
            mut = find_declared_symbol(&ctx->symbols, ctx->prog, stmt, stmt->u.cnst.name);
            symtab_set_value_segment(mut, value, O26_SEG_ABS);
            changed = 1;
         }
      }

      if (!changed)
         break;
   }

   for (stmt = ctx->prog->head; stmt; stmt = stmt->next) {
      const symbol_t *sym;

      if (!const_stmt_deferred_resolution_applies(stmt))
         continue;

      sym = find_declared_symbol(&ctx->symbols, ctx->prog, stmt, stmt->u.cnst.name);
      if (!sym || !sym->defined) {
         eval_or_report(ctx, stmt->u.cnst.expr, &ctx->symbols, stmt->scope, stmt->file, stmt->address, &stmt->address, stmt);
      }
   }

   return 0;
}

//! @brief Handle asm pass1 logic for assembler pass and relaxation engine.
int asm_pass1(asm_context_t *ctx, int pass_index)
{
   stmt_t *stmt;
   cond_frame_t *cond_stack;

   cond_stack = NULL;

   symtab_free(&ctx->symbols);
   symtab_init(&ctx->symbols);

   reset_segment_pcs(ctx);
   publish_segment_symbols(ctx);
   if (ctx->object_mode_o26) {
      stmt_t *wstmt;
      for (wstmt = ctx->prog->head; wstmt; wstmt = wstmt->next) {
         if (wstmt->kind != STMT_DIR || !wstmt->u.dir)
            continue;
         if (!strcmp(wstmt->u.dir->name, ".segmentdef")) {
            asm_warning(wstmt, ".segmentdef is ignored when writing o26 object files");
         } else if (!strcmp(wstmt->u.dir->name, ".org")) {
            asm_warning(wstmt, ".org in o26 object mode changes the relative offset within the segment; no absolute placement is recorded");
         }
      }
   } else {
      gather_segment_defs(ctx);
      validate_segment_defs(ctx);
   }

   for (stmt = ctx->prog->head; stmt; stmt = stmt->next) {
      asm_segment_t *seg;
      long pc_abs;
      long pc_logical;
      symbol_t *sym;

      seg = segment_find(ctx, stmt->segment ? stmt->segment : DEFAULT_SEGMENT_NAME);
      if (!seg) {
         asm_error(ctx, stmt, "unknown segment '%s'", stmt->segment ? stmt->segment : DEFAULT_SEGMENT_NAME);
         continue;
      }

      pc_abs = seg->base + seg->pc;
      pc_logical = segment_logical_pc(seg);
      stmt->emit_address = pc_abs;
      stmt->address = pc_logical;
      stmt->rorg_active = seg->rorg_active;
      stmt->active = cond_current_active(cond_stack);

      if (stmt->kind == STMT_DIR && stmt->u.dir && directive_is_conditional(stmt->u.dir->name)) {
         conditional_process_directive(ctx, stmt, stmt->u.dir, pc_logical, &cond_stack);
         continue;
      }

      if (!stmt->active)
         continue;

      if (stmt->label) {
         if (declare_symbol_or_report(ctx, stmt->label, stmt)) {
            sym = find_declared_symbol(&ctx->symbols, ctx->prog, stmt, stmt->label);
            if (seg->rorg_active) {
               symtab_set_value_segment(sym, pc_logical, O26_SEG_ABS);
            } else {
               symtab_set_value_segment_named(sym, pc_logical,
                                      segment_name_to_o26(stmt->segment ? stmt->segment : DEFAULT_SEGMENT_NAME),
                                      stmt->segment ? stmt->segment : DEFAULT_SEGMENT_NAME);
            }
         }
      }

      if (stmt->kind == STMT_DIR && stmt->u.dir && !strcmp(stmt->u.dir->name, ".proc")) {
         const char *proc_name = proc_decl_name(stmt);
         if (!proc_name) {
            asm_error(ctx, stmt, ".proc expects exactly one identifier name");
         } else if (declare_symbol_or_report(ctx, proc_name, stmt)) {
            sym = find_declared_symbol(&ctx->symbols, ctx->prog, stmt, proc_name);
            if (seg->rorg_active) {
               symtab_set_value_segment(sym, pc_logical, O26_SEG_ABS);
            } else {
               symtab_set_value_segment_named(sym, pc_logical,
                                      segment_name_to_o26(stmt->segment ? stmt->segment : DEFAULT_SEGMENT_NAME),
                                      stmt->segment ? stmt->segment : DEFAULT_SEGMENT_NAME);
            }
         }
      }

      switch (stmt->kind) {
         case STMT_LABEL:
            break;

         case STMT_CONST:
            process_const_statement_pass1(ctx, stmt, pc_logical);
            break;

         case STMT_INSN:
            segment_advance(ctx, seg, stmt, stmt->u.insn.size);
            break;

         case STMT_DIR:
            if (!strcmp(stmt->u.dir->name, ".rorg")) {
               long new_logical;

               if (!stmt->u.dir->exprs || stmt->u.dir->exprs->next) {
                  asm_error(ctx, stmt, ".rorg expects exactly one expression");
                  break;
               }

               if (eval_or_report(ctx, stmt->u.dir->exprs->expr, &ctx->symbols, stmt->scope, stmt->file, pc_logical, &new_logical, stmt))
                  break;

               seg->rorg_active = 1;
               seg->rorg_pc = new_logical;
               break;
            }

            if (!strcmp(stmt->u.dir->name, ".rend")) {
               if (stmt->u.dir->exprs) {
                  asm_error(ctx, stmt, ".rend expects no arguments");
                  break;
               }

               if (!seg->rorg_active) {
                  asm_error(ctx, stmt, ".rend without active .rorg");
                  break;
               }

               seg->rorg_active = 0;
               seg->rorg_pc = 0;
               break;
            }

            if (!strcmp(stmt->u.dir->name, ".pagecontain")) {
               if (stmt->u.dir->exprs || stmt->u.dir->string) {
                  asm_error(ctx, stmt, ".pagecontain expects no arguments");
                  break;
               }
               seg->page_contained = 1;
               break;
            }

            if (!strcmp(stmt->u.dir->name, ".segment") ||
                !strcmp(stmt->u.dir->name, ".segmentdef") ||
                !strcmp(stmt->u.dir->name, ".global") ||
                !strcmp(stmt->u.dir->name, ".export") ||
                !strcmp(stmt->u.dir->name, ".import") ||
                !strcmp(stmt->u.dir->name, ".globalzp") ||
                !strcmp(stmt->u.dir->name, ".exportzp") ||
                !strcmp(stmt->u.dir->name, ".importzp") ||
                !strcmp(stmt->u.dir->name, ".zpglobal") ||
                !strcmp(stmt->u.dir->name, ".zpexport") ||
                !strcmp(stmt->u.dir->name, ".zpimport") ||
                !strcmp(stmt->u.dir->name, ".weak") ||
                !strcmp(stmt->u.dir->name, ".proc") ||
                !strcmp(stmt->u.dir->name, ".endproc")) {
               break;
            }

            if (!strcmp(stmt->u.dir->name, ".org")) {
               long new_abs;
               long new_pc;

               if (seg->rorg_active) {
                  asm_error(ctx, stmt, ".org is not allowed while .rorg is active; use .rend first");
                  break;
               }

               if (!stmt->u.dir->exprs || stmt->u.dir->exprs->next) {
                  asm_error(ctx, stmt, ".org expects exactly one expression");
                  break;
               }

               if (eval_or_report(ctx, stmt->u.dir->exprs->expr, &ctx->symbols, stmt->scope, stmt->file, pc_logical, &new_abs, stmt))
                  break;

               new_pc = new_abs - seg->base;
               if (new_pc < 0) {
                  asm_error(ctx, stmt, ".org address $%lX is below base of segment '%s' ($%lX)",
                            new_abs, seg->name, seg->base);
                  break;
               }

               seg->pc = new_pc;
               if (seg->size >= 0 && seg->pc > seg->size && !seg->overflow_warned) {
                  asm_warning(stmt,
                              "segment '%s' overflowed: used $%lX bytes, declared size $%lX",
                              seg->name, seg->pc, seg->size);
                  seg->overflow_warned = 1;
               }
               break;
            }

            if (!strcmp(stmt->u.dir->name, ".align")) {
               const expr_list_node_t *args = stmt->u.dir->exprs;
               long boundary;
               long offset = 0;
               long count;

               if (!args || (args->next && args->next->next)) {
                  asm_error(ctx, stmt, ".align expects one or two expressions");
                  break;
               }

               if (eval_or_report(ctx, args->expr, &ctx->symbols, stmt->scope, stmt->file, pc_logical, &boundary, stmt))
                  break;
               if (args->next && eval_or_report(ctx, args->next->expr, &ctx->symbols, stmt->scope, stmt->file, pc_logical, &offset, stmt))
                  break;

               if (boundary <= 0) {
                  asm_error(ctx, stmt, ".align requires a positive boundary");
                  break;
               }
               if (offset < 0 || offset >= boundary) {
                  asm_error(ctx, stmt, ".align offset must be from zero through boundary minus one");
                  break;
               }

               count = align_padding_for_address(pc_logical, boundary, offset);
               segment_advance(ctx, seg, stmt, count);
               break;
            }

            if (!strcmp(stmt->u.dir->name, ".byte")) {
               int count = 0;
               const expr_list_node_t *node;

               for (node = stmt->u.dir->exprs; node; node = node->next)
                  count++;
               segment_advance(ctx, seg, stmt, count);
               break;
            }

            if (!strcmp(stmt->u.dir->name, ".word")) {
               int count = 0;
               const expr_list_node_t *node;

               for (node = stmt->u.dir->exprs; node; node = node->next)
                  count++;
               segment_advance(ctx, seg, stmt, count * 2);
               break;
            }

            if (!strcmp(stmt->u.dir->name, ".text") ||
                !strcmp(stmt->u.dir->name, ".ascii")) {
               int len = 0;

               if (stmt->u.dir->string && !decode_escaped_string(stmt->u.dir->string, NULL, 0, &len)) {
                  asm_error(ctx, stmt, "malformed quoted string");
                  break;
               }

               segment_advance(ctx, seg, stmt, len);
               break;
            }

            if (!strcmp(stmt->u.dir->name, ".asciiz")) {
               int len = 0;

               if (stmt->u.dir->string && !decode_escaped_string(stmt->u.dir->string, NULL, 0, &len)) {
                  asm_error(ctx, stmt, "malformed quoted string");
                  break;
               }

               segment_advance(ctx, seg, stmt, len + 1);
               break;
            }

            if (!strcmp(stmt->u.dir->name, ".res")) {
               long value;

               if (!stmt->u.dir->exprs || stmt->u.dir->exprs->next) {
                  asm_error(ctx, stmt, ".res expects exactly one expression");
                  break;
               }

               if (eval_or_report(ctx, stmt->u.dir->exprs->expr, &ctx->symbols, stmt->scope, stmt->file, pc_logical, &value, stmt))
                  break;

               if (value < 0) {
                  asm_error(ctx, stmt, ".res requires a non-negative size");
                  break;
               }

               segment_advance(ctx, seg, stmt, value);
               break;
            }

            break;
      }
   }

   while (cond_stack) {
      asm_error(ctx, cond_stack->start, "unterminated conditional block");
      {
         cond_frame_t *next = cond_stack->next;
         free(cond_stack);
         cond_stack = next;
      }
   }

   snapshot_segment_used_sizes(ctx);
   publish_segment_symbols(ctx);
   resolve_constants(ctx);
   gather_imports(ctx);
   validate_imports(ctx);
   (void)pass_index;
   return 0;
}


//! @brief Return whether expr is imported zero-page reference in assembler pass and relaxation engine.
static int expr_is_imported_zp_reference(const asm_context_t *ctx, const expr_t *expr)
{
   return expr_is_zp_import(ctx, expr);
}

//! @brief Return whether relax to zero-page family applies in assembler pass and relaxation engine.
static int can_relax_to_zp_family(const insn_info_t *insn, emit_mode_t current_mode, emit_mode_t *relaxed_mode)
{
   unsigned char dummy;

   if (insn->spec != MODE_SPEC_NONE)
      return 0;

   switch (current_mode) {
      case EM_ABS:
         if (opcode_lookup(insn->opcode, EM_ZP, &dummy)) {
            *relaxed_mode = EM_ZP;
            return 1;
         }
         break;

      case EM_ABSX:
         if (opcode_lookup(insn->opcode, EM_ZPX, &dummy)) {
            *relaxed_mode = EM_ZPX;
            return 1;
         }
         break;

      case EM_ABSY:
         if (opcode_lookup(insn->opcode, EM_ZPY, &dummy)) {
            *relaxed_mode = EM_ZPY;
            return 1;
         }
         break;

      default:
         break;
   }

   return 0;
}

//! @brief Handle asm relax logic for assembler pass and relaxation engine.
int asm_relax(asm_context_t *ctx)
{
   int iter;
   int changed;
   int have_previous_stats = 0;
   stmt_t *stmt;
   asm_segment_t *seg;
   asm_pass_stats_t previous_stats;

   for (iter = 1; iter <= 50; iter++) {
      long segment_signature_before = 0;
      long segment_signature_after = 0;
      asm_pass_stats_t layout_stats;
      asm_pass_stats_t relaxed_stats;

      trace_pass_begin(iter);

      for (seg = ctx->segments; seg; seg = seg->next) {
         segment_signature_before ^= seg->base;
         segment_signature_before ^= (seg->size << 1);
         segment_signature_before ^= (seg->used_size << 2);
      }

      asm_pass1(ctx, iter);
      collect_pass_stats(ctx, &layout_stats);

      if (!have_previous_stats) {
         trace_pass_initial_sizes(&layout_stats);
      } else {
         if (pass_stats_differ(&previous_stats, &layout_stats))
            trace_pass_changes(&previous_stats, &layout_stats);
      }
      previous_stats = layout_stats;
      have_previous_stats = 1;

      for (seg = ctx->segments; seg; seg = seg->next) {
         segment_signature_after ^= seg->base;
         segment_signature_after ^= (seg->size << 1);
         segment_signature_after ^= (seg->used_size << 2);
      }

      changed = (segment_signature_before != segment_signature_after);

      for (stmt = ctx->prog->head; stmt; stmt = stmt->next) {
         long value;
         emit_mode_t candidate;

         if (stmt->kind != STMT_INSN)
            continue;

         if (stmt->u.insn.final_mode == EM_REL_LONG && insn_can_relax_long_branch(stmt, ctx)) {
            stmt->u.insn.final_mode = EM_REL;
            stmt->u.insn.size = insn_size_from_mode(EM_REL);
            changed = 1;
            continue;
         }

         if (!can_relax_to_zp_family(&stmt->u.insn, stmt->u.insn.final_mode, &candidate))
            continue;

         if (!stmt->u.insn.expr)
            continue;

         if (expr_eval(stmt->u.insn.expr, &ctx->symbols, stmt->scope, stmt->file, stmt->address, &value) != EXPR_EVAL_OK) {
            if (!expr_is_imported_zp_reference(ctx, stmt->u.insn.expr))
               continue;
         } else if (!expr_is_u8_value(value)) {
            continue;
         }

         if (candidate != stmt->u.insn.final_mode) {
            stmt->u.insn.final_mode = candidate;
            stmt->u.insn.size = insn_size_from_mode(candidate);
            changed = 1;
         }
      }

      collect_pass_stats(ctx, &relaxed_stats);
      if (pass_stats_differ(&previous_stats, &relaxed_stats))
         trace_pass_changes(&previous_stats, &relaxed_stats);
      previous_stats = relaxed_stats;

      if (!changed) {
         trace_pass_stable(iter, &relaxed_stats);
         break;
      }
   }

   return ctx->error_count ? 1 : 0;
}

//! @brief Emit byte for assembler pass and relaxation engine diagnostics or output files.
static int emit_byte(asm_context_t *ctx, long addr, unsigned char b, const stmt_t *stmt)
{
   if (!ihex_write_byte(&ctx->image, addr, b)) {
      asm_error(ctx, stmt, "output address out of range: $%lX", addr);
      return 0;
   }

   return 1;
}

//! @brief Emit word for assembler pass and relaxation engine diagnostics or output files.
static int emit_word(asm_context_t *ctx, long addr, unsigned short w, const stmt_t *stmt)
{
   if (!ihex_write_word(&ctx->image, addr, w)) {
      asm_error(ctx, stmt, "output address out of range: $%lX", addr);
      return 0;
   }

   return 1;
}

//! @brief Reset mutable assembler-time symbols before sequential emission.
static void reset_mutable_symbols_for_emit(symtab_t *symbols)
{
   symbol_t *sym;

   if (!symbols)
      return;

   for (sym = symbols->head; sym; sym = sym->next) {
      if (sym->mutable)
         sym->defined = 0;
   }
}

//! @brief Apply a .set statement during sequential emission.
static int process_set_statement_emit(asm_context_t *ctx, const stmt_t *stmt)
{
   symbol_t *sym;
   long value;

   if (!ctx || !stmt || stmt->kind != STMT_CONST || stmt->u.cnst.assign_kind != CONST_ASSIGN_SET)
      return 0;

   if (!stmt->active)
      return 0;

   sym = find_declared_symbol(&ctx->symbols, ctx->prog, stmt, stmt->u.cnst.name);
   if (!sym || !sym->mutable) {
      asm_error(ctx, stmt, "internal error: missing mutable symbol '%s'", stmt->u.cnst.name);
      return -1;
   }

   if (eval_or_report(ctx, stmt->u.cnst.expr, &ctx->symbols, stmt->scope, stmt->file, stmt->address, &value, stmt))
      return -1;

   symtab_set_value_segment(sym, value, O26_SEG_ABS);
   return 0;
}

/* returns 0 success, -1 statement error */
//! @brief Handle directive emit pass2 logic for assembler pass and relaxation engine.
static int directive_emit_pass2(asm_context_t *ctx,
                                const stmt_t *stmt,
                                const directive_info_t *dir)
{
   const expr_list_node_t *node;
   long value;
   long pc;
   long logical_pc;
   long start_pc;
   unsigned char rec[256];
   int rec_count;

   start_pc = stmt->address;
   pc = stmt->emit_address;
   logical_pc = stmt->address;
   rec_count = 0;

   if (!stmt->active) {
      if (ctx->listing)
         listing_write_no_bytes(ctx->listing, stmt);
      return 0;
   }

   if (directive_is_diagnostic(dir->name)) {
      char msg[4096];

      if (!stmt->active) {
         if (ctx->listing)
            listing_write_no_bytes(ctx->listing, stmt);
         return 0;
      }

      if (!directive_decode_message(ctx, stmt, dir, msg, (int)sizeof(msg)))
         return -1;

      if (!strcmp(dir->name, ".echo")) {
         fprintf(stderr, "%s\n", msg);
      } else {
         asm_error(ctx, stmt, "%s", msg);
      }

      if (ctx->listing)
         listing_write_no_bytes(ctx->listing, stmt);
      return 0;
   }

   if (!strcmp(dir->name, ".org") ||
       !strcmp(dir->name, ".rorg") ||
       !strcmp(dir->name, ".rend") ||
       !strcmp(dir->name, ".segment") ||
       !strcmp(dir->name, ".segmentdef") ||
       !strcmp(dir->name, ".pagecontain") ||
       !strcmp(dir->name, ".global") ||
       !strcmp(dir->name, ".export") ||
       !strcmp(dir->name, ".import") ||
       !strcmp(dir->name, ".globalzp") ||
       !strcmp(dir->name, ".exportzp") ||
       !strcmp(dir->name, ".importzp") ||
       !strcmp(dir->name, ".zpglobal") ||
       !strcmp(dir->name, ".zpexport") ||
       !strcmp(dir->name, ".zpimport") ||
       !strcmp(dir->name, ".weak") ||
       !strcmp(dir->name, ".proc") ||
       !strcmp(dir->name, ".endproc") ||
       directive_is_conditional(dir->name)) {
      if (ctx->listing)
         listing_write_no_bytes(ctx->listing, stmt);
      return 0;
   }

   if (!strcmp(dir->name, ".align")) {
      const expr_list_node_t *args = dir->exprs;
      long boundary;
      long offset = 0;
      long count;
      long i;

      if (!args || (args->next && args->next->next)) {
         asm_error(ctx, stmt, ".align expects one or two expressions");
         return -1;
      }

      if (eval_or_report(ctx, args->expr, &ctx->symbols, stmt->scope, stmt->file, logical_pc, &boundary, stmt))
         return -1;
      if (args->next && eval_or_report(ctx, args->next->expr, &ctx->symbols, stmt->scope, stmt->file, logical_pc, &offset, stmt))
         return -1;

      if (boundary <= 0) {
         asm_error(ctx, stmt, ".align requires a positive boundary");
         return -1;
      }
      if (offset < 0 || offset >= boundary) {
         asm_error(ctx, stmt, ".align offset must be from zero through boundary minus one");
         return -1;
      }

      count = align_padding_for_address(logical_pc, boundary, offset);
      for (i = 0; i < count; i++) {
         if (!emit_byte(ctx, pc, 0x00, stmt))
            return -1;
         if (rec_count < (int)sizeof(rec))
            rec[rec_count++] = 0x00;
         pc++;
         logical_pc++;
      }

      if (ctx->listing) {
         if (rec_count > 0)
            listing_write_record(ctx->listing, stmt, start_pc, rec, rec_count);
         else
            listing_write_no_bytes(ctx->listing, stmt);
      }
      return 0;
   }

   if (!strcmp(dir->name, ".byte")) {
      for (node = dir->exprs; node; node = node->next) {
         if (eval_or_report(ctx, node->expr, &ctx->symbols, stmt->scope, stmt->file, logical_pc, &value, stmt))
            return -1;
         if (!emit_byte(ctx, pc, (unsigned char)(value & 0xFF), stmt))
            return -1;
         if (rec_count < (int)sizeof(rec))
            rec[rec_count++] = (unsigned char)(value & 0xFF);
         pc++;
         logical_pc++;
      }
      if (ctx->listing)
         listing_write_record(ctx->listing, stmt, start_pc, rec, rec_count);
      return 0;
   }

   if (!strcmp(dir->name, ".word")) {
      for (node = dir->exprs; node; node = node->next) {
         if (eval_or_report(ctx, node->expr, &ctx->symbols, stmt->scope, stmt->file, logical_pc, &value, stmt))
            return -1;
         if (!emit_word(ctx, pc, (unsigned short)(value & 0xFFFF), stmt))
            return -1;
         if (rec_count + 1 < (int)sizeof(rec)) {
            rec[rec_count++] = (unsigned char)(value & 0xFF);
            rec[rec_count++] = (unsigned char)((value >> 8) & 0xFF);
         }
         pc += 2;
         logical_pc += 2;
      }
      if (ctx->listing)
         listing_write_record(ctx->listing, stmt, start_pc, rec, rec_count);
      return 0;
   }

   if (!strcmp(dir->name, ".text") || !strcmp(dir->name, ".ascii")) {
      unsigned char buf[256];
      int len;
      int i;

      if (!dir->string) {
         if (ctx->listing)
            listing_write_no_bytes(ctx->listing, stmt);
         return 0;
      }

      if (!decode_escaped_string(dir->string, buf, (int)sizeof(buf), &len)) {
         asm_error(ctx, stmt, "malformed quoted string");
         return -1;
      }

      for (i = 0; i < len; i++) {
         if (!emit_byte(ctx, pc, buf[i], stmt))
            return -1;
         if (rec_count < (int)sizeof(rec))
            rec[rec_count++] = buf[i];
         pc++;
         logical_pc++;
      }

      if (ctx->listing)
         listing_write_record(ctx->listing, stmt, start_pc, rec, rec_count);
      return 0;
   }

   if (!strcmp(dir->name, ".asciiz")) {
      unsigned char buf[256];
      int len;
      int i;

      if (!dir->string) {
         if (!emit_byte(ctx, pc, 0x00, stmt))
            return -1;
         rec[rec_count++] = 0x00;
         if (ctx->listing)
            listing_write_record(ctx->listing, stmt, start_pc, rec, rec_count);
         return 0;
      }

      if (!decode_escaped_string(dir->string, buf, (int)sizeof(buf), &len)) {
         asm_error(ctx, stmt, "malformed quoted string");
         return -1;
      }

      for (i = 0; i < len; i++) {
         if (!emit_byte(ctx, pc, buf[i], stmt))
            return -1;
         if (rec_count < (int)sizeof(rec))
            rec[rec_count++] = buf[i];
         pc++;
         logical_pc++;
      }

      if (!emit_byte(ctx, pc, 0x00, stmt))
         return -1;
      if (rec_count < (int)sizeof(rec))
         rec[rec_count++] = 0x00;
      logical_pc++;

      if (ctx->listing)
         listing_write_record(ctx->listing, stmt, start_pc, rec, rec_count);
      return 0;
   }

   if (!strcmp(dir->name, ".res")) {
      long i;

      if (!dir->exprs || dir->exprs->next) {
         asm_error(ctx, stmt, ".res expects exactly one expression");
         return -1;
      }

      if (eval_or_report(ctx, dir->exprs->expr, &ctx->symbols, stmt->scope, stmt->file, logical_pc, &value, stmt))
         return -1;

      if (value < 0) {
         asm_error(ctx, stmt, ".res requires a non-negative size");
         return -1;
      }

      for (i = 0; i < value; i++) {
         if (!emit_byte(ctx, pc, 0x00, stmt))
            return -1;
         if (rec_count < (int)sizeof(rec))
            rec[rec_count++] = 0x00;
         pc++;
         logical_pc++;
      }

      if (ctx->listing)
         listing_write_record(ctx->listing, stmt, start_pc, rec, rec_count);
      return 0;
   }

   asm_error(ctx, stmt, "unhandled directive %s", dir->name);
   return -1;
}

/* returns 0 success, -1 statement error */
//! @brief Handle insn emit pass2 logic for assembler pass and relaxation engine.
static int insn_emit_pass2(asm_context_t *ctx,
                           const stmt_t *stmt,
                           const insn_info_t *insn)
{
   long value;
   unsigned char opcode;
   unsigned char rec[8];
   int rec_count;
   long start_pc;
   long pc;
   long logical_pc;
   emit_mode_t emode;

   emode = insn->final_mode;
   start_pc = stmt->address;
   pc = stmt->emit_address;
   logical_pc = stmt->address;
   rec_count = 0;

   if (!stmt->active) {
      if (ctx->listing)
         listing_write_no_bytes(ctx->listing, stmt);
      return 0;
   }

   if (emode == EM_REL_LONG) {
      unsigned char inv_opcode;

      if (!opcode_invert_branch(insn->opcode, &inv_opcode)) {
         asm_error(ctx, stmt, "internal error: no inverse branch for %s", insn->opcode);
         return -1;
      }

      if (!emit_byte(ctx, pc, inv_opcode, stmt))
         return -1;
      rec[rec_count++] = inv_opcode;
      pc++;
      logical_pc++;

      if (!emit_byte(ctx, pc, 0x03, stmt))
         return -1;
      rec[rec_count++] = 0x03;
      pc++;
      logical_pc++;

      if (!opcode_lookup("JMP", EM_ABS, &opcode)) {
         asm_error(ctx, stmt, "internal error: missing JMP opcode");
         return -1;
      }

      if (!emit_byte(ctx, pc, opcode, stmt))
         return -1;
      rec[rec_count++] = opcode;
      pc++;
      logical_pc++;
   } else {
      if (!opcode_lookup(insn->opcode, emode, &opcode)) {
         asm_error(ctx, stmt, "illegal addressing mode for %s%s",
                   insn->opcode, mode_spec_suffix(insn->spec));
         return -1;
      }

      if (!emit_byte(ctx, pc, opcode, stmt))
         return -1;
      rec[rec_count++] = opcode;
      pc++;
      logical_pc++;
   }

   switch (emode) {
      case EM_IMPLIED:
      case EM_ACCUMULATOR:
         if (ctx->listing)
            listing_write_record(ctx->listing, stmt, start_pc, rec, rec_count);
         return 0;

      default:
         break;
   }

   if (!insn->has_operand || !insn->expr) {
      asm_error(ctx, stmt, "internal error: missing operand expression");
      return -1;
   }

   if (eval_or_report(ctx, insn->expr, &ctx->symbols, stmt->scope, stmt->file, logical_pc, &value, stmt))
      return -1;

   switch (emode) {
      case EM_IMMEDIATE:
         if (!expr_is_s8_or_u8_value(value)) {
            asm_error(ctx, stmt, "%s%s immediate operand out of range: %ld",
                      insn->opcode, mode_spec_suffix(insn->spec), value);
            return -1;
         }
         break;

      case EM_ZP:
      case EM_ZPX:
      case EM_ZPY:
      case EM_INDX:
      case EM_INDY:
         if (!expr_is_u8_value(value)) {
            asm_error(ctx, stmt, "%s%s requires a zero-page operand, got $%lX",
                      insn->opcode, mode_spec_suffix(insn->spec), value & 0xFFFF);
            return -1;
         }
         break;

      default:
         break;
   }

   switch (emode) {
      case EM_IMMEDIATE:
      case EM_ZP:
      case EM_ZPX:
      case EM_ZPY:
      case EM_INDX:
      case EM_INDY:
         if (!emit_byte(ctx, pc, (unsigned char)(value & 0xFF), stmt))
            return -1;
         rec[rec_count++] = (unsigned char)(value & 0xFF);
         pc++;
         logical_pc++;
         break;

      case EM_REL: {
         long disp;

         disp = value - (logical_pc + 1);
         if (disp < -128 || disp > 127) {
            asm_error(ctx, stmt, "branch out of range");
            return -1;
         }

         if (!emit_byte(ctx, pc, (unsigned char)(disp & 0xFF), stmt))
            return -1;
         rec[rec_count++] = (unsigned char)(disp & 0xFF);
         pc++;
         logical_pc++;
         break;
      }

      case EM_REL_LONG:
      case EM_ABS:
      case EM_ABSX:
      case EM_ABSY:
      case EM_IND:
         if (!emit_word(ctx, pc, (unsigned short)(value & 0xFFFF), stmt))
            return -1;
         rec[rec_count++] = (unsigned char)(value & 0xFF);
         rec[rec_count++] = (unsigned char)((value >> 8) & 0xFF);
         pc += 2;
         logical_pc += 2;
         break;

      default:
         asm_error(ctx, stmt, "internal emitter error");
         return -1;
   }

   if (ctx->listing)
      listing_write_record(ctx->listing, stmt, start_pc, rec, rec_count);

   return 0;
}

//! @brief Compare segment ptrs records for deterministic ordering.
static int cmp_segment_ptrs(const void *a, const void *b)
{
   const asm_segment_t *sa;
   const asm_segment_t *sb;

   sa = *(const asm_segment_t * const *)a;
   sb = *(const asm_segment_t * const *)b;

   if (sa->base < sb->base)
      return -1;
   if (sa->base > sb->base)
      return 1;
   return strcmp(sa->name, sb->name);
}

//! @brief Compare symbol ptrs records for deterministic ordering.
static int cmp_symbol_ptrs(const void *a, const void *b)
{
   const symbol_t *sa;
   const symbol_t *sb;

   sa = *(const symbol_t * const *)a;
   sb = *(const symbol_t * const *)b;

   if (sa->defined != sb->defined)
      return sb->defined - sa->defined;

   if (sa->defined) {
      if (sa->value < sb->value)
         return -1;
      if (sa->value > sb->value)
         return 1;
   }

   return strcmp(sa->name, sb->name);
}

//! @brief Handle asm write map file logic for assembler pass and relaxation engine.
int asm_write_map_file(FILE *fp, const asm_context_t *ctx)
{
   const asm_segment_t *seg;
   const symbol_t *sym;
   asm_segment_t **segv;
   symbol_t **symv;
   int segc;
   int symc;
   int i;

   if (!fp || !ctx)
      return 0;

   segc = 0;
   for (seg = ctx->segments; seg; seg = seg->next)
      segc++;

   symc = 0;
   for (sym = ctx->symbols.head; sym; sym = sym->next)
      symc++;

   segv = NULL;
   symv = NULL;

   if (segc > 0) {
      segv = (asm_segment_t **)malloc((size_t)segc * sizeof(*segv));
      if (!segv) {
         fprintf(stderr, "out of memory\n");
         return 0;
      }
   }

   if (symc > 0) {
      symv = (symbol_t **)malloc((size_t)symc * sizeof(*symv));
      if (!symv) {
         free(segv);
         fprintf(stderr, "out of memory\n");
         return 0;
      }
   }

   i = 0;
   for (seg = ctx->segments; seg; seg = seg->next)
      segv[i++] = (asm_segment_t *)seg;

   i = 0;
   for (sym = ctx->symbols.head; sym; sym = sym->next)
      symv[i++] = (symbol_t *)sym;

   if (segc > 1)
      qsort(segv, (size_t)segc, sizeof(*segv), cmp_segment_ptrs);
   if (symc > 1)
      qsort(symv, (size_t)symc, sizeof(*symv), cmp_symbol_ptrs);

   fprintf(fp, "SEGMENTS\n");
   fprintf(fp, "========\n\n");
   fprintf(fp, "%-20s %-10s %-10s %-10s %-10s\n",
           "NAME", "BASE", "SIZE", "END", "CAPACITY");

   for (i = 0; i < segc; i++) {
      long end_addr;

      end_addr = segv[i]->base + segv[i]->used_size;
      fprintf(fp, "%-20s $%08lX $%08lX $%08lX $%08lX\n",
              segv[i]->name,
              segv[i]->base & 0xFFFFFFFFL,
              segv[i]->used_size & 0xFFFFFFFFL,
              end_addr & 0xFFFFFFFFL,
              segv[i]->size & 0xFFFFFFFFL);
   }

   fprintf(fp, "\nSYMBOLS\n");
   fprintf(fp, "=======\n\n");
   fprintf(fp, "%-10s %s\n", "ADDRESS", "NAME");

   for (i = 0; i < symc; i++) {
      if (symv[i]->defined)
         fprintf(fp, "$%08lX %s\n", symv[i]->value & 0xFFFFFFFFL, symv[i]->name);
      else
         fprintf(fp, "???????? %s\n", symv[i]->name);
   }

   free(segv);
   free(symv);
   return 1;
}

//! @brief Handle asm pass2 logic for assembler pass and relaxation engine.
int asm_pass2(asm_context_t *ctx)
{
   stmt_t *stmt;
   int rc;

   ihex_image_init(&ctx->image);
   reset_mutable_symbols_for_emit(&ctx->symbols);

   for (stmt = ctx->prog->head; stmt; stmt = stmt->next) {
      switch (stmt->kind) {
         case STMT_LABEL:
            if (ctx->listing)
               listing_write_no_bytes(ctx->listing, stmt);
            break;

         case STMT_CONST:
            if (stmt->u.cnst.assign_kind == CONST_ASSIGN_SET) {
               rc = process_set_statement_emit(ctx, stmt);
               (void)rc;
            }
            if (ctx->listing)
               listing_write_no_bytes(ctx->listing, stmt);
            break;

         case STMT_DIR:
            rc = directive_emit_pass2(ctx, stmt, stmt->u.dir);
            (void)rc;
            break;

         case STMT_INSN:
            rc = insn_emit_pass2(ctx, stmt, &stmt->u.insn);
            (void)rc;
            break;
      }
   }

   return ctx->error_count ? 1 : 0;
}
