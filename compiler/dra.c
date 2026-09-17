//! @file compiler/dra.c
//! @brief Implements the Direct Register Access syntax surface and staged semantic gates.
//! @ingroup compiler

#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#include "ast.h"
#include "dra.h"
#include "compile_type.h"
#include "messages.h"

static const ASTNode *dra_unwrap_expr(const ASTNode *node) {
   while (node && node->count == 1 && node->name &&
          (!strcmp(node->name, "assign_expr") ||
           !strcmp(node->name, "conditional_expr") ||
           !strcmp(node->name, "expr"))) {
      node = node->children[0];
   }
   return node;
}

static bool dra_is_leaf(const ASTNode *node) {
   return node && node->kind == AST_DRA;
}

static const char *dra_name(const ASTNode *node) {
   return dra_is_leaf(node) && node->strval ? node->strval : "<DRA>";
}

static bool dra_tree_contains(const ASTNode *node) {
   if (!node) return false;
   if (dra_is_leaf(node)) return true;
   for (int i = 0; i < node->count; i++) {
      if (dra_tree_contains(node->children[i])) return true;
   }
   return false;
}

static const ASTNode *dra_first_leaf(const ASTNode *node) {
   const ASTNode *found;
   if (!node) return NULL;
   if (dra_is_leaf(node)) return node;
   for (int i = 0; i < node->count; i++) {
      found = dra_first_leaf(node->children[i]);
      if (found) return found;
   }
   return NULL;
}

static void dra_error(const ASTNode *site, const char *message, const char *name) {
   error_user("[%s:%d.%d] %s '%s'",
              site && site->file ? site->file : "<unknown>",
              site ? site->line : 0,
              site ? site->column : 0,
              message, name ? name : "<DRA>");
}

static bool dra_is_cpu_register(const char *name) {
   return name && (!strcmp(name, "$A") || !strcmp(name, "$X") ||
                   !strcmp(name, "$Y") || !strcmp(name, "$S"));
}

static bool dra_is_memory_register(const char *name) {
   return name && (!strcmp(name, "$A") || !strcmp(name, "$X") ||
                   !strcmp(name, "$Y"));
}

static bool dra_is_branch_flag(const char *name) {
   return name && (!strcmp(name, "$C") || !strcmp(name, "$Z") ||
                   !strcmp(name, "$N") || !strcmp(name, "$V"));
}

static bool dra_is_unbranchable_flag(const char *name) {
   return name && (!strcmp(name, "$I") || !strcmp(name, "$D"));
}

static bool dra_is_flag(const char *name) {
   return dra_is_branch_flag(name) || dra_is_unbranchable_flag(name);
}

static bool dra_constant_value(const ASTNode *node, long long *value_out) {
   return expr_is_integer_constant_expr(dra_unwrap_expr(node), value_out);
}

static bool dra_constant_is(const ASTNode *node, long long expected) {
   long long value;
   return dra_constant_value(node, &value) && value == expected;
}

static bool dra_suffix_is_direct(const ASTNode *suffix) {
   const ASTNode *index;
   if (!suffix || is_empty(suffix)) return true;
   if (!suffix->name) return false;
   if (!strcmp(suffix->name, ".") && suffix->count == 2) {
      return dra_suffix_is_direct(suffix->children[0]);
   }
   if (strcmp(suffix->name, "[") || suffix->count != 2) return false;
   if (!dra_suffix_is_direct(suffix->children[0])) return false;
   index = dra_unwrap_expr(suffix->children[1]);
   return index && index->kind == AST_INTEGER;
}

static bool dra_lvalue_is_direct_shape(const ASTNode *node) {
   const ASTNode *base;
   if (!node || strcmp(node->name, "lvalue") || node->count != 2) return false;
   base = node->children[0];
   if (!base || strcmp(base->name, "lvalue_base") || base->count != 1 ||
       !base->children[0] || base->children[0]->kind != AST_IDENTIFIER) {
      return false;
   }
   return dra_suffix_is_direct(node->children[1]);
}

static bool dra_is_plain_assignment(const ASTNode *node) {
   const ASTNode *op;
   if (!node || strcmp(node->name, "assign_expr") || node->count != 3) return false;
   op = node->children[0];
   return op && op->kind == AST_IDENTIFIER && op->strval && !strcmp(op->strval, ":=");
}

static bool dra_transfer_supported(const char *dst, const char *src) {
   if (!dst || !src || !strcmp(dst, src)) return false;
   if (!strcmp(dst, "$A")) return !strcmp(src, "$X") || !strcmp(src, "$Y");
   if (!strcmp(dst, "$X")) return !strcmp(src, "$A") || !strcmp(src, "$S");
   if (!strcmp(dst, "$Y")) return !strcmp(src, "$A");
   if (!strcmp(dst, "$S")) return !strcmp(src, "$X");
   return false;
}

static void dra_validate_assignment(const ASTNode *node) {
   const ASTNode *dst;
   const ASTNode *src;
   const char *dst_name;

   if (!node || strcmp(node->name, "dra_assign") || node->count != 2) {
      error_user("internal error: malformed DRA assignment surface");
   }
   dst = node->children[0];
   src = dra_unwrap_expr(node->children[1]);
   dst_name = dra_name(dst);

   if (dra_is_cpu_register(dst_name)) {
      if (dra_is_leaf(src)) {
         if (!dra_is_cpu_register(dra_name(src)) ||
             !dra_transfer_supported(dst_name, dra_name(src))) {
            dra_error(src, "unsupported direct-register transfer from", dra_name(src));
         }
         return;
      }
      if (!strcmp(dst_name, "$S")) {
         dra_error(dst, "$S supports only the native assignment from", "$X");
      }
      if (src && src->kind == AST_INTEGER) return;
      if (dra_lvalue_is_direct_shape(src)) return;
      dra_error(dst, "direct-register load requires an immediate byte or directly addressable object for", dst_name);
   }

   if (dra_is_flag(dst_name)) {
      if (!strcmp(dst_name, "$Z") || !strcmp(dst_name, "$N")) {
         dra_error(dst, "status flag is read-only through Direct Register Access", dst_name);
      }
      if (!strcmp(dst_name, "$V")) {
         if (dra_constant_is(src, 0)) return;
         dra_error(dst, "$V supports only the direct assignment $V := 0; for", dst_name);
      }
      if (dra_constant_is(src, 0) || dra_constant_is(src, 1)) return;
      dra_error(dst, "writable status flag requires compile-time 0 or 1 for", dst_name);
   }

   dra_error(dst, "unsupported Direct Register Access assignment target", dst_name);
}

//! @brief Return the first DRA leaf that is not legal in a DRA7 boolean condition.
//!
//! Ordinary non-DRA subtrees remain ordinary C26 conditions.  A DRA leaf may
//! participate only through nested !, &&, and ||, and only C/Z/N/V are readable.
//! This keeps flag tests branch-only while allowing the existing short-circuit
//! lowering to compose them with normal conditions without materializing bytes.
static const ASTNode *dra_invalid_condition_leaf(const ASTNode *condition) {
   const ASTNode *work = dra_unwrap_expr(condition);
   const ASTNode *bad;

   if (!work || !dra_tree_contains(work)) return NULL;
   if (dra_is_leaf(work)) {
      return dra_is_branch_flag(dra_name(work)) ? NULL : work;
   }
   if (work->name && !strcmp(work->name, "!") && work->count == 1) {
      return dra_invalid_condition_leaf(work->children[0]);
   }
   if (work->name && (!strcmp(work->name, "&&") || !strcmp(work->name, "||")) &&
       work->count == 2) {
      bad = dra_invalid_condition_leaf(work->children[0]);
      if (bad) return bad;
      return dra_invalid_condition_leaf(work->children[1]);
   }
   return dra_first_leaf(work);
}

static bool dra_condition_shape_supported(const ASTNode *condition) {
   return dra_tree_contains(condition) && !dra_invalid_condition_leaf(condition);
}

static void dra_validate_condition(const ASTNode *condition) {
   const ASTNode *bad;
   const char *name;

   if (!dra_tree_contains(condition)) return;
   bad = dra_invalid_condition_leaf(condition);
   if (!bad) return;

   name = dra_name(bad);
   if (dra_is_branch_flag(name)) {
      dra_error(bad, "DRA flag conditions may use only nested !, &&, and || around readable flags; general use is unsupported for", name);
   }
   if (dra_is_unbranchable_flag(name)) {
      dra_error(bad, "status flag is not directly branchable and cannot be read as a condition", name);
   }
   dra_error(bad, "CPU register cannot be used as a Direct Register Access condition", name);
}

static void dra_validate_node(const ASTNode *node) {
   const ASTNode *src;
   const char *src_name;

   if (!node) return;

   if (!strcmp(node->name, "dra_assign")) {
      dra_validate_assignment(node);
      return;
   }

   if (dra_is_plain_assignment(node)) {
      src = dra_unwrap_expr(node->children[2]);
      if (dra_is_leaf(src)) {
         src_name = dra_name(src);
         if (!dra_is_memory_register(src_name)) {
            dra_error(src, "only $A, $X, or $Y can be stored directly to memory; unsupported source", src_name);
         }
         if (!dra_lvalue_is_direct_shape(node->children[1])) {
            dra_error(src, "direct-register store requires a directly addressable destination for", src_name);
         }
         return;
      }
   }

   if ((!strcmp(node->name, "if_stmt") || !strcmp(node->name, "while_stmt")) && node->count >= 1) {
      dra_validate_condition(node->children[0]);
      for (int i = 1; i < node->count; i++) dra_validate_node(node->children[i]);
      return;
   }
   if (!strcmp(node->name, "do_stmt") && node->count >= 2) {
      dra_validate_node(node->children[0]);
      dra_validate_condition(node->children[1]);
      for (int i = 2; i < node->count; i++) dra_validate_node(node->children[i]);
      return;
   }
   if (!strcmp(node->name, "for_stmt") && node->count >= 4) {
      dra_validate_node(node->children[0]);
      dra_validate_condition(node->children[1]);
      dra_validate_node(node->children[2]);
      dra_validate_node(node->children[3]);
      for (int i = 4; i < node->count; i++) dra_validate_node(node->children[i]);
      return;
   }

   if (!strcmp(node->name, "declarator") && dra_tree_contains(node)) {
      const ASTNode *pseudo = dra_first_leaf(node);
      dra_error(pseudo, "Direct Register Access pseudo-object cannot be declared", dra_name(pseudo));
   }

   if ((!strcmp(node->name, "&") || !strcmp(node->name, "&<") || !strcmp(node->name, "&>")) &&
       dra_tree_contains(node)) {
      const ASTNode *pseudo = dra_first_leaf(node);
      dra_error(pseudo, "cannot take the address of Direct Register Access pseudo-object", dra_name(pseudo));
   }

   if (dra_is_leaf(node)) {
      dra_error(node, "Direct Register Access pseudo-object is not a general expression", dra_name(node));
   }

   for (int i = 0; i < node->count; i++) {
      dra_validate_node(node->children[i]);
   }
}

bool dra_validate_surface(const ASTNode *root) {
   bool seen = dra_tree_contains(root);
   if (seen) dra_validate_node(root);
   return seen;
}

static bool dra_condition_codegen_implemented(const ASTNode *condition) {
   return dra_condition_shape_supported(condition);
}

static void dra_reject_unimplemented_codegen_node(const ASTNode *node) {
   const ASTNode *src;
   const ASTNode *pseudo;

   if (!node) return;

   /* DRA5 owns simple C/Z/N/V truth tests in statement-condition positions.
      Deliberately skip only the condition subtree here; nested statements are
      still walked so later/unimplemented DRA forms cannot hide in a body. */
   if ((!strcmp(node->name, "if_stmt") || !strcmp(node->name, "while_stmt")) &&
       node->count >= 1 && dra_condition_codegen_implemented(node->children[0])) {
      for (int i = 1; i < node->count; i++) {
         dra_reject_unimplemented_codegen_node(node->children[i]);
      }
      return;
   }
   if (!strcmp(node->name, "do_stmt") && node->count >= 2 &&
       dra_condition_codegen_implemented(node->children[1])) {
      dra_reject_unimplemented_codegen_node(node->children[0]);
      for (int i = 2; i < node->count; i++) {
         dra_reject_unimplemented_codegen_node(node->children[i]);
      }
      return;
   }
   if (!strcmp(node->name, "for_stmt") && node->count >= 4 &&
       dra_condition_codegen_implemented(node->children[1])) {
      dra_reject_unimplemented_codegen_node(node->children[0]);
      dra_reject_unimplemented_codegen_node(node->children[2]);
      dra_reject_unimplemented_codegen_node(node->children[3]);
      for (int i = 4; i < node->count; i++) {
         dra_reject_unimplemented_codegen_node(node->children[i]);
      }
      return;
   }

   /* DRA2-DRA4 own direct register loads/transfers and DRA6 owns the
      validated constant-only direct flag writes. */
   if (!strcmp(node->name, "dra_assign") && node->count == 2) {
      src = dra_unwrap_expr(node->children[1]);
      if (dra_is_leaf(node->children[0])) {
         const char *dst_name = dra_name(node->children[0]);
         if (!strcmp(dst_name, "$C") || !strcmp(dst_name, "$I") ||
             !strcmp(dst_name, "$D") || !strcmp(dst_name, "$V")) {
            return;
         }
      }
      if (dra_is_leaf(node->children[0]) && dra_is_leaf(src) &&
          dra_transfer_supported(dra_name(node->children[0]), dra_name(src))) {
         return;
      }
      if (dra_is_leaf(node->children[0]) &&
          (!strcmp(dra_name(node->children[0]), "$A") ||
           !strcmp(dra_name(node->children[0]), "$X") ||
           !strcmp(dra_name(node->children[0]), "$Y")) && !dra_is_leaf(src)) {
         return;
      }
      pseudo = dra_first_leaf(node);
      dra_error(pseudo, "Direct Register Access code generation is not implemented yet for", dra_name(pseudo));
   }

   /* DRA2/DRA3 also own plain direct-byte stores from physical A/X/Y. */
   if (dra_is_plain_assignment(node)) {
      src = dra_unwrap_expr(node->children[2]);
      if (dra_is_leaf(src) &&
          (!strcmp(dra_name(src), "$A") || !strcmp(dra_name(src), "$X") ||
           !strcmp(dra_name(src), "$Y"))) {
         return;
      }
   }

   if (dra_is_leaf(node)) {
      dra_error(node, "Direct Register Access code generation is not implemented yet for", dra_name(node));
   }

   for (int i = 0; i < node->count; i++) {
      dra_reject_unimplemented_codegen_node(node->children[i]);
   }
}

void dra_reject_unimplemented_codegen(const ASTNode *root) {
   dra_reject_unimplemented_codegen_node(root);
}
