//! @file compiler/emit.c
//! @brief Implements assembly emission buffers for the VCSC compiler.
//! @ingroup compiler

#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <ctype.h>
#include <stdbool.h>

#include "emit.h"
#include "messages.h"
#include "xray.h"

typedef struct {
   char *text;
   char *trim;
   char *mnemonic;
   char *operand;
   char *label;
   bool is_generated;
   bool is_instruction;
   bool is_label_only;
   bool is_directive;
   bool is_blank_or_comment;
   bool is_inline_asm;
   bool is_inline_asm_marker;
   bool keep;
   int size;
} PeepholeLine;

typedef struct {
   int total_before;
   int total_saved;
   int pass_bytes;
   int pass_removed;
   int pass_saved;
   int pass_dup_load;
   int pass_dup_store;
   int pass_dup_transfer;
   int pass_dup_status;
   int pass_const_alu;
   int pass_dead_load;
   int pass_never_branch;
   int pass_jump_next;
   int pass_branch_next;
} PeepholeStats;

//! @brief Return xstrndup local data used by compiler assembly emitter; returned pointers alias existing storage unless explicitly allocated by the function name.
static char *xstrndup_local(const char *s, size_t n) {
   char *ret = (char *) malloc(n + 1);
   memcpy(ret, s, n);
   ret[n] = '\0';
   return ret;
}

//! Compiler-owned zero-page operands whose direct loads/stores are safe for peephole value tracking.
static const char *compiler_zp_operand_names[] = {
   "arg0",
   "arg1",
   "ptr0",
   "ptr0+1",
   "ptr1",
   "ptr1+1",
   "ptr2",
   "ptr2+1",
};

enum { COMPILER_ZP_OPERAND_COUNT = (int) (sizeof(compiler_zp_operand_names) / sizeof(compiler_zp_operand_names[0])) };

//! @brief Return index of compiler zero-page operand or -1 when operand is not directly tracked.
static int compiler_zp_operand_index(const char *operand) {
   if (!operand || !*operand)
      return -1;

   for (int i = 0; i < COMPILER_ZP_OPERAND_COUNT; i++) {
      if (!strcmp(operand, compiler_zp_operand_names[i]))
         return i;
   }
   return -1;
}

//! @brief Return whether compiler zero-page operand applies in compiler assembly emitter.
static bool is_compiler_zp_operand(const char *operand) {
   return compiler_zp_operand_index(operand) >= 0;
}

//! @brief Return whether text appears in a null-terminated string list.
static bool string_in_list(const char *text, const char *const *items) {
   if (!text)
      return false;
   for (int i = 0; items[i]; i++) {
      if (!strcmp(text, items[i]))
         return true;
   }
   return false;
}

//! @brief Return whether mnemonic is one of the 6502 relative branch opcodes.
static bool is_branch_mnemonic(const char *mnemonic) {
   static const char *const branches[] = { "bcc", "bcs", "beq", "bmi", "bne", "bpl", "bvc", "bvs", NULL };
   return string_in_list(mnemonic, branches);
}

//! @brief Return whether mnemonic is one of the one-byte implied/register 6502 opcodes.
static bool is_one_byte_mnemonic(const char *mnemonic) {
   static const char *const one_byte[] = {
      "brk", "clc", "cld", "cli", "clv", "dex", "dey", "inx", "iny", "nop",
      "pha", "php", "pla", "plp", "rti", "rts", "sec", "sed", "sei",
      "tax", "tay", "tsx", "txa", "txs", "tya", NULL
   };
   return string_in_list(mnemonic, one_byte);
}

//! @brief Return whether operand is an accumulator pseudo-operand.
static bool operand_is_accumulator(const char *operand) {
   return operand && !strcmp(operand, "a");
}

static char *trim_in_place(char *s);

//! @brief Return whether operand is a compiler-owned zero-page operand with a simple X/Y suffix.
static bool operand_is_compiler_zp_indexed(const char *operand) {
   char *copy;
   char *base;
   char *comma;
   bool ret = false;

   if (!operand || !*operand)
      return false;

   comma = strrchr(operand, ',');
   if (!comma)
      return false;

   if (comma[0] != ',' || comma[2] != '\0' || (tolower((unsigned char) comma[1]) != 'x' && tolower((unsigned char) comma[1]) != 'y'))
      return false;

   copy = xstrndup_local(operand, (size_t) (comma - operand));
   base = trim_in_place(copy);
   ret = is_compiler_zp_operand(base);
   free(copy);
   return ret;
}

//! @brief Return whether operand is safe load value in compiler assembly emitter.
static bool operand_is_safe_load_value(const char *operand) {
   if (!operand || !*operand)
      return false;
   if (operand[0] == '#')
      return true;
   return is_compiler_zp_operand(operand);
}

//! @brief Handle instruction size for logic for compiler assembly emitter.
static int instruction_size_for(const char *mnemonic, const char *operand) {
   if (!mnemonic || !*mnemonic)
      return 0;

   if (is_one_byte_mnemonic(mnemonic))
      return 1;

   if ((!strcmp(mnemonic, "asl") || !strcmp(mnemonic, "lsr") || !strcmp(mnemonic, "rol") || !strcmp(mnemonic, "ror")) &&
       (!operand || !*operand || operand_is_accumulator(operand))) {
      return 1;
   }

   if (is_branch_mnemonic(mnemonic))
      return 2;

   if (!strcmp(mnemonic, "jmp") || !strcmp(mnemonic, "jsr"))
      return 3;

   if (!operand)
      return 0;

   if (operand[0] == '#')
      return 2;

   if (operand[0] == '(')
      return 2;

   if (is_compiler_zp_operand(operand) || operand_is_compiler_zp_indexed(operand))
      return 2;

   return 3;
}

//! @brief Emit sink join for compiler assembly emitter diagnostics or output files.
static char *emit_sink_join(EmitSink *es) {
   size_t total = 0;
   char *buf;
   size_t off = 0;

   for (EmitPiece *ep = es->head; ep; ep = ep->next) {
      total += strlen(ep->txt);
   }

   buf = (char *) malloc(total + 1);
   for (EmitPiece *ep = es->head; ep; ep = ep->next) {
      size_t len = strlen(ep->txt);
      memcpy(buf + off, ep->txt, len);
      off += len;
   }
   buf[off] = '\0';
   return buf;
}

//! @brief Release emit sink pieces storage owned by compiler assembly emitter.
static void free_emit_sink_pieces(EmitSink *es) {
   EmitPiece *next;
   for (EmitPiece *ep = es->head; ep; ep = next) {
      next = ep->next;
      free((void *) ep->txt);
      free(ep);
   }
   es->head = es->tail = NULL;
}

//! @brief Parse lines into the normalized representation used by compiler assembly emitter.
static int split_lines(char *text, char ***out_lines) {
   char **lines = NULL;
   int count = 0;
   char *start = text;
   char *p = text;

   while (1) {
      if (*p == '\n' || *p == '\0') {
         lines = (char **) realloc(lines, sizeof(char *) * (count + 1));
         lines[count++] = xstrndup_local(start, (size_t) (p - start));
         if (*p == '\0')
            break;
         start = p + 1;
      }
      p++;
   }

   *out_lines = lines;
   return count;
}

//! @brief Return trim in place data used by compiler assembly emitter; returned pointers alias existing storage unless explicitly allocated by the function name.
static char *trim_in_place(char *s) {
   char *end;
   while (*s && isspace((unsigned char) *s))
      s++;
   end = s + strlen(s);
   while (end > s && isspace((unsigned char) end[-1]))
      *--end = '\0';
   return s;
}

//! @brief Parse line into the normalized representation used by compiler assembly emitter.
static void parse_line(PeepholeLine *line) {
   char *p;
   char *comment;
   line->trim = trim_in_place(line->text);
   line->mnemonic = NULL;
   line->operand = NULL;
   line->label = NULL;
   line->is_generated = (line->text[0] == ' ' || line->text[0] == '\t');
   line->is_instruction = false;
   line->is_label_only = false;
   line->is_directive = false;
   line->is_blank_or_comment = false;
   line->is_inline_asm = false;
   line->is_inline_asm_marker = false;
   line->keep = true;
   line->size = 0;

   if (!strcmp(line->trim, EMIT_INLINE_ASM_BEGIN_MARKER) || !strcmp(line->trim, EMIT_INLINE_ASM_END_MARKER)) {
      line->is_blank_or_comment = true;
      line->is_inline_asm_marker = true;
      return;
   }

   if (!line->trim[0] || line->trim[0] == ';') {
      line->is_blank_or_comment = true;
      return;
   }

   if (!line->is_generated) {
      size_t len = strlen(line->trim);
      if (len > 0 && line->trim[len - 1] == ':') {
         line->is_label_only = true;
         line->label = xstrndup_local(line->trim, len - 1);
         return;
      }
      if (line->trim[0] == '.') {
         line->is_directive = true;
         return;
      }
      return;
   }

   if (line->trim[0] == '.') {
      line->is_directive = true;
      return;
   }

   p = line->trim;
   while (*p && isalpha((unsigned char) *p))
      p++;
   if (p == line->trim)
      return;

   line->mnemonic = xstrndup_local(line->trim, (size_t) (p - line->trim));
   for (char *q = line->mnemonic; *q; q++) {
      *q = (char) tolower((unsigned char) *q);
   }

   while (*p && isspace((unsigned char) *p))
      p++;
   comment = strchr(p, ';');
   if (comment)
      *comment = '\0';
   p = trim_in_place(p);
   if (*p)
      line->operand = strdup(p);

   line->is_instruction = true;
   line->size = instruction_size_for(line->mnemonic, line->operand);
}

//! @brief Release lines storage owned by compiler assembly emitter.
static void free_lines(PeepholeLine *lines, int count) {
   for (int i = 0; i < count; i++) {
      free(lines[i].text);
      free(lines[i].mnemonic);
      free(lines[i].operand);
      free(lines[i].label);
   }
   free(lines);
}

//! @brief Mark inline asm ranges so the peephole pass treats programmer-owned assembly as opaque.
static void annotate_inline_asm_lines(PeepholeLine *lines, int count) {
   bool in_inline_asm = false;

   for (int i = 0; i < count; i++) {
      if (lines[i].is_inline_asm_marker) {
         lines[i].keep = false;
         if (!strcmp(lines[i].trim, EMIT_INLINE_ASM_BEGIN_MARKER))
            in_inline_asm = true;
         else
            in_inline_asm = false;
         continue;
      }

      if (in_inline_asm)
         lines[i].is_inline_asm = true;
   }
}

//! @brief Return whether a jump/branch target is in the immediate following run of labels.
static bool target_is_immediately_following_label(PeepholeLine *lines, int count, int index, const char *target) {
   if (!target || !*target)
      return false;

   for (int i = index + 1; i < count; i++) {
      if (!lines[i].keep)
         continue;
      if (lines[i].is_inline_asm)
         return false;
      if (lines[i].is_blank_or_comment)
         continue;
      if (lines[i].is_label_only) {
         if (lines[i].label && !strcmp(lines[i].label, target))
            return true;
         continue;
      }
      return false;
   }

   return false;
}

//! @brief Clear one tracked peephole string state slot.
static void clear_state(char **slot) {
   free(*slot);
   *slot = NULL;
}

//! @brief Handle set reg state logic for compiler assembly emitter.
static void set_reg_state(char **slot, const char *value) {
   free(*slot);
   *slot = value ? strdup(value) : NULL;
}

//! @brief Clear all tracked compiler zero-page memory values.
static void clear_mem_state(char **mem_values) {
   for (int i = 0; i < COMPILER_ZP_OPERAND_COUNT; i++) {
      clear_state(&mem_values[i]);
   }
}

//! @brief Handle reset reg state logic for compiler assembly emitter.
static void reset_peephole_state(char **a, char **x, char **y, char **flags, char **mem_values) {
   clear_state(a);
   clear_state(x);
   clear_state(y);
   clear_state(flags);
   clear_mem_state(mem_values);
}

//! @brief Handle log rewrite logic for compiler assembly emitter.
static void log_rewrite(const char *kind, int index, const PeepholeLine *line, int saved) {
   if (get_xray(XRAY_DEBUG)) {
      debug("peephole:%s line=%d saved=%d :: %s", kind, index + 1, saved, line->trim ? line->trim : "");
   }
}

//! @brief Handle same text logic for compiler assembly emitter.
static bool same_text(const char *a, const char *b) {
   if (!a || !b)
      return false;
   return !strcmp(a, b);
}

//! @brief Return the current known value loaded from an operand, if peephole can prove one.
static const char *known_value_for_operand(const char *operand, char **mem_values) {
   int idx;

   if (!operand || !*operand)
      return NULL;

   if (operand[0] == '#')
      return operand;

   idx = compiler_zp_operand_index(operand);
   if (idx < 0)
      return NULL;

   return mem_values[idx] ? mem_values[idx] : operand;
}

//! @brief Return whether mnemonic reads the N/Z flags produced by a previous load.
static bool mnemonic_reads_nz_flags(const char *mnemonic) {
   static const char *const reads_nz[] = { "beq", "bmi", "bne", "bpl", "php", "brk", NULL };
   return string_in_list(mnemonic, reads_nz);
}

//! @brief Return whether mnemonic is a control-flow split that can skip a later N/Z overwrite.
static bool mnemonic_splits_control_flow(const char *mnemonic) {
   return is_branch_mnemonic(mnemonic);
}

//! @brief Return whether mnemonic sets or clears a status flag without changing registers or memory.
static bool mnemonic_sets_simple_status_flag(const char *mnemonic) {
   static const char *const simple_status[] = { "clc", "sec", "cld", "sed", "cli", "sei", "clv", NULL };
   return string_in_list(mnemonic, simple_status);
}

//! @brief Return whether two simple status-flag instructions write the same flag the same way.
static bool simple_status_write_is_same(const char *a, const char *b) {
   return same_text(a, b);
}


//! @brief Return whether mnemonic is a simple immediate ALU op that can be folded with a previous immediate A load.
static bool mnemonic_is_foldable_a_imm_alu(const char *mnemonic) {
   static const char *const foldable[] = { "and", "eor", "ora", NULL };
   return string_in_list(mnemonic, foldable);
}

//! @brief Parse an immediate byte operand that is a plain numeric literal.
static bool parse_immediate_byte(const char *operand, int *out_value) {
   const char *p;
   char *end = NULL;
   long value;
   int base = 10;

   if (!operand || operand[0] != '#' || !operand[1])
      return false;

   p = operand + 1;
   if (*p == '$') {
      base = 16;
      p++;
   }
   else if (*p == '%') {
      base = 2;
      p++;
   }
   else if (p[0] == '0' && (p[1] == 'x' || p[1] == 'X')) {
      base = 16;
      p += 2;
   }

   if (!*p)
      return false;

   value = strtol(p, &end, base);
   if (!end || *end || value < 0 || value > 255)
      return false;

   *out_value = (int) value;
   return true;
}

//! @brief Rewrite a generated immediate A load to use a folded byte literal.
static void rewrite_lda_immediate(PeepholeLine *line, int value) {
   char buf[32];

   snprintf(buf, sizeof(buf), "    lda #$%02x", value & 0xff);
   free(line->text);
   line->text = strdup(buf);
   line->trim = trim_in_place(line->text);
   free(line->operand);
   line->operand = strdup(line->trim + 4);
   line->size = instruction_size_for(line->mnemonic, line->operand);
}

//! @brief Remove a folded immediate A ALU operation and update peephole accounting.
static void remove_folded_const_alu(PeepholeLine *line, PeepholeStats *stats, int index, const char *kind, int *changed) {
   line->keep = false;
   stats->pass_removed++;
   stats->pass_saved += line->size;
   stats->total_saved += line->size;
   stats->pass_const_alu++;
   log_rewrite(kind, index, line, line->size);
   *changed = 1;
}


//! @brief Remove a dead adjacent load that is overwritten before its value or N/Z flags can be observed.
static void remove_dead_load(PeepholeLine *line, PeepholeStats *stats, int index, int *changed) {
   line->keep = false;
   stats->pass_removed++;
   stats->pass_saved += line->size;
   stats->total_saved += line->size;
   stats->pass_dead_load++;
   log_rewrite("dead_load", index, line, line->size);
   *changed = 1;
}

//! @brief Return previous kept non-comment line before an index, or NULL when none exists.
static PeepholeLine *previous_kept_effective_line(PeepholeLine *lines, int index) {
   for (int j = index - 1; j >= 0; j--) {
      if (!lines[j].keep || lines[j].is_blank_or_comment)
         continue;
      return &lines[j];
   }
   return NULL;
}

//! @brief Return whether previous load into the same register is made dead by this adjacent load.
static bool previous_same_reg_load_is_dead(PeepholeLine *prev, const PeepholeLine *line) {
   return prev &&
          prev->is_generated && prev->is_instruction && !prev->is_inline_asm &&
          line->is_generated && line->is_instruction && !line->is_inline_asm &&
          same_text(prev->mnemonic, line->mnemonic) &&
          (!strcmp(line->mnemonic, "lda") || !strcmp(line->mnemonic, "ldx") || !strcmp(line->mnemonic, "ldy")) &&
          operand_is_safe_load_value(prev->operand);
}
//! @brief Return whether mnemonic overwrites N/Z flags before they can be observed.
static bool mnemonic_writes_nz_flags(const char *mnemonic, const char *operand) {
   static const char *const writes_nz[] = {
      "adc", "and", "asl", "bit", "cmp", "cpx", "cpy", "dec", "dex", "dey",
      "eor", "inc", "inx", "iny", "lda", "ldx", "ldy", "lsr", "ora", "pla",
      "rol", "ror", "sbc", "tax", "tay", "tsx", "txa", "tya", NULL
   };

   (void) operand;
   return string_in_list(mnemonic, writes_nz);
}

//! @brief Return whether the N/Z side effects of removing a load are dead before any observable use.
static bool load_nz_flags_are_dead_after(PeepholeLine *lines, int count, int index) {
   for (int i = index + 1; i < count; i++) {
      PeepholeLine *line = &lines[i];

      if (!line->keep || line->is_blank_or_comment)
         continue;

      if (line->is_inline_asm)
         return false;

      if (line->is_label_only)
         continue;

      if (line->is_directive || !line->is_generated)
         return false;

      if (!line->is_instruction)
         continue;

      if ((!strcmp(line->mnemonic, "jmp") || is_branch_mnemonic(line->mnemonic)) && target_is_immediately_following_label(lines, count, i, line->operand))
         continue;

      if (mnemonic_reads_nz_flags(line->mnemonic))
         return false;

      if (mnemonic_splits_control_flow(line->mnemonic))
         return false;

      if (!strcmp(line->mnemonic, "jsr") || !strcmp(line->mnemonic, "jmp") || !strcmp(line->mnemonic, "rts") || !strcmp(line->mnemonic, "rti"))
         return false;

      if (mnemonic_writes_nz_flags(line->mnemonic, line->operand))
         return true;
   }

   return false;
}

//! @brief Return whether loading operand into a register would be redundant and preserve or safely discard N/Z side effects.
static bool load_is_redundant(PeepholeLine *lines, int count, int index, const char *reg_value, const char *flags_value, const char *operand, char **mem_values) {
   const char *value = known_value_for_operand(operand, mem_values);
   if (!value || !same_text(reg_value, value))
      return false;
   return same_text(flags_value, value) || load_nz_flags_are_dead_after(lines, count, index);
}

//! @brief Return whether a conditional branch is provably not taken from the tracked flag facts.
static bool branch_is_never_taken(const char *mnemonic, const char *flags_value, const char *carry_state, const char *overflow_state) {
   int value;

   if (!mnemonic)
      return false;

   if ((!strcmp(mnemonic, "beq") || !strcmp(mnemonic, "bne") || !strcmp(mnemonic, "bmi") || !strcmp(mnemonic, "bpl")) &&
       parse_immediate_byte(flags_value, &value)) {
      bool z = (value & 0xff) == 0;
      bool n = (value & 0x80) != 0;

      if (!strcmp(mnemonic, "beq"))
         return !z;
      if (!strcmp(mnemonic, "bne"))
         return z;
      if (!strcmp(mnemonic, "bmi"))
         return !n;
      return n;
   }

   if (!strcmp(mnemonic, "bcc"))
      return same_text(carry_state, "sec");
   if (!strcmp(mnemonic, "bcs"))
      return same_text(carry_state, "clc");
   if (!strcmp(mnemonic, "bvs"))
      return same_text(overflow_state, "clv");

   return false;
}

//! @brief Remove a conditional branch that is provably never taken and update peephole accounting.
static void remove_never_taken_branch(PeepholeLine *line, PeepholeStats *stats, int index, int *changed) {
   line->keep = false;
   stats->pass_removed++;
   stats->pass_saved += line->size;
   stats->total_saved += line->size;
   stats->pass_never_branch++;
   log_rewrite("never_branch", index, line, line->size);
   *changed = 1;
}

//! @brief Return whether a register transfer would leave the destination and observable N/Z flags unchanged.
static bool transfer_is_redundant(PeepholeLine *lines, int count, int index, const char *dst_value, const char *src_value, const char *flags_value) {
   if (!src_value || !same_text(dst_value, src_value))
      return false;
   return same_text(flags_value, src_value) || load_nz_flags_are_dead_after(lines, count, index);
}

//! @brief Track the value and flags produced by a load into one register.
static void set_loaded_reg_state(char **reg_value, char **flags_value, const char *operand, char **mem_values) {
   const char *value = known_value_for_operand(operand, mem_values);
   set_reg_state(reg_value, value);
   set_reg_state(flags_value, value);
}

//! @brief Invalidate a tracked value if it is known only by reference to a changed operand.
static void invalidate_if_refs(char **slot, const char *operand) {
   if (same_text(*slot, operand))
      clear_state(slot);
}

//! @brief Invalidate all register/flag values that refer to one compiler zero-page operand.
static void invalidate_operand_refs(char **a, char **x, char **y, char **flags, const char *operand) {
   invalidate_if_refs(a, operand);
   invalidate_if_refs(x, operand);
   invalidate_if_refs(y, operand);
   invalidate_if_refs(flags, operand);
}

//! @brief Invalidate all register/flag values that refer to any compiler zero-page operand.
static void invalidate_all_zp_refs(char **a, char **x, char **y, char **flags) {
   for (int i = 0; i < COMPILER_ZP_OPERAND_COUNT; i++) {
      invalidate_operand_refs(a, x, y, flags, compiler_zp_operand_names[i]);
   }
}

//! @brief Invalidate tracked memory values that are known only by reference to a changed operand.
static void invalidate_mem_refs(char **mem_values, const char *operand) {
   for (int i = 0; i < COMPILER_ZP_OPERAND_COUNT; i++) {
      if (same_text(mem_values[i], operand))
         clear_state(&mem_values[i]);
   }
}

//! @brief Return whether storing a register value into a compiler zero-page operand is redundant.
static bool store_is_redundant(char **mem_values, const char *operand, const char *source_value) {
   int idx = compiler_zp_operand_index(operand);
   const char *known;

   if (idx < 0 || !source_value)
      return false;

   known = mem_values[idx] ? mem_values[idx] : compiler_zp_operand_names[idx];
   return same_text(known, source_value);
}

//! @brief Remove a redundant compiler scratch store and update peephole accounting.
static void remove_redundant_store(PeepholeLine *line, PeepholeStats *stats, int index, const char *kind, int *changed) {
   line->keep = false;
   stats->pass_removed++;
   stats->pass_saved += line->size;
   stats->total_saved += line->size;
   stats->pass_dup_store++;
   log_rewrite(kind, index, line, line->size);
   *changed = 1;
}

//! @brief Remove a redundant register transfer and update peephole accounting.
static void remove_redundant_transfer(PeepholeLine *line, PeepholeStats *stats, int index, const char *kind, int *changed) {
   line->keep = false;
   stats->pass_removed++;
   stats->pass_saved += line->size;
   stats->total_saved += line->size;
   stats->pass_dup_transfer++;
   log_rewrite(kind, index, line, line->size);
   *changed = 1;
}

//! @brief Remove a redundant simple status-flag instruction and update peephole accounting.
static void remove_redundant_status(PeepholeLine *line, PeepholeStats *stats, int index, int *changed) {
   line->keep = false;
   stats->pass_removed++;
   stats->pass_saved += line->size;
   stats->total_saved += line->size;
   stats->pass_dup_status++;
   log_rewrite("dup_status", index, line, line->size);
   *changed = 1;
}

//! @brief Track a store into memory and invalidate stale loads from aliased compiler scratch bytes.
static int track_memory_store(char **a, char **x, char **y, char **flags, char **mem_values, const char *operand, const char *source_value) {
   int idx = compiler_zp_operand_index(operand);

   if (idx < 0) {
      clear_mem_state(mem_values);
      invalidate_all_zp_refs(a, x, y, flags);
      return -1;
   }

   if (!same_text(source_value, compiler_zp_operand_names[idx])) {
      invalidate_operand_refs(a, x, y, flags, compiler_zp_operand_names[idx]);
      invalidate_mem_refs(mem_values, compiler_zp_operand_names[idx]);
   }
   set_reg_state(&mem_values[idx], source_value);
   return idx;
}

//! @brief When a store writes an unknown register value into tracked scratch, remember that the source register now equals that scratch byte.
static void track_unknown_store_source(char **source_reg, const char *source_value, int stored_idx) {
   if (stored_idx >= 0 && !source_value)
      set_reg_state(source_reg, compiler_zp_operand_names[stored_idx]);
}

//! @brief Track an instruction that modifies memory in place and produces unknown N/Z flags.
static void track_memory_modify(char **a, char **x, char **y, char **flags, char **mem_values, const char *operand) {
   int idx = compiler_zp_operand_index(operand);

   if (idx < 0) {
      clear_mem_state(mem_values);
      invalidate_all_zp_refs(a, x, y, flags);
   }
   else {
      clear_state(&mem_values[idx]);
      invalidate_operand_refs(a, x, y, flags, compiler_zp_operand_names[idx]);
      invalidate_mem_refs(mem_values, compiler_zp_operand_names[idx]);
   }
   clear_state(flags);
}

//! @brief Return whether an instruction mutates A and N/Z in a way the peephole pass does not model.
static bool mnemonic_unknown_a_result(const char *mnemonic) {
   static const char *const unknown_a[] = { "adc", "and", "eor", "ora", "sbc", NULL };
   return string_in_list(mnemonic, unknown_a);
}

//! @brief Return whether an instruction mutates memory in place.
static bool mnemonic_modifies_memory(const char *mnemonic) {
   static const char *const modifies_memory[] = { "inc", "dec", "asl", "lsr", "rol", "ror", NULL };
   return string_in_list(mnemonic, modifies_memory);
}

//! @brief Run the peephole pass stage of the compiler tool pipeline.
static int run_peephole_pass(PeepholeLine *lines, int count, PeepholeStats *stats) {
   char *reg_a = NULL;
   char *reg_x = NULL;
   char *reg_y = NULL;
   char *flags_value = NULL;
   char *carry_state = NULL;
   char *decimal_state = NULL;
   char *interrupt_state = NULL;
   char *overflow_state = NULL;
   char **mem_values = (char **) calloc((size_t) COMPILER_ZP_OPERAND_COUNT, sizeof(char *));
   int changed = 0;

   stats->pass_bytes = 0;
   stats->pass_removed = 0;
   stats->pass_saved = 0;
   stats->pass_dup_load = 0;
   stats->pass_dup_store = 0;
   stats->pass_dup_transfer = 0;
   stats->pass_dup_status = 0;
   stats->pass_const_alu = 0;
   stats->pass_dead_load = 0;
   stats->pass_never_branch = 0;
   stats->pass_jump_next = 0;
   stats->pass_branch_next = 0;

   for (int i = 0; i < count; i++) {
      PeepholeLine *line = &lines[i];

      if (!line->keep)
         continue;

      if (line->is_instruction)
         stats->pass_bytes += line->size;

      if (line->is_inline_asm) {
         reset_peephole_state(&reg_a, &reg_x, &reg_y, &flags_value, mem_values);
         clear_state(&carry_state);
         clear_state(&decimal_state);
         clear_state(&interrupt_state);
         clear_state(&overflow_state);
         continue;
      }

      if (line->is_label_only || line->is_directive || !line->is_generated) {
         reset_peephole_state(&reg_a, &reg_x, &reg_y, &flags_value, mem_values);
         clear_state(&carry_state);
         clear_state(&decimal_state);
         clear_state(&interrupt_state);
         clear_state(&overflow_state);
         continue;
      }

      if (!line->is_instruction)
         continue;

      if ((!strcmp(line->mnemonic, "jmp") || is_branch_mnemonic(line->mnemonic)) && target_is_immediately_following_label(lines, count, i, line->operand)) {
         line->keep = false;
         stats->pass_removed++;
         stats->pass_saved += line->size;
         stats->total_saved += line->size;
         if (!strcmp(line->mnemonic, "jmp")) {
            stats->pass_jump_next++;
            log_rewrite("jump_next", i, line, line->size);
         }
         else {
            stats->pass_branch_next++;
            log_rewrite("branch_next", i, line, line->size);
         }
         changed = 1;
         continue;
      }

      if (is_branch_mnemonic(line->mnemonic) && branch_is_never_taken(line->mnemonic, flags_value, carry_state, overflow_state)) {
         remove_never_taken_branch(line, stats, i, &changed);
         continue;
      }

      if (mnemonic_sets_simple_status_flag(line->mnemonic)) {
         char **status_slot = NULL;

         if (!strcmp(line->mnemonic, "clc") || !strcmp(line->mnemonic, "sec"))
            status_slot = &carry_state;
         else if (!strcmp(line->mnemonic, "cld") || !strcmp(line->mnemonic, "sed"))
            status_slot = &decimal_state;
         else if (!strcmp(line->mnemonic, "cli") || !strcmp(line->mnemonic, "sei"))
            status_slot = &interrupt_state;
         else if (!strcmp(line->mnemonic, "clv"))
            status_slot = &overflow_state;

         if (status_slot && simple_status_write_is_same(*status_slot, line->mnemonic)) {
            remove_redundant_status(line, stats, i, &changed);
            continue;
         }

         if (status_slot)
            set_reg_state(status_slot, line->mnemonic);
      }

      if (mnemonic_is_foldable_a_imm_alu(line->mnemonic)) {
         PeepholeLine *prev = NULL;
         int lhs, rhs, result = 0;

         prev = previous_kept_effective_line(lines, i);

         if (prev && prev->is_generated && prev->is_instruction && !prev->is_inline_asm &&
             !strcmp(prev->mnemonic, "lda") && parse_immediate_byte(prev->operand, &lhs) && parse_immediate_byte(line->operand, &rhs)) {
            if (!strcmp(line->mnemonic, "and"))
               result = lhs & rhs;
            else if (!strcmp(line->mnemonic, "eor"))
               result = lhs ^ rhs;
            else
               result = lhs | rhs;

            rewrite_lda_immediate(prev, result);
            set_reg_state(&reg_a, prev->operand);
            set_reg_state(&flags_value, prev->operand);
            remove_folded_const_alu(line, stats, i, "const_alu", &changed);
            continue;
         }
      }

      if (!strcmp(line->mnemonic, "lda") || !strcmp(line->mnemonic, "ldx") || !strcmp(line->mnemonic, "ldy")) {
         PeepholeLine *prev = previous_kept_effective_line(lines, i);
         if (previous_same_reg_load_is_dead(prev, line)) {
            remove_dead_load(prev, stats, (int) (prev - lines), &changed);
            if (!strcmp(line->mnemonic, "lda"))
               clear_state(&reg_a);
            else if (!strcmp(line->mnemonic, "ldx"))
               clear_state(&reg_x);
            else
               clear_state(&reg_y);
            clear_state(&flags_value);
         }
      }

      if (!strcmp(line->mnemonic, "lda") && operand_is_safe_load_value(line->operand) && load_is_redundant(lines, count, i, reg_a, flags_value, line->operand, mem_values)) {
         line->keep = false;
         stats->pass_removed++;
         stats->pass_saved += line->size;
         stats->total_saved += line->size;
         stats->pass_dup_load++;
         log_rewrite("dup_lda", i, line, line->size);
         changed = 1;
         continue;
      }
      if (!strcmp(line->mnemonic, "ldx") && operand_is_safe_load_value(line->operand) && load_is_redundant(lines, count, i, reg_x, flags_value, line->operand, mem_values)) {
         line->keep = false;
         stats->pass_removed++;
         stats->pass_saved += line->size;
         stats->total_saved += line->size;
         stats->pass_dup_load++;
         log_rewrite("dup_ldx", i, line, line->size);
         changed = 1;
         continue;
      }
      if (!strcmp(line->mnemonic, "ldy") && operand_is_safe_load_value(line->operand) && load_is_redundant(lines, count, i, reg_y, flags_value, line->operand, mem_values)) {
         line->keep = false;
         stats->pass_removed++;
         stats->pass_saved += line->size;
         stats->total_saved += line->size;
         stats->pass_dup_load++;
         log_rewrite("dup_ldy", i, line, line->size);
         changed = 1;
         continue;
      }

      if (!strcmp(line->mnemonic, "tax") && transfer_is_redundant(lines, count, i, reg_x, reg_a, flags_value)) {
         remove_redundant_transfer(line, stats, i, "dup_tax", &changed);
         continue;
      }
      if (!strcmp(line->mnemonic, "tay") && transfer_is_redundant(lines, count, i, reg_y, reg_a, flags_value)) {
         remove_redundant_transfer(line, stats, i, "dup_tay", &changed);
         continue;
      }
      if (!strcmp(line->mnemonic, "txa") && transfer_is_redundant(lines, count, i, reg_a, reg_x, flags_value)) {
         remove_redundant_transfer(line, stats, i, "dup_txa", &changed);
         continue;
      }
      if (!strcmp(line->mnemonic, "tya") && transfer_is_redundant(lines, count, i, reg_a, reg_y, flags_value)) {
         remove_redundant_transfer(line, stats, i, "dup_tya", &changed);
         continue;
      }

      if (!strcmp(line->mnemonic, "lda")) {
         set_loaded_reg_state(&reg_a, &flags_value, line->operand, mem_values);
      }
      else if (!strcmp(line->mnemonic, "ldx")) {
         set_loaded_reg_state(&reg_x, &flags_value, line->operand, mem_values);
      }
      else if (!strcmp(line->mnemonic, "ldy")) {
         set_loaded_reg_state(&reg_y, &flags_value, line->operand, mem_values);
      }
      else if (!strcmp(line->mnemonic, "sta")) {
         if (store_is_redundant(mem_values, line->operand, reg_a)) {
            remove_redundant_store(line, stats, i, "dup_sta", &changed);
            continue;
         }
         {
            const char *source_value = reg_a;
            int stored_idx = track_memory_store(&reg_a, &reg_x, &reg_y, &flags_value, mem_values, line->operand, source_value);
            track_unknown_store_source(&reg_a, source_value, stored_idx);
         }
      }
      else if (!strcmp(line->mnemonic, "stx")) {
         if (store_is_redundant(mem_values, line->operand, reg_x)) {
            remove_redundant_store(line, stats, i, "dup_stx", &changed);
            continue;
         }
         {
            const char *source_value = reg_x;
            int stored_idx = track_memory_store(&reg_a, &reg_x, &reg_y, &flags_value, mem_values, line->operand, source_value);
            track_unknown_store_source(&reg_x, source_value, stored_idx);
         }
      }
      else if (!strcmp(line->mnemonic, "sty")) {
         if (store_is_redundant(mem_values, line->operand, reg_y)) {
            remove_redundant_store(line, stats, i, "dup_sty", &changed);
            continue;
         }
         {
            const char *source_value = reg_y;
            int stored_idx = track_memory_store(&reg_a, &reg_x, &reg_y, &flags_value, mem_values, line->operand, source_value);
            track_unknown_store_source(&reg_y, source_value, stored_idx);
         }
      }
      else if (!strcmp(line->mnemonic, "cmp") || !strcmp(line->mnemonic, "cpx") || !strcmp(line->mnemonic, "cpy")) {
         clear_state(&flags_value);
         clear_state(&carry_state);
      }
      else if (!strcmp(line->mnemonic, "bit")) {
         clear_state(&flags_value);
         clear_state(&overflow_state);
      }
      else if (mnemonic_unknown_a_result(line->mnemonic)) {
         clear_state(&reg_a);
         clear_state(&flags_value);
         if (!strcmp(line->mnemonic, "adc") || !strcmp(line->mnemonic, "sbc")) {
            clear_state(&carry_state);
            clear_state(&overflow_state);
         }
      }
      else if (mnemonic_modifies_memory(line->mnemonic)) {
         if (operand_is_accumulator(line->operand) || !line->operand || !*line->operand) {
            clear_state(&reg_a);
            clear_state(&flags_value);
         }
         else {
            track_memory_modify(&reg_a, &reg_x, &reg_y, &flags_value, mem_values, line->operand);
         }
         clear_state(&carry_state);
      }
      else if (!strcmp(line->mnemonic, "pla")) {
         clear_state(&reg_a);
         clear_state(&flags_value);
      }
      else if (!strcmp(line->mnemonic, "plp")) {
         clear_state(&flags_value);
         clear_state(&carry_state);
         clear_state(&decimal_state);
         clear_state(&interrupt_state);
         clear_state(&overflow_state);
      }
      else if (!strcmp(line->mnemonic, "tax")) {
         set_reg_state(&reg_x, reg_a);
         set_reg_state(&flags_value, reg_a);
      }
      else if (!strcmp(line->mnemonic, "tay")) {
         set_reg_state(&reg_y, reg_a);
         set_reg_state(&flags_value, reg_a);
      }
      else if (!strcmp(line->mnemonic, "txa")) {
         set_reg_state(&reg_a, reg_x);
         set_reg_state(&flags_value, reg_x);
      }
      else if (!strcmp(line->mnemonic, "tya")) {
         set_reg_state(&reg_a, reg_y);
         set_reg_state(&flags_value, reg_y);
      }
      else if (!strcmp(line->mnemonic, "tsx")) {
         clear_state(&reg_x);
         clear_state(&flags_value);
      }
      else if (!strcmp(line->mnemonic, "inx") || !strcmp(line->mnemonic, "dex")) {
         clear_state(&reg_x);
         clear_state(&flags_value);
      }
      else if (!strcmp(line->mnemonic, "iny") || !strcmp(line->mnemonic, "dey")) {
         clear_state(&reg_y);
         clear_state(&flags_value);
      }
      else if (!strcmp(line->mnemonic, "jsr") || !strcmp(line->mnemonic, "rts") || !strcmp(line->mnemonic, "rti")) {
         reset_peephole_state(&reg_a, &reg_x, &reg_y, &flags_value, mem_values);
         clear_state(&carry_state);
         clear_state(&decimal_state);
         clear_state(&interrupt_state);
         clear_state(&overflow_state);
      }
      else if (!strcmp(line->mnemonic, "jmp")) {
         reset_peephole_state(&reg_a, &reg_x, &reg_y, &flags_value, mem_values);
         clear_state(&carry_state);
         clear_state(&decimal_state);
         clear_state(&interrupt_state);
         clear_state(&overflow_state);
      }
      else if (is_branch_mnemonic(line->mnemonic) ||
               !strcmp(line->mnemonic, "pha") ||
               !strcmp(line->mnemonic, "php") ||
               !strcmp(line->mnemonic, "clc") ||
               !strcmp(line->mnemonic, "sec") ||
               !strcmp(line->mnemonic, "cld") ||
               !strcmp(line->mnemonic, "sed") ||
               !strcmp(line->mnemonic, "cli") ||
               !strcmp(line->mnemonic, "sei") ||
               !strcmp(line->mnemonic, "clv") ||
               !strcmp(line->mnemonic, "nop") ||
               !strcmp(line->mnemonic, "txs")) {
         /* These instructions do not alter tracked register values or N/Z in a way relevant to duplicate load removal. */
      }
      else {
         reset_peephole_state(&reg_a, &reg_x, &reg_y, &flags_value, mem_values);
         clear_state(&carry_state);
         clear_state(&decimal_state);
         clear_state(&interrupt_state);
         clear_state(&overflow_state);
      }
   }

   reset_peephole_state(&reg_a, &reg_x, &reg_y, &flags_value, mem_values);
   clear_state(&carry_state);
   clear_state(&decimal_state);
   clear_state(&interrupt_state);
   clear_state(&overflow_state);
   free(mem_values);
   return changed;
}

//! @brief Collect instruction bytes from existing compiler assembly emitter state for a later pass.
static int count_instruction_bytes(PeepholeLine *lines, int count) {
   int total = 0;
   for (int i = 0; i < count; i++) {
      if (lines[i].keep && lines[i].is_instruction)
         total += lines[i].size;
   }
   return total;
}

//! @brief Collect instructions from existing compiler assembly emitter state for a later pass.
static int count_instructions(PeepholeLine *lines, int count) {
   int total = 0;
   for (int i = 0; i < count; i++) {
      if (lines[i].keep && lines[i].is_instruction)
         total++;
   }
   return total;
}

//! @brief Emit peephole stats for compiler assembly emitter diagnostics or output files.
static void print_peephole_stats(int pass_index, const char *phase, PeepholeLine *lines, int count, const PeepholeStats *stats) {
   if (!get_xray(XRAY_PEEPHOLE))
      return;

   message("%03d %-10s bytes=%d insns=%d removed=%d saved=%d total_saved=%d dup_load=%d dup_store=%d dup_transfer=%d dup_status=%d const_alu=%d dead_load=%d never_branch=%d jump_next=%d branch_next=%d",
         pass_index,
         phase,
         count_instruction_bytes(lines, count),
         count_instructions(lines, count),
         stats->pass_removed,
         stats->pass_saved,
         stats->total_saved,
         stats->pass_dup_load,
         stats->pass_dup_store,
         stats->pass_dup_transfer,
         stats->pass_dup_status,
         stats->pass_const_alu,
         stats->pass_dead_load,
         stats->pass_never_branch,
         stats->pass_jump_next,
         stats->pass_branch_next);
}

//! @brief Emit peephole optimize for compiler assembly emitter diagnostics or output files.
void emit_peephole_optimize(EmitSink *es) {
   char *joined;
   char **raw_lines = NULL;
   PeepholeLine *lines;
   int count;
   PeepholeStats stats;
   int pass_index = 0;
   int changed;
   size_t total_len = 0;
   char *out;
   size_t off = 0;
   EmitPiece *piece;

   if (!es || !es->head)
      return;

   joined = emit_sink_join(es);
   count = split_lines(joined, &raw_lines);
   lines = (PeepholeLine *) calloc((size_t) count, sizeof(PeepholeLine));
   for (int i = 0; i < count; i++) {
      lines[i].text = raw_lines[i];
      parse_line(&lines[i]);
   }
   annotate_inline_asm_lines(lines, count);
   free(raw_lines);
   free(joined);

   memset(&stats, 0, sizeof(stats));
   stats.total_before = count_instruction_bytes(lines, count);

   do {
      pass_index++;
      changed = run_peephole_pass(lines, count, &stats);
      print_peephole_stats(pass_index, changed ? "peephole" : "stable", lines, count, &stats);
   } while (changed && pass_index < 20);

   for (int i = 0; i < count; i++) {
      if (!lines[i].keep)
         continue;
      total_len += strlen(lines[i].text) + 1;
   }
   out = (char *) malloc(total_len + 1);
   for (int i = 0; i < count; i++) {
      size_t len;
      if (!lines[i].keep)
         continue;
      len = strlen(lines[i].text);
      memcpy(out + off, lines[i].text, len);
      off += len;
      out[off++] = '\n';
   }
   out[off] = '\0';

   free_emit_sink_pieces(es);
   piece = (EmitPiece *) malloc(sizeof(EmitPiece));
   piece->txt = out;
   piece->next = NULL;
   es->head = es->tail = piece;

   free_lines(lines, count);
}

//! @brief Emit emit for compiler assembly emitter diagnostics or output files.
void emit(EmitSink *es, const char *fmt, ...) {
   int len;
   va_list args;

   va_start(args, fmt);
   len = vsnprintf(NULL, 0, fmt, args);
   va_end(args);

   EmitPiece *piece = (EmitPiece *) malloc (sizeof(EmitPiece));
   piece->txt = (char *) malloc(len + 1);

   va_start(args, fmt);
   vsprintf((char *) piece->txt, fmt, args);
   va_end(args);

   piece->next = NULL;
   if (es->head == NULL) {
      es->head = es->tail = piece;
   }
   else {
      es->tail->next = piece;
      es->tail = piece;
   }
}

//! @brief Emit print for compiler assembly emitter diagnostics or output files.
void emit_print(EmitSink *es, FILE *out) {
   if (!out) {
      out = stdout;
   }

   for (EmitPiece *ep = es->head; ep; ep = ep->next) {
      fprintf(out, "%s", ep->txt);
   }
}
