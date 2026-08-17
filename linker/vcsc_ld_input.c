//! @file linker/vcsc_ld_input.c
//! @brief Implements linker input loading for the VCSC linker.
//! @ingroup linker

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "vcsc_ld_internal.h"
#include "vcsc_ld_input.h"

//! @brief Read entire file from the current input position and advance the reader on success.
static uint8_t *read_entire_file(const char *path, size_t *size_out)
{
   FILE *fp = fopen(path, "rb");
   uint8_t *buf;
   long len;
   size_t got;
   if (!fp) {
      fprintf(stderr, "vcsc-ld: cannot open '%s'\n", path);
      exit(1);
   }
   if (fseek(fp, 0, SEEK_END) != 0) {
      fprintf(stderr, "vcsc-ld: cannot seek '%s'\n", path);
      fclose(fp);
      exit(1);
   }
   len = ftell(fp);
   if (len < 0) {
      fprintf(stderr, "vcsc-ld: cannot size '%s'\n", path);
      fclose(fp);
      exit(1);
   }
   if (fseek(fp, 0, SEEK_SET) != 0) {
      fprintf(stderr, "vcsc-ld: cannot rewind '%s'\n", path);
      fclose(fp);
      exit(1);
   }
   buf = (uint8_t *)xmalloc((size_t)len ? (size_t)len : 1);
   got = fread(buf, 1, (size_t)len, fp);
   if (got != (size_t)len) {
      fprintf(stderr, "vcsc-ld: short read '%s'\n", path);
      fclose(fp);
      free(buf);
      exit(1);
   }
   fclose(fp);
   *size_out = (size_t)len;
   return buf;
}

//! @brief Handle reader init logic for linker object/archive loader.
static void reader_init(reader_t *r, const uint8_t *data, size_t size, const char *label)
{
   r->data = data;
   r->size = size;
   r->pos = 0;
   r->label = label;
}

//! @brief Handle reader fail logic for linker object/archive loader.
static void reader_fail(const reader_t *r, const char *msg)
{
   fprintf(stderr, "vcsc-ld: %s at offset 0x%zx in '%s'\n", msg, r->pos, r->label);
   exit(1);
}

//! @brief Read 8-bit from the current input position and advance the reader on success.
static uint8_t rd_u8(reader_t *r)
{
   if (r->pos + 1 > r->size)
      reader_fail(r, "unexpected EOF");
   return r->data[r->pos++];
}

//! @brief Read 16-bit from the current input position and advance the reader on success.
static uint16_t rd_u16(reader_t *r)
{
   uint16_t lo = rd_u8(r);
   uint16_t hi = rd_u8(r);
   return (uint16_t)(lo | (hi << 8));
}

//! @brief Read bytes from the current input position and advance the reader on success.
static void rd_bytes(reader_t *r, uint8_t *dst, size_t n)
{
   if (r->pos + n > r->size)
      reader_fail(r, "unexpected EOF");
   memcpy(dst, r->data + r->pos, n);
   r->pos += n;
}

//! @brief Read C string from the current input position and advance the reader on success.
static char *rd_cstr(reader_t *r)
{
   size_t start = r->pos;
   while (r->pos < r->size && r->data[r->pos] != 0)
      r->pos++;
   if (r->pos >= r->size)
      reader_fail(r, "unterminated string");
   {
      size_t len = r->pos - start;
      char *s = (char *)xmalloc(len + 1);
      memcpy(s, r->data + start, len);
      s[len] = '\0';
      r->pos++;
      return s;
   }
}

//! @brief Parse reloc table old into the normalized representation used by linker object/archive loader.
static int parse_reloc_table_old(reader_t *r, reloc_t **out, size_t *count_out)
{
   reloc_t *items = NULL;
   size_t count = 0;
   long prev = -1;

   for (;;) {
      uint8_t delta = rd_u8(r);
      if (delta == 0)
         break;
      if (delta == 255) {
         prev += 254;
         continue;
      }
      items = (reloc_t *)xrealloc(items, (count + 1) * sizeof(*items));
      memset(&items[count], 0, sizeof(items[count]));
      prev += delta;
      items[count].offset = (uint32_t)prev;
      items[count].type = rd_u8(r);
      items[count].segid = rd_u8(r);
      if (items[count].segid == O26_SEG_UNDEF)
         items[count].undef_index = rd_u16(r);
      if (items[count].type & O26_RTYPE_LAYOUT) {
         items[count].layout_index = rd_u16(r);
         items[count].has_layout_index = 1;
      }
      if (items[count].type & O26_RTYPE_AUX) {
         items[count].aux_low = rd_u8(r);
         items[count].has_aux_low = 1;
      }
      count++;
   }

   *out = items;
   *count_out = count;
   return 1;
}

//! @brief Parse exports into the normalized representation used by linker object/archive loader.
static int parse_exports(reader_t *r, symbol_t **out, size_t *count_out)
{
   size_t i;
   uint16_t count = rd_u16(r);
   symbol_t *items = (symbol_t *)xcalloc(count, sizeof(*items));
   for (i = 0; i < count; ++i) {
      items[i].name = rd_cstr(r);
      items[i].segid = rd_u8(r);
      items[i].value = rd_u16(r);
   }
   *out = items;
   *count_out = count;
   return 1;
}

//! @brief Release partial layouts storage owned by linker object/archive loader.
static void free_partial_layouts(object_layout_t *items, size_t count)
{
   size_t i;
   for (i = 0; i < count; ++i)
      free(items[i].name);
   free(items);
}

//! @brief Parse C string bytes into the normalized representation used by linker object/archive loader.
static int scan_cstr_bytes(const uint8_t *data, size_t size, size_t *pos, char **out)
{
   size_t start = *pos;
   size_t len;

   while (*pos < size && data[*pos] != 0)
      (*pos)++;
   if (*pos >= size)
      return 0;

   len = *pos - start;
   *out = (char *)xmalloc(len + 1);
   memcpy(*out, data + start, len);
   (*out)[len] = '\0';
   (*pos)++;
   return 1;
}

//! @brief Parse layouts with mode into the normalized representation used by linker object/archive loader.
static int parse_layouts_with_mode(const uint8_t *data, size_t size, size_t start, int version,
   object_layout_t **out, size_t *count_out, size_t *end_out)
{
   size_t i;
   size_t pos = start;
   uint16_t count;
   object_layout_t *items;

   if (pos + 2 > size)
      return 0;
   count = (uint16_t)(data[pos] | (data[pos + 1] << 8));
   pos += 2;
   items = (object_layout_t *)xcalloc(count, sizeof(*items));

   for (i = 0; i < count; ++i) {
      if (!scan_cstr_bytes(data, size, &pos, &items[i].name) || pos + 5 > size) {
         free_partial_layouts(items, count);
         return 0;
      }
      items[i].segid = data[pos++];
      items[i].packed_base = (uint16_t)(data[pos] | (data[pos + 1] << 8));
      pos += 2;
      items[i].size = (uint16_t)(data[pos] | (data[pos + 1] << 8));
      pos += 2;
      if (version >= 2) {
         if (pos + 3 > size) {
            free_partial_layouts(items, count);
            return 0;
         }
         items[i].image_segid = data[pos++];
         items[i].image_base = (uint16_t)(data[pos] | (data[pos + 1] << 8));
         pos += 2;
      } else {
         items[i].image_segid = items[i].segid;
         items[i].image_base = items[i].packed_base;
      }
      if (version >= 3) {
         if (pos + 1 > size) {
            free_partial_layouts(items, count);
            return 0;
         }
         items[i].flags = data[pos++];
         if (items[i].flags & ~(O26_LAYOUT_PAGE_CONTAINED | O26_LAYOUT_INDEX_RANGE)) {
            free_partial_layouts(items, count);
            return 0;
         }
      }
      if (version >= 4) {
         uint32_t range_end;
         if (pos + 4 > size) {
            free_partial_layouts(items, count);
            return 0;
         }
         items[i].index_range_start = (uint16_t)(data[pos] | (data[pos + 1] << 8));
         pos += 2;
         items[i].index_range_max = (uint16_t)(data[pos] | (data[pos + 1] << 8));
         pos += 2;
         range_end = (uint32_t)items[i].index_range_start + items[i].index_range_max;
         if ((items[i].flags & O26_LAYOUT_INDEX_RANGE) &&
             (items[i].index_range_max > 255 || range_end >= items[i].size)) {
            free_partial_layouts(items, count);
            return 0;
         }
         if (!(items[i].flags & O26_LAYOUT_INDEX_RANGE) &&
             (items[i].index_range_start != 0 || items[i].index_range_max != 0)) {
            free_partial_layouts(items, count);
            return 0;
         }
      }
   }

   *out = items;
   *count_out = count;
   *end_out = pos;
   return 1;
}

//! @brief Parse layouts any into the normalized representation used by linker object/archive loader.
//! @brief Parse optional branch metadata following a layout table.
static int parse_branches_at(const uint8_t *data, size_t size, size_t start,
   branch_t **out, size_t *count_out, size_t *end_out)
{
   size_t i;
   size_t pos = start;
   size_t record_size;
   uint16_t count;
   branch_t *items;
   int version;

   if (pos == size) {
      *out = NULL;
      *count_out = 0;
      *end_out = pos;
      return 1;
   }
   if (pos + O26_BRANCH_MAGIC_SIZE + 2 > size)
      return 0;
   if (memcmp(data + pos, O26_BRANCH_MAGIC_V2, O26_BRANCH_MAGIC_SIZE) == 0) {
      version = 2;
      record_size = 7;
   } else if (memcmp(data + pos, O26_BRANCH_MAGIC_V1, O26_BRANCH_MAGIC_SIZE) == 0) {
      version = 1;
      record_size = 6;
   } else {
      return 0;
   }
   pos += O26_BRANCH_MAGIC_SIZE;
   count = (uint16_t)(data[pos] | (data[pos + 1] << 8));
   pos += 2;
   if (pos + (size_t)count * record_size != size)
      return 0;

   items = (branch_t *)xcalloc(count ? count : 1, sizeof(*items));
   for (i = 0; i < count; ++i) {
      items[i].segid = data[pos++];
      items[i].source = (uint16_t)(data[pos] | (data[pos + 1] << 8));
      pos += 2;
      items[i].target = (uint16_t)(data[pos] | (data[pos + 1] << 8));
      pos += 2;
      items[i].opcode = data[pos++];
      items[i].page_policy = version >= 2 ? data[pos++] : BRANCH_PAGE_FLEX;
      if (items[i].segid < O26_SEG_TEXT || items[i].segid > O26_SEG_ZP ||
          items[i].page_policy > BRANCH_PAGE_CROSS) {
         free(items);
         return 0;
      }
   }

   *out = items;
   *count_out = count;
   *end_out = pos;
   return 1;
}

//! @brief Parse the newest compatible layout table and optional branch metadata.
static int parse_layouts_any(reader_t *r, object_layout_t **out, size_t *count_out,
   branch_t **branches_out, size_t *branch_count_out)
{
   int version;

   for (version = 4; version >= 1; --version) {
      size_t layout_end = 0;
      size_t metadata_end = 0;
      object_layout_t *layouts = NULL;
      size_t layout_count = 0;
      branch_t *branches = NULL;
      size_t branch_count = 0;

      if (parse_layouts_with_mode(r->data, r->size, r->pos, version,
            &layouts, &layout_count, &layout_end) &&
          parse_branches_at(r->data, r->size, layout_end,
            &branches, &branch_count, &metadata_end) && metadata_end == r->size) {
         *out = layouts;
         *count_out = layout_count;
         *branches_out = branches;
         *branch_count_out = branch_count;
         r->pos = metadata_end;
         return 1;
      }
      free_partial_layouts(layouts, layout_count);
      free(branches);
   }

   *out = NULL;
   *count_out = 0;
   *branches_out = NULL;
   *branch_count_out = 0;
   return 0;
}

//! @brief Parse undefs into the normalized representation used by linker object/archive loader.
static int parse_undefs(reader_t *r, char ***out, size_t *count_out)
{
   size_t i;
   uint16_t count = rd_u16(r);
   char **items = (char **)xcalloc(count, sizeof(*items));
   for (i = 0; i < count; ++i)
      items[i] = rd_cstr(r);
   *out = items;
   *count_out = count;
   return 1;
}

//! @brief Release exports array storage owned by linker object/archive loader.
static void free_exports_array(symbol_t *items, size_t count)
{
   size_t i;
   for (i = 0; i < count; ++i)
      free(items[i].name);
   free(items);
}

//! @brief Release layout array storage owned by linker object/archive loader.
static void free_layout_array(object_layout_t *items, size_t count)
{
   size_t i;
   for (i = 0; i < count; ++i)
      free(items[i].name);
   free(items);
}

//! @brief Handle try parse tail logic for linker object/archive loader.
static int try_parse_tail(const uint8_t *tail, size_t tail_size,
   reloc_t **text_relocs, size_t *text_reloc_count,
   reloc_t **data_relocs, size_t *data_reloc_count,
   symbol_t **exports, size_t *export_count,
   object_layout_t **layouts, size_t *layout_count,
   branch_t **branches, size_t *branch_count,
   char ***undefs, size_t *undef_count,
   const char *label)
{
   reader_t r;
   size_t save;

   reader_init(&r, tail, tail_size, label);
   parse_undefs(&r, undefs, undef_count);
   save = r.pos;

   if (parse_reloc_table_old(&r, text_relocs, text_reloc_count) &&
         parse_reloc_table_old(&r, data_relocs, data_reloc_count) &&
         parse_exports(&r, exports, export_count)) {
      if (r.pos == r.size)
         return 1;
      if (parse_layouts_any(&r, layouts, layout_count, branches, branch_count) && r.pos == r.size)
         return 1;
   }

   free(*text_relocs); *text_relocs = NULL; *text_reloc_count = 0;
   free(*data_relocs); *data_relocs = NULL; *data_reloc_count = 0;
   free_exports_array(*exports, *export_count); *exports = NULL; *export_count = 0;
   free_layout_array(*layouts, *layout_count); *layouts = NULL; *layout_count = 0;
   free(*branches); *branches = NULL; *branch_count = 0;

   r.pos = save;
   if (parse_reloc_table_old(&r, data_relocs, data_reloc_count) &&
         parse_reloc_table_old(&r, text_relocs, text_reloc_count) &&
         parse_exports(&r, exports, export_count)) {
      if (r.pos == r.size)
         return 1;
      if (parse_layouts_any(&r, layouts, layout_count, branches, branch_count) && r.pos == r.size)
         return 1;
   }

   free(*text_relocs); *text_relocs = NULL; *text_reloc_count = 0;
   free(*data_relocs); *data_relocs = NULL; *data_reloc_count = 0;
   free_exports_array(*exports, *export_count); *exports = NULL; *export_count = 0;
   free_layout_array(*layouts, *layout_count); *layouts = NULL; *layout_count = 0;
   free(*branches); *branches = NULL; *branch_count = 0;
   return 0;
}

//! @brief Compute default layouts and update linker object/archive loader state once prerequisite pass data is available.
static void synthesize_default_layouts(object_file_t *obj)
{
   size_t count = 0;
   object_layout_t *items;

   if (obj->layout_count > 0)
      return;

   if (obj->text.length > 0)
      count++;
   if (obj->data.length > 0)
      count++;
   if (obj->blen > 0)
      count++;
   if (obj->zlen > 0)
      count++;

   items = (object_layout_t *)xcalloc(count ? count : 1, sizeof(*items));
   count = 0;
   if (obj->text.length > 0) {
      items[count].name = xstrdup("CODE");
      items[count].segid = O26_SEG_TEXT;
      items[count].image_segid = O26_SEG_TEXT;
      items[count].packed_base = 0;
      items[count].image_base = 0;
      items[count].size = (uint16_t)obj->text.length;
      count++;
   }
   if (obj->data.length > 0) {
      items[count].name = xstrdup("DATA");
      items[count].segid = O26_SEG_DATA;
      items[count].image_segid = O26_SEG_DATA;
      items[count].packed_base = 0;
      items[count].image_base = 0;
      items[count].size = (uint16_t)obj->data.length;
      count++;
   }
   if (obj->blen > 0) {
      items[count].name = xstrdup("BSS");
      items[count].segid = O26_SEG_BSS;
      items[count].image_segid = O26_SEG_BSS;
      items[count].packed_base = 0;
      items[count].image_base = 0;
      items[count].size = obj->blen;
      count++;
   }
   if (obj->zlen > 0) {
      items[count].name = xstrdup("ZEROPAGE");
      items[count].segid = O26_SEG_ZP;
      items[count].image_segid = O26_SEG_ZP;
      items[count].packed_base = 0;
      items[count].image_base = 0;
      items[count].size = obj->zlen;
      count++;
   }

   obj->layouts = items;
   obj->layout_count = count;
}

//! @brief Extract parse o26 object from memory for linker object/archive loader.
static void parse_o26_object_from_memory(object_file_t *obj, const uint8_t *data, size_t size, const char *label)
{
   reader_t r;
   uint8_t header[5];
   uint8_t optlen;
   size_t header_end;
   symbol_t *exports = NULL;
   size_t export_count = 0;
   char **undefs = NULL;
   size_t undef_count = 0;
   reloc_t *text_relocs = NULL;
   size_t text_reloc_count = 0;
   reloc_t *data_relocs = NULL;
   size_t data_reloc_count = 0;
   object_layout_t *layouts = NULL;
   size_t layout_count = 0;
   branch_t *branches = NULL;
   size_t branch_count = 0;

   memset(obj, 0, sizeof(*obj));
   snprintf(obj->origin, sizeof(obj->origin), "%s", label);

   reader_init(&r, data, size, label);
   rd_bytes(&r, header, sizeof(header));
   if (!(header[0] == 1 && header[1] == 0 && header[2] == 'o' && header[3] == '2' && header[4] == '6')) {
      fprintf(stderr, "vcsc-ld: '%s' is not an o26 file\n", label);
      exit(1);
   }

   {
      uint8_t version = rd_u8(&r);
      if (version < 1 || version > 2) {
         fprintf(stderr, "vcsc-ld: unsupported o26 version %u in '%s'\n",
                 (unsigned)version, label);
         exit(1);
      }
   }
   obj->mode = rd_u16(&r);
   obj->tbase = rd_u16(&r);
   obj->text.length = rd_u16(&r);
   obj->dbase = rd_u16(&r);
   obj->data.length = rd_u16(&r);
   obj->bbase = rd_u16(&r);
   obj->blen = rd_u16(&r);
   obj->zbase = rd_u16(&r);
   obj->zlen = rd_u16(&r);
   obj->stack = rd_u16(&r);

   for (;;) {
      optlen = rd_u8(&r);
      if (optlen == 0)
         break;
      if (optlen < 1 || r.pos + (size_t)optlen - 1 > r.size)
         reader_fail(&r, "bad o26 options block");
      r.pos += (size_t)optlen - 1;
   }

   header_end = r.pos;

   obj->text.data = (uint8_t *)xmalloc(obj->text.length);
   obj->data.data = (uint8_t *)xmalloc(obj->data.length);
   rd_bytes(&r, obj->text.data, obj->text.length);
   rd_bytes(&r, obj->data.data, obj->data.length);

   if (!try_parse_tail(data + r.pos, size - r.pos,
         &text_relocs, &text_reloc_count,
         &data_relocs, &data_reloc_count,
         &exports, &export_count,
         &layouts, &layout_count,
         &branches, &branch_count,
         &undefs, &undef_count,
         label)) {
      fprintf(stderr, "vcsc-ld: failed to parse o26 relocation/export tail in '%s' (header ended at 0x%zx)\n", label, header_end);
      exit(1);
   }

   obj->text.relocs = text_relocs;
   obj->text.reloc_count = text_reloc_count;
   obj->data.relocs = data_relocs;
   obj->data.reloc_count = data_reloc_count;
   obj->undefs = undefs;
   obj->undef_count = undef_count;
   obj->exports = exports;
   obj->export_count = export_count;
   obj->layouts = layouts;
   obj->layout_count = layout_count;
   obj->branches = branches;
   obj->branch_count = branch_count;
   synthesize_default_layouts(obj);
}

//! @brief Load archive for linker object/archive loader and initialize the caller-visible state.
void load_archive(const char *path, archive_file_t *archive)
{
   reader_t r;
   size_t size;
   uint8_t *buf = read_entire_file(path, &size);
   uint8_t magic[VCSC_AR_MAGIC_SIZE];

   memset(archive, 0, sizeof(*archive));
   snprintf(archive->path, sizeof(archive->path), "%s", path);

   reader_init(&r, buf, size, path);
   rd_bytes(&r, magic, sizeof(magic));
   if (memcmp(magic, VCSC_AR_MAGIC, VCSC_AR_MAGIC_SIZE) != 0) {
      fprintf(stderr, "vcsc-ld: '%s' is not an l26 archive created by vcsc-ar\n", path);
      free(buf);
      exit(1);
   }

   while (r.pos < r.size) {
      uint16_t name_len;
      uint32_t member_size;
      archive_member_t *m;
      char member_label[MAX_PATH + MAX_NAME + 8];

      name_len = rd_u16(&r);
      member_size = (uint32_t)rd_u16(&r) | ((uint32_t)rd_u16(&r) << 16);
      archive->members = (archive_member_t *)xrealloc(archive->members,
         (archive->member_count + 1) * sizeof(*archive->members));
      m = &archive->members[archive->member_count++];
      memset(m, 0, sizeof(*m));
      if (name_len >= sizeof(m->member_name)) {
         fprintf(stderr, "vcsc-ld: member name too long in '%s'\n", path);
         exit(1);
      }
      rd_bytes(&r, (uint8_t *)m->member_name, name_len);
      m->member_name[name_len] = '\0';
      if (r.pos + member_size > r.size)
         reader_fail(&r, "truncated archive member payload");
      m->data = (uint8_t *)xmalloc(member_size);
      memcpy(m->data, r.data + r.pos, member_size);
      m->size = member_size;
      r.pos += member_size;
      snprintf(member_label, sizeof(member_label), "%s(%s)", path, m->member_name);
      parse_o26_object_from_memory(&m->obj, m->data, m->size, member_label);
      m->obj.selected_from_archive = 1;
   }

   {
      size_t i;
      for (i = 0; i < archive->member_count; ++i)
         archive->members[i].obj.archive_member = &archive->members[i];
   }

   free(buf);
}

//! @brief Load object for linker object/archive loader and initialize the caller-visible state.
void load_object(const char *path, object_file_t *obj)
{
   size_t size;
   uint8_t *buf = read_entire_file(path, &size);
   parse_o26_object_from_memory(obj, buf, size, path);
   free(buf);
}

//! @brief Handle object exports symbol logic for linker object/archive loader.
static int object_exports_symbol(const object_file_t *obj, const char *name)
{
   size_t i;
   for (i = 0; i < obj->export_count; ++i) {
      if (strcmp(obj->exports[i].name, name) == 0)
         return 1;
   }
   return 0;
}

//! @brief Handle object exports symbol or weak logic for linker object/archive loader.
static int object_exports_symbol_or_weak(const object_file_t *obj, const char *name)
{
   char *weak = make_weak_name(name);
   int found = object_exports_symbol(obj, name) || object_exports_symbol(obj, weak);
   free(weak);
   return found;
}

//! @brief Handle symbol in list logic for linker object/archive loader.
static int symbol_in_list(char **items, size_t count, const char *name)
{
   size_t i;
   for (i = 0; i < count; ++i) {
      if (strcmp(items[i], name) == 0)
         return 1;
   }
   return 0;
}

//! @brief Add unique string to linker object/archive loader state, growing storage or preserving uniqueness as needed.
static void add_unique_string(char ***items, size_t *count, const char *name)
{
   if (!symbol_in_list(*items, *count, name)) {
      *items = (char **)xrealloc(*items, (*count + 1) * sizeof(**items));
      (*items)[(*count)++] = xstrdup(name);
   }
}

//! @brief Handle selected objects export symbol logic for linker object/archive loader.
static int selected_objects_export_symbol(const input_set_t *in, const char *name)
{
   size_t i;
   for (i = 0; i < in->object_count; ++i) {
      if (object_exports_symbol_or_weak(&in->objects[i], name))
         return 1;
   }
   return 0;
}

//! @brief Collect needed symbols from existing linker object/archive loader state for a later pass.
static void collect_needed_symbols(const input_set_t *in, char ***out, size_t *count_out)
{
   char **needed = NULL;
   size_t needed_count = 0;
   size_t i, j;

   add_unique_string(&needed, &needed_count, "__reset");
   add_unique_string(&needed, &needed_count, "__nmi");
   add_unique_string(&needed, &needed_count, "__irqbrk");

   for (i = 0; i < in->object_count; ++i) {
      for (j = 0; j < in->objects[i].undef_count; ++j)
         add_unique_string(&needed, &needed_count, in->objects[i].undefs[j]);
   }

   *out = needed;
   *count_out = needed_count;
}

//! @brief Find provider in archive in linker object/archive loader tables without transferring ownership.
static object_file_t *find_provider_in_archive(archive_file_t *arc, const char *symbol_name)
{
   size_t m;
   for (m = 0; m < arc->member_count; ++m) {
      archive_member_t *mem = &arc->members[m];
      if (mem->selected)
         continue;
      if (object_exports_symbol(&mem->obj, symbol_name))
         return &mem->obj;
   }
   return NULL;
}

//! @brief Find provider in object in linker object/archive loader tables without transferring ownership.
static object_file_t *find_provider_in_object(object_file_t *obj, const char *symbol_name)
{
   if (obj->selected)
      return NULL;
   return object_exports_symbol(obj, symbol_name) ? obj : NULL;
}

//! @brief Find best provider in linker object/archive loader tables without transferring ownership.
static object_file_t *find_best_provider(input_set_t *in, const char *name)
{
   size_t i;
   char *weak = make_weak_name(name);
   object_file_t *provider = NULL;

   for (i = 0; i < in->order_count; ++i) {
      input_ref_t *ref = &in->order[i];
      if (ref->kind == INPUT_REF_OBJECT)
         provider = find_provider_in_object(&in->cmd_objects[ref->index], name);
      else
         provider = find_provider_in_archive(&in->archives[ref->index], name);
      if (provider) {
         free(weak);
         return provider;
      }
   }

   for (i = 0; i < in->order_count; ++i) {
      input_ref_t *ref = &in->order[i];
      if (ref->kind == INPUT_REF_OBJECT)
         provider = find_provider_in_object(&in->cmd_objects[ref->index], weak);
      else
         provider = find_provider_in_archive(&in->archives[ref->index], weak);
      if (provider) {
         free(weak);
         return provider;
      }
   }

   free(weak);
   return NULL;
}

//! @brief Handle include object logic for linker object/archive loader.
static void include_object(input_set_t *in, object_file_t *obj)
{
   if (obj->selected)
      return;
   obj->selected = 1;
   if (obj->archive_member)
      obj->archive_member->selected = 1;
   in->objects = (object_file_t *)xrealloc(in->objects,
      (in->object_count + 1) * sizeof(*in->objects));
   in->objects[in->object_count++] = *obj;
}

//! @brief Return whether a command-line object carries authoritative configuration metadata.
static int object_has_configuration_metadata(const object_file_t *obj)
{
   size_t i;
   if (!obj)
      return 0;
   for (i = 0; i < obj->export_count; ++i) {
      const char *name = obj->exports[i].name;
      if (strncmp(name, MEM_DECL_META_PREFIX, sizeof(MEM_DECL_META_PREFIX) - 1) == 0 ||
          strncmp(name, CARTRIDGE_TOPOLOGY_META_PREFIX,
                  sizeof(CARTRIDGE_TOPOLOGY_META_PREFIX) - 1) == 0 ||
          strncmp(name, CARTRIDGE_TOPOLOGY_META_PREFIX_V1,
                  sizeof(CARTRIDGE_TOPOLOGY_META_PREFIX_V1) - 1) == 0 ||
          strncmp(name, BANK_TOPOLOGY_META_PREFIX,
                  sizeof(BANK_TOPOLOGY_META_PREFIX) - 1) == 0)
         return 1;
   }
   return 0;
}

//! @brief Return whether an otherwise empty command-line object exists only to configure linking.
static int object_is_configuration_only(const object_file_t *obj)
{
   return object_has_configuration_metadata(obj) &&
          obj->text.length == 0 && obj->data.length == 0 &&
          obj->blen == 0 && obj->zlen == 0;
}

//! @brief Compute needed objects and update linker object/archive loader state once prerequisite pass data is available.
void select_needed_objects(input_set_t *in)
{
   size_t command_index;
   for (command_index = 0; command_index < in->cmd_object_count; ++command_index) {
      object_file_t *obj = &in->cmd_objects[command_index];
      if (object_is_configuration_only(obj))
         include_object(in, obj);
   }
   int progress;
   do {
      char **needed = NULL;
      size_t needed_count = 0;
      size_t i;

      collect_needed_symbols(in, &needed, &needed_count);
      progress = 0;

      for (i = 0; i < needed_count; ++i) {
         object_file_t *provider;
         if (selected_objects_export_symbol(in, needed[i]))
            continue;
         provider = find_best_provider(in, needed[i]);
         if (provider) {
            include_object(in, provider);
            progress = 1;
         }
      }

      for (i = 0; i < needed_count; ++i)
         free(needed[i]);
      free(needed);
   } while (progress);
}

//! @brief Report unused cmdline objects diagnostics with the location/context expected by linker object/archive loader callers.
void warn_unused_cmdline_objects(const input_set_t *in)
{
   size_t i;
   for (i = 0; i < in->cmd_object_count; ++i) {
      if (!in->cmd_objects[i].selected)
         fprintf(stderr, "vcsc-ld: warning: unused object '%s' not linked\n", in->cmd_objects[i].origin);
   }

   for (i = 0; i < in->archive_count; ++i) {
      const archive_file_t *arc = &in->archives[i];
      size_t m;
      int any_selected = 0;
      for (m = 0; m < arc->member_count; ++m) {
         if (arc->members[m].selected || arc->members[m].obj.selected) {
            any_selected = 1;
            break;
         }
      }
      if (!any_selected)
         fprintf(stderr, "vcsc-ld: warning: unused archive '%s' not linked\n", arc->path);
   }
}

//! @brief Release object storage owned by linker object/archive loader.
void free_object(object_file_t *obj)
{
   size_t i;
   free(obj->text.data);
   free(obj->data.data);
   free(obj->text.relocs);
   free(obj->data.relocs);
   for (i = 0; i < obj->undef_count; ++i)
      free(obj->undefs[i]);
   free(obj->undefs);
   for (i = 0; i < obj->export_count; ++i)
      free(obj->exports[i].name);
   free(obj->exports);
   for (i = 0; i < obj->layout_count; ++i)
      free(obj->layouts[i].name);
   free(obj->layouts);
   free(obj->branches);
}
