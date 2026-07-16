//! @file linker/n65ld_abi.c
//! @brief Implements link-time ABI metadata validation for the n65 linker.
//! @ingroup linker

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

#include "n65ld_abi.h"

typedef struct {
   const char *origin;
   char *kind;
   char *state;
   char *symbol;
   char *role;
   char *fingerprint;
   char *detail;
} abi_record_t;

//! @brief Create dup for linker ABI metadata checker. The returned storage is owned by the caller or the object that immediately records it.
static char *substr_dup(const char *start, size_t len)
{
   char *s = (char *)xmalloc(len + 1);
   memcpy(s, start, len);
   s[len] = '\0';
   return s;
}

//! @brief Return whether ABI metadata has prefix in linker ABI metadata checker.
int abi_metadata_has_prefix(const char *name)
{
   return name && strncmp(name, ABI_META_PREFIX, sizeof(ABI_META_PREFIX) - 1) == 0;
}

//! @brief Handle hexval logic for linker ABI metadata checker.
static int hexval(int ch)
{
   if (ch >= '0' && ch <= '9')
      return ch - '0';
   if (ch >= 'a' && ch <= 'f')
      return ch - 'a' + 10;
   if (ch >= 'A' && ch <= 'F')
      return ch - 'A' + 10;
   return -1;
}

//! @brief Return meta decode data used by linker ABI metadata checker; returned pointers alias existing storage unless explicitly allocated by the function name.
static char *meta_decode(const char *text)
{
   size_t n = text ? strlen(text) : 0;
   char *out = (char *)xmalloc(n + 1);
   size_t oi = 0;
   size_t i = 0;

   while (text && text[i]) {
      if (text[i] == 'Q' && text[i + 1] && text[i + 2]) {
         int hi = hexval((unsigned char)text[i + 1]);
         int lo = hexval((unsigned char)text[i + 2]);
         if (hi >= 0 && lo >= 0) {
            out[oi++] = (char)((hi << 4) | lo);
            i += 3;
            continue;
         }
      }
      out[oi++] = text[i++];
   }

   out[oi] = '\0';
   return out;
}

//! @brief Parse metadata fields into the normalized representation used by linker ABI metadata checker.
static int split_metadata_fields(const char *name, char **fields, int want)
{
   const char *p = name + sizeof(ABI_META_PREFIX) - 1;
   int count = 0;

   while (count < want) {
      const char *end = strchr(p, '$');
      if (!end) {
         if (count != want - 1)
            return 0;
         fields[count++] = xstrdup(p);
         break;
      }
      fields[count++] = substr_dup(p, (size_t)(end - p));
      p = end + 1;
    }

   return count == want;
}

//! @brief Parse ABI record into the normalized representation used by linker ABI metadata checker.
static int parse_abi_record(const symbol_t *sym, const char *origin, abi_record_t *out)
{
   char *fields[6] = {0};
   int ok;

   if (!abi_metadata_has_prefix(sym->name))
      return 0;

   ok = split_metadata_fields(sym->name, fields, 6);
   if (!ok) {
      int i;
      for (i = 0; i < 6; ++i)
         free(fields[i]);
      fprintf(stderr, "n65ld: malformed ABI metadata export '%s' in %s\n", sym->name, origin);
      exit(1);
   }

   memset(out, 0, sizeof(*out));
   out->origin = origin;
   out->kind = fields[0];
   out->state = fields[1];
   out->symbol = meta_decode(fields[2]);
   out->role = fields[3];
   out->fingerprint = meta_decode(fields[4]);
   out->detail = meta_decode(fields[5]);
   free(fields[2]);
   free(fields[4]);
   free(fields[5]);
   return 1;
}

//! @brief Release ABI record storage owned by linker ABI metadata checker.
static void free_abi_record(abi_record_t *rec)
{
   free(rec->kind);
   free(rec->state);
   free(rec->symbol);
   free(rec->role);
   free(rec->fingerprint);
   free(rec->detail);
}

//! @brief Collect object records from existing linker ABI metadata checker state for a later pass.
static void collect_object_records(const object_file_t *obj, abi_record_t **records, size_t *count)
{
   size_t i;
   for (i = 0; i < obj->export_count; ++i) {
      abi_record_t rec;
      if (!parse_abi_record(&obj->exports[i], obj->origin, &rec))
         continue;
      *records = (abi_record_t *)xrealloc(*records, (*count + 1) * sizeof(**records));
      (*records)[(*count)++] = rec;
   }
}

//! @brief Handle same group logic for linker ABI metadata checker.
static int same_group(const abi_record_t *a, const abi_record_t *b)
{
   return strcmp(a->kind, b->kind) == 0 && strcmp(a->symbol, b->symbol) == 0 && strcmp(a->role, b->role) == 0;
}

//! @brief Return role display data used by linker ABI metadata checker; returned pointers alias existing storage unless explicitly allocated by the function name.
static const char *role_display(const char *role)
{
   static char buf[64];
   long index;
   char *end;

   if (!strcmp(role, "summary"))
      return "summary";
   if (!strcmp(role, "return"))
      return "return type";
   if (!strcmp(role, "object"))
      return "object type";
   if (strncmp(role, "param", 5) == 0) {
      index = strtol(role + 5, &end, 10);
      if (end != role + 5 && *end == '\0') {
         snprintf(buf, sizeof(buf), "parameter %ld", index);
         return buf;
      }
   }
   return role;
}

//! @brief Handle report mismatch logic for linker ABI metadata checker.
static void report_mismatch(const abi_record_t *records, size_t count, size_t first)
{
   size_t i;
   fprintf(stderr, "n65ld: ABI/type fingerprint mismatch for %s symbol '%s' %s\n",
      records[first].kind, records[first].symbol, role_display(records[first].role));

   for (i = first; i < count; ++i) {
      if (!same_group(&records[first], &records[i]))
         continue;
      fprintf(stderr, "  %s: %s -> %s\n",
         records[i].origin,
         records[i].state,
         records[i].detail ? records[i].detail : "(no detail)");
   }
}

//! @brief Validate ABI metadata invariants before later linker stages depend on them.
void validate_abi_metadata(const input_set_t *in)
{
   abi_record_t *records = NULL;
   size_t count = 0;
   size_t i;
   size_t j;

   for (i = 0; i < in->object_count; ++i)
      collect_object_records(&in->objects[i], &records, &count);

   for (i = 0; i < count; ++i) {
      for (j = i + 1; j < count; ++j) {
         if (!same_group(&records[i], &records[j]))
            continue;
         if (strcmp(records[i].fingerprint, records[j].fingerprint) == 0)
            continue;
         report_mismatch(records, count, i);
         for (i = 0; i < count; ++i)
            free_abi_record(&records[i]);
         free(records);
         exit(1);
      }
   }

   for (i = 0; i < count; ++i)
      free_abi_record(&records[i]);
   free(records);
}
