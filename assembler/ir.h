//! @file assembler/ir.h
//! @brief Declares assembler intermediate representation for the VCSC assembler.
//! @ingroup assembler

#ifndef IR_H
#define IR_H

#include "addr_mode.h"
#include "expr.h"
#include "directive.h"
#include "opcode.h"

//! Optional addressing-mode suffix requested in source, such as `.z` or `.a`.
typedef enum mode_spec {
   MODE_SPEC_NONE = 0,
   MODE_SPEC_Z,
   MODE_SPEC_ZX,
   MODE_SPEC_ZY,
   MODE_SPEC_A,
   MODE_SPEC_AX,
   MODE_SPEC_AY,
   MODE_SPEC_I,
   MODE_SPEC_IX,
   MODE_SPEC_IY
} mode_spec_t;

//! Optional relative-branch page behavior requested by an opcode suffix.
typedef enum branch_page_spec {
   BRANCH_PAGE_UNSPECIFIED = 0,
   BRANCH_PAGE_FLEX,
   BRANCH_PAGE_SAME,
   BRANCH_PAGE_CROSS
} branch_page_spec_t;

//! Kinds of top-level assembler statements stored in the IR.
typedef enum stmt_kind {
   STMT_INSN = 0,
   STMT_DIR,
   STMT_LABEL,
   STMT_CONST
} stmt_kind_t;

typedef enum const_assign_kind {
   CONST_ASSIGN_NORMAL = 0,
   CONST_ASSIGN_DEFAULT,
   CONST_ASSIGN_SET
} const_assign_kind_t;

//! Operand and opcode information for an instruction statement.
typedef struct insn_info {
   char *opcode;
   mode_spec_t spec;
   branch_page_spec_t branch_page;
   addr_mode_t mode;
   expr_t *expr;
   int has_operand;

   emit_mode_t final_mode;
   int size;
} insn_info_t;

typedef struct const_info {
   char *name;
   expr_t *expr;
   const_assign_kind_t assign_kind;
   int applied;
} const_info_t;

typedef struct stmt stmt_t;

struct stmt {
   stmt_kind_t kind;
   const char *file;
   int line;
   long address;
   long emit_address;
   int rorg_active;
   int active;
   char *label;
   char *scope;
   char *segment;
   union {
      insn_info_t insn;
      directive_info_t *dir;
      const_info_t cnst;
   } u;
   stmt_t *next;
};

//! Ordered list of parsed assembly statements.
typedef struct program_ir {
   stmt_t *head;
   stmt_t *tail;
} program_ir_t;

void program_ir_init(program_ir_t *prog);
void program_ir_append(program_ir_t *prog, stmt_t *stmt);
void program_ir_free(program_ir_t *prog);
int program_ir_expand_repeats(program_ir_t *prog);

stmt_t *stmt_make_label(const char *file, int line, char *label);
stmt_t *stmt_make_insn(const char *file, int line, char *label, char *opcode_text, addr_mode_t mode, expr_t *expr, int has_operand);
stmt_t *stmt_make_dir(const char *file, int line, char *label, directive_info_t *dir);
stmt_t *stmt_make_const(const char *file, int line, char *name, expr_t *expr);
stmt_t *stmt_make_const_default(const char *file, int line, char *name, expr_t *expr);
stmt_t *stmt_make_const_set(const char *file, int line, char *name, expr_t *expr);

const char *mode_spec_suffix(mode_spec_t spec);
const char *branch_page_spec_suffix(branch_page_spec_t spec);

void stmt_print(const stmt_t *stmt);
void program_ir_print(const program_ir_t *prog);

#endif
