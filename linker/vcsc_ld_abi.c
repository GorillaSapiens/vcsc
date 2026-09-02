//! @file linker/vcsc_ld_abi.c
//! @brief Implements link-time ABI metadata validation for the VCSC linker.
//! @ingroup linker

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

#include "vcsc_ld_abi.h"

typedef struct {
   const char *origin;
   char *kind;
   char *state;
   char *symbol;
   char *role;
   char *fingerprint;
   char *detail;
} abi_record_t;

static void collect_object_records(const object_file_t *obj,
                                   abi_record_t **records,
                                   size_t *count);

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
      fprintf(stderr, "vcsc-ld: malformed ABI metadata export '%s' in %s\n", sym->name, origin);
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

typedef struct {
   int has_read;
   uint16_t read_start;
   int has_write;
   uint16_t write_start;
   uint32_t size;
} absolute_binding_range_t;

//! @brief Parse one canonical absolute-binding range fingerprint emitted by vcsc-cc1.
static int parse_absolute_binding_range(const abi_record_t *rec,
                                        absolute_binding_range_t *out)
{
   char *copy;
   char *tok;
   int have_read = 0;
   int have_write = 0;
   int have_size = 0;

   if (!rec || !out || strcmp(rec->kind, "absolute_binding") != 0 ||
       strcmp(rec->role, "region_guard") != 0)
      return 0;

   memset(out, 0, sizeof(*out));
   copy = xstrdup(rec->fingerprint ? rec->fingerprint : "");
   tok = strtok(copy, ",");
   while (tok) {
      if (strncmp(tok, "read=", 5) == 0) {
         const char *value = tok + 5;
         char *end = NULL;
         unsigned long n;
         if (strcmp(value, "none") == 0) {
            out->has_read = 0;
         } else {
            n = strtoul(value, &end, 0);
            if (!end || *end != '\0' || n > 0xFFFFul)
               goto malformed;
            out->has_read = 1;
            out->read_start = (uint16_t)n;
         }
         have_read = 1;
      } else if (strncmp(tok, "write=", 6) == 0) {
         const char *value = tok + 6;
         char *end = NULL;
         unsigned long n;
         if (strcmp(value, "none") == 0) {
            out->has_write = 0;
         } else {
            n = strtoul(value, &end, 0);
            if (!end || *end != '\0' || n > 0xFFFFul)
               goto malformed;
            out->has_write = 1;
            out->write_start = (uint16_t)n;
         }
         have_write = 1;
      } else if (strncmp(tok, "size=", 5) == 0) {
         char *end = NULL;
         unsigned long n = strtoul(tok + 5, &end, 0);
         if (!end || *end != '\0' || n == 0 || n > 0x10000ul)
            goto malformed;
         out->size = (uint32_t)n;
         have_size = 1;
      } else {
         goto malformed;
      }
      tok = strtok(NULL, ",");
   }
   free(copy);
   if (!have_read || !have_write || !have_size)
      goto malformed_after_free;
   if ((out->has_read && (uint32_t)out->read_start + out->size > 0x10000u) ||
       (out->has_write && (uint32_t)out->write_start + out->size > 0x10000u))
      goto malformed_after_free;
   return 1;

malformed:
   free(copy);
malformed_after_free:
   fprintf(stderr,
           "vcsc-ld: malformed absolute-binding range metadata '%s' in %s\n",
           rec->fingerprint ? rec->fingerprint : "", rec->origin);
   exit(1);
}

//! @brief Return whether two non-wrapping half-open address ranges overlap.
static int address_ranges_overlap(uint32_t a_start, uint32_t a_size,
                                  uint32_t b_start, uint32_t b_size)
{
   return a_start < b_start + b_size && b_start < a_start + a_size;
}

//! @brief Reject absolute external bindings whose read or write side overlaps linker-managed MEMORY.
void validate_absolute_binding_memory_regions(const linker_config_t *cfg,
                                              const input_set_t *in)
{
   abi_record_t *records = NULL;
   size_t count = 0;
   size_t i;
   size_t j;

   if (!cfg || !in)
      return;

   for (i = 0; i < in->object_count; ++i)
      collect_object_records(&in->objects[i], &records, &count);

   for (i = 0; i < count; ++i) {
      absolute_binding_range_t range;
      if (!parse_absolute_binding_range(&records[i], &range))
         continue;

      for (j = 0; j < cfg->mem_count; ++j) {
         const memory_region_t *mem = &cfg->mem[j];
         uint32_t read_start;
         uint32_t write_start;
         if (mem->data_bank_name[0] || mem->swapram)
            continue;
         read_start = mem->start;
         write_start = mem->has_write_start ? mem->write_start : mem->start;

         if (range.has_read &&
             address_ranges_overlap(range.read_start, range.size,
                                    read_start, mem->size)) {
            fprintf(stderr,
                    "vcsc-ld: %s overlaps allocator-managed MEMORY region '%s' read window $%04X-$%04X\n",
                    records[i].detail ? records[i].detail : records[i].symbol,
                    mem->name, mem->start,
                    (unsigned int)((uint32_t)mem->start + mem->size - 1u));
            goto fail;
         }
         if (range.has_write &&
             address_ranges_overlap(range.write_start, range.size,
                                    write_start, mem->size)) {
            fprintf(stderr,
                    "vcsc-ld: %s overlaps allocator-managed MEMORY region '%s' write window $%04X-$%04X\n",
                    records[i].detail ? records[i].detail : records[i].symbol,
                    mem->name, (unsigned int)write_start,
                    (unsigned int)(write_start + mem->size - 1u));
            goto fail;
         }
      }
   }

   for (i = 0; i < count; ++i)
      free_abi_record(&records[i]);
   free(records);
   return;

fail:
   for (i = 0; i < count; ++i)
      free_abi_record(&records[i]);
   free(records);
   exit(1);
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
   if (!strcmp(role, "code_regions"))
      return "code regions";
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
   fprintf(stderr, "vcsc-ld: ABI/type fingerprint mismatch for %s symbol '%s' %s\n",
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
