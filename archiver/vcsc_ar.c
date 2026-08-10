//! @file archiver/vcsc_ar.c
//! @brief Implements archive file command-line driver for the VCSC archive tool.
//! @ingroup archiver

#include <errno.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "version.h"

#define VCSC_AR_MAGIC "VCSL26\1"
#define VCSC_AR_MAGIC_SIZE 7
#define COPY_BUFFER_SIZE 65536

typedef struct
{
   char op;
   bool suppress_create_message;
   bool verbose;
} ar_options_t;

//! @brief Print the archiver command-line usage text.
static void usage(FILE *fp)
{
   fprintf(fp,
      "Usage:\n"
      "  vcsc-ar rcs archive.l26 file1.o26 file2.o26 ...\n"
      "  vcsc-ar t archive.l26 [member ...]\n"
      "  vcsc-ar x archive.l26 [member ...]\n"
      "\n"
      "Supported GNU ar-style operations/modifiers:\n"
      "  r  replace or add members\n"
      "  q  append members\n"
      "  t  list members\n"
      "  x  extract members\n"
      "  c  suppress the 'creating archive' message\n"
      "  s  accepted for compatibility; no index is written\n"
      "  v  verbose output\n"
      "  V  print version information\n"
      "  -h, --help  print this help text\n"
      "\n"
      "Legacy compatibility is also accepted:\n"
      "  vcsc-ar -c archive.l26 file1.o26 ...\n"
      "  vcsc-ar -l archive.l26\n"
      "  vcsc-ar -x archive.l26\n"
      "  vcsc-ar -V\n");
}

//! @brief Return the archive member basename; the pointer aliases the input path.
static const char *base_name(const char *path)
{
   const char *slash;
   const char *backslash;
   const char *base;

   slash = strrchr(path, '/');
   backslash = strrchr(path, '\\');
   base = path;

   if (slash && slash + 1 > base)
      base = slash + 1;

   if (backslash && backslash + 1 > base)
      base = backslash + 1;

   return base;
}

//! @brief Return whether a string ends with the requested suffix.
static bool ends_with(const char *s, const char *suffix)
{
   size_t slen;
   size_t tlen;

   slen = strlen(s);
   tlen = strlen(suffix);

   if (slen < tlen)
      return false;

   return strcmp(s + slen - tlen, suffix) == 0;
}

//! @brief Write a 16-bit little-endian integer field to a stream.
static int write_u16_le(FILE *fp, uint16_t value)
{
   unsigned char b[2];

   b[0] = (unsigned char)(value & 0xFFu);
   b[1] = (unsigned char)((value >> 8) & 0xFFu);

   return fwrite(b, 1, sizeof(b), fp) == sizeof(b) ? 1 : 0;
}

//! @brief Write a 32-bit little-endian integer field to a stream.
static int write_u32_le(FILE *fp, uint32_t value)
{
   unsigned char b[4];

   b[0] = (unsigned char)(value & 0xFFu);
   b[1] = (unsigned char)((value >> 8) & 0xFFu);
   b[2] = (unsigned char)((value >> 16) & 0xFFu);
   b[3] = (unsigned char)((value >> 24) & 0xFFu);

   return fwrite(b, 1, sizeof(b), fp) == sizeof(b) ? 1 : 0;
}

//! @brief Read a 16-bit little-endian integer field from a stream.
static int read_u16_le(FILE *fp, uint16_t *value)
{
   unsigned char b[2];

   if (fread(b, 1, sizeof(b), fp) != sizeof(b))
      return 0;

   *value = (uint16_t)b[0] | ((uint16_t)b[1] << 8);
   return 1;
}

//! @brief Read a 32-bit little-endian integer field from a stream.
static int read_u32_le(FILE *fp, uint32_t *value)
{
   unsigned char b[4];

   if (fread(b, 1, sizeof(b), fp) != sizeof(b))
      return 0;

   *value = (uint32_t)b[0]
      | ((uint32_t)b[1] << 8)
      | ((uint32_t)b[2] << 16)
      | ((uint32_t)b[3] << 24);
   return 1;
}

//! @brief Copy an exact byte count between streams and fail on short read or write error.
static int copy_n_bytes(FILE *in, FILE *out, uint32_t size)
{
   unsigned char buffer[COPY_BUFFER_SIZE];
   uint32_t remaining;

   remaining = size;
   while (remaining > 0) {
      size_t chunk;
      size_t got;

      chunk = remaining > COPY_BUFFER_SIZE ? COPY_BUFFER_SIZE : (size_t)remaining;
      got = fread(buffer, 1, chunk, in);
      if (got != chunk) {
         fprintf(stderr, "vcsc-ar: unexpected end of file while copying payload\n");
         return 0;
      }

      if (fwrite(buffer, 1, got, out) != got) {
         fprintf(stderr, "vcsc-ar: write failed: %s\n", strerror(errno));
         return 0;
      }

      remaining -= (uint32_t)got;
   }

   return 1;
}

//! @brief Consume an exact byte count from a stream and fail on short input.
static int skip_n_bytes(FILE *fp, uint32_t size)
{
   unsigned char buffer[COPY_BUFFER_SIZE];
   uint32_t remaining;

   remaining = size;
   while (remaining > 0) {
      size_t chunk;
      size_t got;

      chunk = remaining > COPY_BUFFER_SIZE ? COPY_BUFFER_SIZE : (size_t)remaining;
      got = fread(buffer, 1, chunk, fp);
      if (got != chunk) {
         fprintf(stderr, "vcsc-ar: unexpected end of file while skipping payload\n");
         return 0;
      }

      remaining -= (uint32_t)got;
   }

   return 1;
}

//! @brief Return a stream length while restoring the original seek position.
static long file_size(FILE *fp)
{
   long cur;
   long end;

   cur = ftell(fp);
   if (cur < 0)
      return -1;

   if (fseek(fp, 0, SEEK_END) != 0)
      return -1;

   end = ftell(fp);
   if (end < 0)
      return -1;

   if (fseek(fp, cur, SEEK_SET) != 0)
      return -1;

   return end;
}

//! @brief Load archive for read for archive reader/writer and initialize the caller-visible state.
static int open_archive_for_read(const char *archive_name, FILE **out_fp)
{
   FILE *archive;
   unsigned char magic[VCSC_AR_MAGIC_SIZE];

   archive = fopen(archive_name, "rb");
   if (!archive) {
      fprintf(stderr, "vcsc-ar: cannot open '%s': %s\n", archive_name, strerror(errno));
      return 0;
   }

   if (fread(magic, 1, VCSC_AR_MAGIC_SIZE, archive) != VCSC_AR_MAGIC_SIZE) {
      fprintf(stderr, "vcsc-ar: '%s' is too short to be a vcsc-ar archive\n", archive_name);
      fclose(archive);
      return 0;
   }

   if (memcmp(magic, VCSC_AR_MAGIC, VCSC_AR_MAGIC_SIZE) != 0) {
      fprintf(stderr, "vcsc-ar: '%s' is not a vcsc-ar archive\n", archive_name);
      fclose(archive);
      return 0;
   }

   *out_fp = archive;
   return 1;
}

//! @brief Return whether member name is valid in archive reader/writer.
static bool member_name_is_valid(const char *name)
{
   return strchr(name, '/') == NULL && strchr(name, '\\') == NULL && name[0] != '\0';
}

//! @brief Extract append member from file for archive reader/writer.
static int append_member_from_file(FILE *archive, const char *input_name)
{
   const char *stored_name;
   FILE *input;
   long size;
   size_t name_len;

   stored_name = base_name(input_name);
   name_len = strlen(stored_name);

   if (!ends_with(stored_name, ".o26"))
      fprintf(stderr, "vcsc-ar: warning: '%s' does not end with .o26\n", input_name);

   if (name_len == 0 || name_len > UINT16_MAX || !member_name_is_valid(stored_name)) {
      fprintf(stderr, "vcsc-ar: invalid member name '%s'\n", input_name);
      return 0;
   }

   input = fopen(input_name, "rb");
   if (!input) {
      fprintf(stderr, "vcsc-ar: cannot open '%s': %s\n", input_name, strerror(errno));
      return 0;
   }

   size = file_size(input);
   if (size < 0) {
      fprintf(stderr, "vcsc-ar: cannot determine size of '%s'\n", input_name);
      fclose(input);
      return 0;
   }

   if ((uint64_t)size > UINT32_MAX) {
      fprintf(stderr, "vcsc-ar: '%s' is too large for this archive format\n", input_name);
      fclose(input);
      return 0;
   }

   if (!write_u16_le(archive, (uint16_t)name_len)
         || !write_u32_le(archive, (uint32_t)size)
         || fwrite(stored_name, 1, name_len, archive) != name_len) {
      fprintf(stderr, "vcsc-ar: failed writing member header for '%s': %s\n", input_name, strerror(errno));
      fclose(input);
      return 0;
   }

   if (fseek(input, 0, SEEK_SET) != 0) {
      fprintf(stderr, "vcsc-ar: seek failed on '%s'\n", input_name);
      fclose(input);
      return 0;
   }

   if (!copy_n_bytes(input, archive, (uint32_t)size)) {
      fclose(input);
      return 0;
   }

   fclose(input);
   return 1;
}

//! @brief Write archive header using the on-disk format expected by archive reader/writer.
static int write_archive_header(FILE *archive, const char *archive_name)
{
   if (fwrite(VCSC_AR_MAGIC, 1, VCSC_AR_MAGIC_SIZE, archive) != VCSC_AR_MAGIC_SIZE) {
      fprintf(stderr, "vcsc-ar: failed to write archive header for '%s': %s\n", archive_name, strerror(errno));
      return 0;
   }

   return 1;
}

//! @brief Handle peek archive eof logic for archive reader/writer.
static int peek_archive_eof(FILE *archive, const char *archive_name, int *at_eof_out)
{
   int ch;

   ch = fgetc(archive);
   if (ch == EOF) {
      if (feof(archive)) {
         clearerr(archive);
         *at_eof_out = 1;
         return 1;
      }

      fprintf(stderr, "vcsc-ar: read error on '%s'\n", archive_name);
      return 0;
   }

   if (ungetc(ch, archive) == EOF) {
      fprintf(stderr, "vcsc-ar: internal read error on '%s'\n", archive_name);
      return 0;
   }

   *at_eof_out = 0;
   return 1;
}

//! @brief Read member header from the current input position and advance the reader on success.
static int read_member_header(FILE *archive,
                              const char *archive_name,
                              uint16_t *name_len_out,
                              uint32_t *size_out,
                              char **name_out,
                              int *at_eof_out)
{
   uint16_t name_len;
   uint32_t size;
   char *name;

   *name_out = NULL;

   if (!peek_archive_eof(archive, archive_name, at_eof_out))
      return 0;

   if (*at_eof_out)
      return 1;

   if (!read_u16_le(archive, &name_len) || !read_u32_le(archive, &size)) {
      fprintf(stderr, "vcsc-ar: truncated member header in '%s'\n", archive_name);
      return 0;
   }

   if (name_len == 0) {
      fprintf(stderr, "vcsc-ar: invalid zero-length member name in '%s'\n", archive_name);
      return 0;
   }

   name = (char *)malloc((size_t)name_len + 1u);
   if (!name) {
      fprintf(stderr, "vcsc-ar: out of memory\n");
      return 0;
   }

   if (fread(name, 1, name_len, archive) != name_len) {
      fprintf(stderr, "vcsc-ar: truncated member name in '%s'\n", archive_name);
      free(name);
      return 0;
   }

   name[name_len] = '\0';
   *name_len_out = name_len;
   *size_out = size;
   *name_out = name;
   return 1;
}

//! @brief Write member record using the on-disk format expected by archive reader/writer.
static int write_member_record(FILE *out, FILE *in, const char *member_name, uint32_t size)
{
   size_t name_len;

   name_len = strlen(member_name);
   if (!write_u16_le(out, (uint16_t)name_len)
         || !write_u32_le(out, size)
         || fwrite(member_name, 1, name_len, out) != name_len) {
      fprintf(stderr, "vcsc-ar: failed writing member header for '%s': %s\n", member_name, strerror(errno));
      return 0;
   }

   return copy_n_bytes(in, out, size);
}

//! @brief Return temp archive name data used by archive reader/writer; returned pointers alias existing storage unless explicitly allocated by the function name.
static char *temp_archive_name(const char *archive_name)
{
   size_t len;
   char *tmp_name;

   len = strlen(archive_name);
   tmp_name = (char *)malloc(len + 5u);
   if (!tmp_name)
      return NULL;

   memcpy(tmp_name, archive_name, len);
   memcpy(tmp_name + len, ".tmp", 5u);
   return tmp_name;
}

//! @brief Handle member name index logic for archive reader/writer.
static int member_name_index(const char *member_name, int count, char **names)
{
   int i;

   for (i = 0; i < count; ++i) {
      if (strcmp(member_name, base_name(names[i])) == 0)
         return i;
   }

   return -1;
}

//! @brief Add archive to archive reader/writer state, growing storage or preserving uniqueness as needed.
static int append_archive(const char *archive_name, int input_count, char **inputs, bool quiet_create, bool verbose)
{
   FILE *old_archive;
   FILE *new_archive;
   char *tmp_name;
   struct stat st;
   bool have_old_archive;
   int status;

   status = 1;
   old_archive = NULL;
   new_archive = NULL;
   tmp_name = NULL;
   have_old_archive = stat(archive_name, &st) == 0;

   if (!have_old_archive && !quiet_create)
      fprintf(stderr, "vcsc-ar: creating %s\n", archive_name);

   if (have_old_archive) {
      if (!open_archive_for_read(archive_name, &old_archive))
         return 1;
   }

   tmp_name = temp_archive_name(archive_name);
   if (!tmp_name) {
      fprintf(stderr, "vcsc-ar: out of memory\n");
      if (old_archive)
         fclose(old_archive);
      return 1;
   }

   new_archive = fopen(tmp_name, "wb");
   if (!new_archive) {
      fprintf(stderr, "vcsc-ar: cannot create '%s': %s\n", tmp_name, strerror(errno));
      if (old_archive)
         fclose(old_archive);
      free(tmp_name);
      return 1;
   }

   if (!write_archive_header(new_archive, archive_name))
      goto cleanup;

   if (old_archive) {
      if (fseek(old_archive, VCSC_AR_MAGIC_SIZE, SEEK_SET) != 0) {
         fprintf(stderr, "vcsc-ar: seek failed on '%s'\n", archive_name);
         goto cleanup;
      }

      while (1) {
         uint16_t name_len;
         uint32_t size;
         char *name;
         int at_eof;

         if (!read_member_header(old_archive, archive_name, &name_len, &size, &name, &at_eof))
            goto cleanup;

         if (at_eof)
            break;

         if (!write_member_record(new_archive, old_archive, name, size)) {
            free(name);
            goto cleanup;
         }

         if (verbose)
            printf("a - %s\n", name);

         free(name);
      }
   }

   for (int i = 0; i < input_count; ++i) {
      const char *member_name;

      member_name = base_name(inputs[i]);
      if (!append_member_from_file(new_archive, inputs[i]))
         goto cleanup;

      if (verbose)
         printf("a - %s\n", member_name);
   }

   status = 0;

cleanup:
   if (old_archive)
      fclose(old_archive);

   if (new_archive && fclose(new_archive) != 0) {
      fprintf(stderr, "vcsc-ar: close failed on '%s': %s\n", tmp_name ? tmp_name : archive_name, strerror(errno));
      status = 1;
   }

   if (status == 0) {
      if (rename(tmp_name, archive_name) != 0) {
         fprintf(stderr, "vcsc-ar: cannot replace '%s': %s\n", archive_name, strerror(errno));
         status = 1;
      }
   }

   if (status != 0 && tmp_name)
      remove(tmp_name);

   free(tmp_name);
   return status;
}

//! @brief Handle replace archive logic for archive reader/writer.
static int replace_archive(const char *archive_name, int input_count, char **inputs, bool quiet_create, bool verbose)
{
   FILE *old_archive;
   FILE *new_archive;
   char *tmp_name;
   struct stat st;
   bool have_old_archive;
   bool *replaced_flags;
   int status;
   int i;

   status = 1;
   old_archive = NULL;
   new_archive = NULL;
   tmp_name = NULL;
   replaced_flags = NULL;
   have_old_archive = stat(archive_name, &st) == 0;

   if (!have_old_archive && !quiet_create)
      fprintf(stderr, "vcsc-ar: creating %s\n", archive_name);

   if (have_old_archive) {
      if (!open_archive_for_read(archive_name, &old_archive))
         return 1;
   }

   replaced_flags = (bool *)calloc((size_t)input_count, sizeof(bool));
   if (!replaced_flags) {
      fprintf(stderr, "vcsc-ar: out of memory\n");
      if (old_archive)
         fclose(old_archive);
      return 1;
   }

   tmp_name = temp_archive_name(archive_name);
   if (!tmp_name) {
      fprintf(stderr, "vcsc-ar: out of memory\n");
      fclose(old_archive);
      free(replaced_flags);
      return 1;
   }

   new_archive = fopen(tmp_name, "wb");
   if (!new_archive) {
      fprintf(stderr, "vcsc-ar: cannot create '%s': %s\n", tmp_name, strerror(errno));
      if (old_archive)
         fclose(old_archive);
      free(replaced_flags);
      free(tmp_name);
      return 1;
   }

   if (!write_archive_header(new_archive, archive_name))
      goto cleanup;

   if (old_archive) {
      if (fseek(old_archive, VCSC_AR_MAGIC_SIZE, SEEK_SET) != 0) {
         fprintf(stderr, "vcsc-ar: seek failed on '%s'\n", archive_name);
         goto cleanup;
      }

      while (1) {
         uint16_t name_len;
         uint32_t size;
         char *name;
         int at_eof;
         int index;

         if (!read_member_header(old_archive, archive_name, &name_len, &size, &name, &at_eof))
            goto cleanup;

         if (at_eof)
            break;

         index = member_name_index(name, input_count, inputs);
         if (index >= 0) {
            replaced_flags[index] = true;
            if (!skip_n_bytes(old_archive, size)) {
               free(name);
               goto cleanup;
            }
            free(name);
            continue;
         }

         if (!write_member_record(new_archive, old_archive, name, size)) {
            free(name);
            goto cleanup;
         }

         free(name);
      }
   }

   for (i = 0; i < input_count; ++i) {
      const char *member_name;
      char action;

      member_name = base_name(inputs[i]);
      action = replaced_flags[i] ? 'r' : 'a';

      if (!append_member_from_file(new_archive, inputs[i]))
         goto cleanup;

      if (verbose)
         printf("%c - %s\n", action, member_name);
   }

   status = 0;

cleanup:
   if (old_archive)
      fclose(old_archive);

   if (new_archive && fclose(new_archive) != 0) {
      fprintf(stderr, "vcsc-ar: close failed on '%s': %s\n", tmp_name ? tmp_name : archive_name, strerror(errno));
      status = 1;
   }

   if (status == 0) {
      if (rename(tmp_name, archive_name) != 0) {
         fprintf(stderr, "vcsc-ar: cannot replace '%s': %s\n", archive_name, strerror(errno));
         status = 1;
      }
   }

   if (status != 0 && tmp_name)
      remove(tmp_name);

   free(replaced_flags);
   free(tmp_name);
   return status;
}

//! @brief Handle extract archive logic for archive reader/writer.
static int extract_archive(const char *archive_name, int requested_count, char **requested_names, bool verbose)
{
   FILE *archive;

   if (!open_archive_for_read(archive_name, &archive))
      return 1;

   while (1) {
      uint16_t name_len;
      uint32_t size;
      char *name;
      int at_eof;
      FILE *out;

      if (!read_member_header(archive, archive_name, &name_len, &size, &name, &at_eof)) {
         fclose(archive);
         return 1;
      }

      if (at_eof)
         break;

      if (requested_count > 0 && member_name_index(name, requested_count, requested_names) < 0) {
         free(name);
         if (!skip_n_bytes(archive, size)) {
            fclose(archive);
            return 1;
         }
         continue;
      }

      if (!member_name_is_valid(name)) {
         fprintf(stderr, "vcsc-ar: refusing suspicious member name '%s'\n", name);
         free(name);
         fclose(archive);
         return 1;
      }

      out = fopen(name, "wb");
      if (!out) {
         fprintf(stderr, "vcsc-ar: cannot create '%s': %s\n", name, strerror(errno));
         free(name);
         fclose(archive);
         return 1;
      }

      if (verbose)
         printf("x - %s\n", name);

      if (!copy_n_bytes(archive, out, size)) {
         fclose(out);
         free(name);
         fclose(archive);
         return 1;
      }

      fclose(out);
      free(name);
   }

   fclose(archive);
   return 0;
}

//! @brief Handle list archive logic for archive reader/writer.
static int list_archive(const char *archive_name, int requested_count, char **requested_names, bool verbose)
{
   FILE *archive;

   (void)verbose;

   if (!open_archive_for_read(archive_name, &archive))
      return 1;

   while (1) {
      uint16_t name_len;
      uint32_t size;
      char *name;
      int at_eof;

      if (!read_member_header(archive, archive_name, &name_len, &size, &name, &at_eof)) {
         fclose(archive);
         return 1;
      }

      if (at_eof)
         break;

      if (requested_count == 0 || member_name_index(name, requested_count, requested_names) >= 0)
         puts(name);

      free(name);
      if (!skip_n_bytes(archive, size)) {
         fclose(archive);
         return 1;
      }
   }

   fclose(archive);
   return 0;
}

//! @brief Parse legacy mode into the normalized representation used by archive reader/writer.
static int parse_legacy_mode(int argc, char **argv)
{
   if (strcmp(argv[1], "-c") == 0) {
      if (argc < 4) {
         usage(stderr);
         return 1;
      }
      return replace_archive(argv[2], argc - 3, &argv[3], true, false);
   }

   if (strcmp(argv[1], "-x") == 0) {
      if (argc < 3) {
         usage(stderr);
         return 1;
      }
      return extract_archive(argv[2], argc - 3, &argv[3], false);
   }

   if (strcmp(argv[1], "-l") == 0) {
      if (argc < 3) {
         usage(stderr);
         return 1;
      }
      return list_archive(argv[2], argc - 3, &argv[3], false);
   }

   return -1;
}

//! @brief Parse mode string into the normalized representation used by archive reader/writer.
static int parse_mode_string(const char *arg, ar_options_t *opts)
{
   const char *p;
   bool have_op;

   opts->op = '\0';
   opts->suppress_create_message = false;
   opts->verbose = false;
   have_op = false;

   p = arg;
   if (*p == '-')
      ++p;

   if (*p == '\0')
      return 0;

   while (*p) {
      switch (*p) {
      case 'r':
      case 'q':
      case 't':
      case 'x':
         if (have_op)
            return 0;
         opts->op = *p;
         have_op = true;
         break;

      case 'c':
         opts->suppress_create_message = true;
         break;

      case 's':
         break;

      case 'v':
         opts->verbose = true;
         break;

      default:
         return 0;
      }

      ++p;
   }

   return have_op ? 1 : 0;
}

//! @brief Entry point for the archiver command; parses arguments, runs the requested pipeline, and returns process status.
int main(int argc, char **argv)
{
   ar_options_t opts;
   int legacy_status;

   if (argc >= 2 && (!strcmp(argv[1], "-h") || !strcmp(argv[1], "--help"))) {
      usage(stdout);
      return 0;
   }

   if (argc == 2 && (!strcmp(argv[1], "-V") || !strcmp(argv[1], "V"))) {
      puts(VERSION);
      return 0;
   }

   if (argc == 2 && argv[1][0] == '-' && argv[1][1] != '\0') {
      fprintf(stderr, "%s: unsupported option '%s'\n", argv[0], argv[1]);
      fprintf(stderr, "Try '%s --help' for a list of supported options.\n", argv[0]);
      return 1;
   }

   if (argc < 3) {
      usage(stderr);
      return 1;
   }

   legacy_status = parse_legacy_mode(argc, argv);
   if (legacy_status >= 0)
      return legacy_status;

   if (!parse_mode_string(argv[1], &opts)) {
      if (argv[1][0] == '-')
         fprintf(stderr, "%s: unsupported option '%s'\n", argv[0], argv[1]);
      else
         fprintf(stderr, "%s: unsupported operation '%s'\n", argv[0], argv[1]);
      fprintf(stderr, "Try '%s --help' for a list of supported options.\n", argv[0]);
      return 1;
   }

   switch (opts.op) {
   case 'r':
   case 'q':
      if (argc < 4) {
         usage(stderr);
         return 1;
      }
      if (opts.op == 'r')
         return replace_archive(argv[2], argc - 3, &argv[3], opts.suppress_create_message, opts.verbose);
      return append_archive(argv[2], argc - 3, &argv[3], opts.suppress_create_message, opts.verbose);

   case 't':
      return list_archive(argv[2], argc - 3, &argv[3], opts.verbose);

   case 'x':
      return extract_archive(argv[2], argc - 3, &argv[3], opts.verbose);

   default:
      usage(stderr);
      return 1;
   }
}
