//! @file compiler/expropt.c
//! @brief Implements expression optimization for the n65 compiler.
//! @ingroup compiler

#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <stdbool.h>
#include <stdint.h>

#include "ast.h"
#include "expropt.h"
#include "float.h"
#include "integer.h"
#include "messages.h"
#include "xray.h"

//! @brief Parse node to double into the normalized representation used by expropt.
static double parse_node_to_double(ASTNode *node) {
   if (node && node->kind == AST_INTEGER) {
      return parse_int(node->strval);
   }
   else {
      return parse_float(node->strval);
   }
}

//! @brief Return whether int applies in expropt.
static bool is_int(ASTNode *node) {
   if (node && node->kind == AST_INTEGER) {
      if (node->count == 0) { // backtick casting is done on the processor
         return true;
      }
   }
   return false;
}

//! @brief Return whether float or int applies in expropt.
static bool is_float_or_int(ASTNode *node) {
   if (node && (node->kind == AST_INTEGER || node->kind == AST_FLOAT)) {
      if (node->count == 0) { // backtick casting is done on the processor
         return true;
      }
   }
   return false;
}

//! @brief Return whether lone expr applies in expropt.
static bool is_lone_expr(ASTNode *node) {
   if (!strcmp(node->name, "expr")) {
      if (node->count == 1) {
         if (is_float_or_int(node->children[0])) {
            return true;
         }
      }
   }
   return false;
}

//! @brief Return whether binary op applies in expropt.
static bool is_binary_op(ASTNode *node) {
   if (node->name[1] == 0 && NULL != strchr("+-*/%", node->name[0])) {
      if (node->count == 2) {
         if (is_lone_expr(node->children[0])) {
            node->children[0] = node->children[0]->children[0];
         }

         if (is_lone_expr(node->children[1])) {
            node->children[1] = node->children[1]->children[0];
         }

         if (is_float_or_int(node->children[0]) &&
             is_float_or_int(node->children[1])) {
            return true;
         }
      }
   }
   return false;
}

//! @brief Return whether unary op applies in expropt.
static bool is_unary_op(ASTNode *node) {
   if (node->name[1] == 0 && NULL != strchr("+-", node->name[0])) {
      if (node->count == 1) {
         if (is_lone_expr(node->children[0])) {
            node->children[0] = node->children[0]->children[0];
         }

         if (is_float_or_int(node->children[0])) {
            return true;
         }
      }
   }
   return false;
}

//! @brief Handle node truthy logic for expropt.
static bool node_truthy(ASTNode *node, bool *truthy) {
   if (!truthy) {
      return false;
   }
   while (node && node->count == 1 &&
          (!strcmp(node->name, "expr") ||
           !strcmp(node->name, "assign_expr") ||
           !strcmp(node->name, "initializer") ||
           !strcmp(node->name, "opt_expr"))) {
      node = node->children[0];
   }
   if (node && node->kind == AST_INTEGER && node->count == 0) {
      *truthy = parse_int(node->strval) != 0;
      return true;
   }
   if (node && node->kind == AST_FLOAT && node->count == 0) {
      *truthy = parse_float(node->strval) != 0.0;
      return true;
   }
   return false;
}

//! @brief Handle handle binary plus logic for expropt.
static void handle_binary_plus(ASTNode **noderef) {
   ASTNode *node = *noderef;
   char buf[256];
   if (is_int(node->children[0]) && is_int(node->children[1])) {
      long long left = parse_int(node->children[0]->strval);
      long long right = parse_int(node->children[1]->strval);

      long long result = left + right;
      sprintf(buf, "%lld", result);
      *noderef = make_integer_leaf(strdup(buf));
   }
   else {
      double left = parse_node_to_double(node->children[0]);
      double right = parse_node_to_double(node->children[1]);

      double result = left + right;
      sprintf(buf, "%la", result);
      *noderef = make_float_leaf(strdup(buf));
   }
}

//! @brief Handle handle unary plus logic for expropt.
static void handle_unary_plus(ASTNode **noderef) {
   *noderef = (*noderef)->children[0];
}

//! @brief Handle handle binary minus logic for expropt.
static void handle_binary_minus(ASTNode **noderef) {
   ASTNode *node = *noderef;
   char buf[256];
   if (is_int(node->children[0]) && is_int(node->children[1])) {
      long long left = parse_int(node->children[0]->strval);
      long long right = parse_int(node->children[1]->strval);

      long long result = left - right;
      sprintf(buf, "%lld", result);
      *noderef = make_integer_leaf(strdup(buf));
   }
   else {
      double left = parse_node_to_double(node->children[0]);
      double right = parse_node_to_double(node->children[1]);

      double result = left - right;
      sprintf(buf, "%la", result);
      *noderef = make_float_leaf(strdup(buf));
   }
}

//! @brief Handle handle unary minus logic for expropt.
static void handle_unary_minus(ASTNode **noderef) {
   ASTNode *node = *noderef;
   char buf[256];
   if (is_int(node->children[0])) {
      long long left = parse_int(node->children[0]->strval);

      long long result = -left;
      sprintf(buf, "%lld", result);
      *noderef = make_integer_leaf(strdup(buf));
   }
   else {
      double left = parse_node_to_double(node->children[0]);
      double result = -left;
      sprintf(buf, "%la", result);
      *noderef = make_float_leaf(strdup(buf));
   }
}

//! @brief Handle handle binary times logic for expropt.
static void handle_binary_times(ASTNode **noderef) {
   ASTNode *node = *noderef;
   char buf[256];
   if (is_int(node->children[0]) && is_int(node->children[1])) {
      long long left = parse_int(node->children[0]->strval);
      long long right = parse_int(node->children[1]->strval);

      long long result = left * right;
      sprintf(buf, "%lld", result);
      *noderef = make_integer_leaf(strdup(buf));
   }
   else {
      double left = parse_node_to_double(node->children[0]);
      double right = parse_node_to_double(node->children[1]);

      double result = left * right;
      sprintf(buf, "%la", result);
      *noderef = make_float_leaf(strdup(buf));
   }
}

//! @brief Handle handle binary divide logic for expropt.
static void handle_binary_divide(ASTNode **noderef) {
   ASTNode *node = *noderef;
   char buf[256];
   if (is_int(node->children[0]) && is_int(node->children[1])) {
      long long left = parse_int(node->children[0]->strval);
      long long right = parse_int(node->children[1]->strval);

      if (right == 0) {
         error_user("integer divide by zero at [%s:%d.%d]", node->file, node->line, node->column);
      }
      long long result = left / right;
      sprintf(buf, "%lld", result);
      *noderef = make_integer_leaf(strdup(buf));
   }
   else {
      double left = parse_node_to_double(node->children[0]);
      double right = parse_node_to_double(node->children[1]);

      double result = left / right;
      sprintf(buf, "%la", result);
      *noderef = make_float_leaf(strdup(buf));
   }
}

//! @brief Handle handle binary modulo logic for expropt.
static void handle_binary_modulo(ASTNode **noderef) {
   ASTNode *node = *noderef;
   char buf[256];
   if (is_int(node->children[0]) && is_int(node->children[1])) {
      long long left = parse_int(node->children[0]->strval);
      long long right = parse_int(node->children[1]->strval);

      if (right == 0) {
         error_user("integer modulo by zero at [%s:%d.%d]", node->file, node->line, node->column);
      }
      long long result = left % right;
      sprintf(buf, "%lld", result);
      *noderef = make_integer_leaf(strdup(buf));
   }
   else {
      error_user("float modulo undefined at [%s:%d.%d]",
         node->file, node->line, node->column);
      // error calls exit
   }
}

//! @brief Handle expropt logic for expropt.
static void expropt(ASTNode **noderef) {
   if (noderef == NULL) {
      return;
   }

   ASTNode *node = *noderef;

   if (*noderef == NULL) {
      return;
   }

   if (!strcmp(node->name, "&&") && node->count == 2) {
      bool truthy;

      expropt(&(node->children[0]));
      if (node_truthy(node->children[0], &truthy)) {
         if (!truthy) {
            *noderef = make_integer_leaf("0");
            return;
         }
         expropt(&(node->children[1]));
         if (node_truthy(node->children[1], &truthy)) {
            *noderef = make_integer_leaf(truthy ? "1" : "0");
         }
         return;
      }
      expropt(&(node->children[1]));
      return;
   }

   if (!strcmp(node->name, "||") && node->count == 2) {
      bool truthy;

      expropt(&(node->children[0]));
      if (node_truthy(node->children[0], &truthy)) {
         if (truthy) {
            *noderef = make_integer_leaf("1");
            return;
         }
         expropt(&(node->children[1]));
         if (node_truthy(node->children[1], &truthy)) {
            *noderef = make_integer_leaf(truthy ? "1" : "0");
         }
         return;
      }
      expropt(&(node->children[1]));
      return;
   }

   if (((!strcmp(node->name, "conditional_expr") && node->count == 4 && node->children[0] &&
         node->children[0]->kind == AST_IDENTIFIER && !strcmp(node->children[0]->strval, "?:"))) ||
       (!strcmp(node->name, "?:") && node->count == 3)) {
      bool truthy;
      ASTNode **test = !strcmp(node->name, "?:") ? &(node->children[0]) : &(node->children[1]);
      ASTNode **iftrue = !strcmp(node->name, "?:") ? &(node->children[1]) : &(node->children[2]);
      ASTNode **iffalse = !strcmp(node->name, "?:") ? &(node->children[2]) : &(node->children[3]);

      expropt(test);
      if (node_truthy(*test, &truthy)) {
         ASTNode *selected = truthy ? *iftrue : *iffalse;
         expropt(&selected);
         *noderef = selected;
         return;
      }
      expropt(iftrue);
      expropt(iffalse);
      return;
   }

   // binary operators
   if (is_binary_op(node)) {
      switch(node->name[0]) {
         case '+':
            handle_binary_plus(noderef);
            return;
         case '-':
            handle_binary_minus(noderef);
            return;
         case '*':
            handle_binary_times(noderef);
            return;
         case '/':
            handle_binary_divide(noderef);
            return;
         case '%':
            handle_binary_modulo(noderef);
            return;
      }
   }

   if (is_unary_op(node)) {
      switch(node->name[0]) {
         case '+':
            handle_unary_plus(noderef);
            return;
         case '-':
            handle_unary_minus(noderef);
            return;
      }
   }

   // everybody else
   for (int i = 0; i < node->count; i++) {
      expropt(&(node->children[i]));
   }
}

//! @brief Handle astcount logic for expropt.
static int astcount(ASTNode *node) {
   int ret = 0;

   if (node) {
      ret++; // for us

      for(int i = 0; i < node->count; i++) {
         ret += astcount(node->children[i]);
      }
   }

   return ret;
}

//! @brief Run the expropt stage of the compiler tool pipeline.
void do_expropt(void) {
   int before, after;
   int pre, post, passes = 0;

   if (get_xray(XRAY_EXPROPTONLY)) {
      before = astcount(root);
      parse_dump();
   }

   do {
      pre = astcount(root);
      passes++;
      expropt(&root);
      post = astcount(root);
   } while (pre != post);

   if (get_xray(XRAY_EXPROPTONLY)) {
      after = astcount(root);

      parse_dump();
      message("expropt: %d -> %d, %d passes\n", before, after, passes);
   }
}
