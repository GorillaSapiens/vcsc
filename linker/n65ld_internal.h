//! @file linker/n65ld_internal.h
//! @brief Declares linker internal interfaces for the n65 linker.
//! @ingroup linker

#ifndef N65LD_INTERNAL_H
#define N65LD_INTERNAL_H

#include <stddef.h>
#include <stdint.h>

//! Compile-time element count for fixed arrays.
#define ARRAY_LEN(a) (sizeof(a) / sizeof((a)[0]))
//! Archive magic shared with n65ar.
#define NAR_MAGIC "NAR65\0\1"
#define NAR_MAGIC_SIZE 7

#define O65_SEG_UNDEF 0
#define O65_SEG_ABS   1
#define O65_SEG_TEXT  2
#define O65_SEG_DATA  3
#define O65_SEG_BSS   4
#define O65_SEG_ZP    5

#define O65_RTYPE_LOW  0x20
#define O65_RTYPE_HIGH 0x40
#define O65_RTYPE_WORD 0x80
#define O65_RTYPE_AUX  0x10

#define SYMBOL_BACKED_META_PREFIX "__sbpmeta$"
#define ABI_META_PREFIX "__abimeta$V1$"
#define MEM_REGION_META_PREFIX "__memmeta$V1$"

#define MAX_NAME 128
#define MAX_PATH 512

//! Memory region parsed from a linker configuration file.
typedef struct {
   uint16_t start;
   uint16_t size;
   char type[8];
   int define_yes;
   char name[MAX_NAME];
} memory_region_t;

//! Segment placement rule parsed from a linker configuration file.
typedef struct {
   char name[MAX_NAME];
   char load_name[MAX_NAME];
   char run_name[MAX_NAME];
   char type[16];
   int define_yes;
} segment_rule_t;

//! Complete in-memory linker configuration.
typedef struct {
   memory_region_t mem[16];
   size_t mem_count;
   segment_rule_t seg[16];
   size_t seg_count;
} linker_config_t;

//! Exported or imported o65 symbol record.
typedef struct {
   char *name;
   uint8_t segid;
   uint16_t value;
} symbol_t;

typedef struct {
   char *name;
   uint8_t segid;
   uint8_t image_segid;
   uint16_t packed_base;
   uint16_t image_base;
   uint16_t size;
   uint16_t load_addr;
   uint16_t run_addr;
} object_layout_t;

typedef struct {
   uint32_t offset;
   uint8_t type;
   uint8_t segid;
   uint16_t undef_index;
   uint8_t aux_low;
   int has_aux_low;
} reloc_t;

//! One loadable o65 segment plus relocations against it.
typedef struct {
   uint8_t *data;
   size_t length;
   uint16_t base;
   reloc_t *relocs;
   size_t reloc_count;
} o65_segment_t;

typedef struct archive_member_s archive_member_t;

//! Decoded o65 object plus placement state selected by the linker.
typedef struct {
   char origin[MAX_PATH];
   uint16_t mode;
   uint16_t tbase, dbase, bbase, zbase, stack;
   uint16_t blen, zlen;
   o65_segment_t text;
   o65_segment_t data;
   char **undefs;
   size_t undef_count;
   symbol_t *exports;
   size_t export_count;
   object_layout_t *layouts;
   size_t layout_count;
   uint16_t place_text_load;
   uint16_t place_data_load;
   uint16_t place_data_run;
   uint16_t place_bss_run;
   uint16_t place_zp_run;
   int selected_from_archive;
   int selected;
   int from_cmdline;
   archive_member_t *archive_member;
} object_file_t;

struct archive_member_s {
   char member_name[MAX_NAME];
   uint8_t *data;
   size_t size;
   int selected;
   object_file_t obj;
};

typedef struct {
   char path[MAX_PATH];
   archive_member_t *members;
   size_t member_count;
} archive_file_t;

//! Keeps original command-line ordering across object files and archives.
typedef enum {
   INPUT_REF_OBJECT = 1,
   INPUT_REF_ARCHIVE = 2
} input_ref_kind_t;

typedef struct {
   input_ref_kind_t kind;
   size_t index;
} input_ref_t;

//! All linker inputs after loading archives and command-line objects.
typedef struct {
   object_file_t *objects;
   size_t object_count;
   object_file_t *cmd_objects;
   size_t cmd_object_count;
   archive_file_t *archives;
   size_t archive_count;
   input_ref_t *order;
   size_t order_count;
} input_set_t;

typedef struct {
   char *name;
   uint16_t addr;
   uint8_t segid;
   const char *source;
} global_symbol_t;

typedef struct {
   char *name;
   int has_symbol_backed_params;
} call_graph_node_t;

typedef struct {
   int from;
   int to;
} call_graph_edge_t;

typedef struct {
   char name[MAX_NAME];
   uint16_t cur;
   uint32_t end;
} memory_cursor_t;

typedef struct {
   char *name;
   uint16_t load_addr;
   uint16_t run_addr;
   uint16_t size;
} copy_record_t;

typedef struct {
   char *name;
   uint16_t run_addr;
   uint16_t size;
} zero_record_t;

//! Final placement, copy/zero tables, stack range, and global symbols.
typedef struct {
   uint16_t code_load_cur;
   uint16_t data_load_cur;
   uint16_t data_run_cur;
   uint16_t bss_run_cur;
   uint16_t zp_run_cur;
   uint16_t code_load_end;
   uint16_t data_load_end;
   uint16_t data_run_end;
   uint16_t bss_run_end;
   uint16_t zp_run_end;
   uint16_t data_load_start;
   uint16_t data_load_size;
   uint16_t data_run_start;
   uint16_t data_run_size;
   uint16_t bss_start;
   uint16_t bss_size;
   uint16_t init_table_addr;
   uint16_t init_table_size;
   uint16_t copy_table_addr;
   uint16_t copy_table_size;
   uint16_t zero_table_addr;
   uint16_t zero_table_size;
   uint16_t stack_start;
   uint16_t stack_top;
   memory_cursor_t *cursors;
   size_t cursor_count;
   copy_record_t *copy_records;
   size_t copy_record_count;
   zero_record_t *zero_records;
   size_t zero_record_count;
   global_symbol_t *globals;
   size_t global_count;
} layout_t;

typedef struct {
   uint32_t value;
   size_t pos;
   int ok;
} parse_result_t;

typedef struct {
   const uint8_t *data;
   size_t size;
   size_t pos;
   const char *label;
} reader_t;

void *xmalloc(size_t size);
char *xstrdup(const char *s);
char *make_weak_name(const char *name);
void *xcalloc(size_t count, size_t size);
void *xrealloc(void *ptr, size_t size);

#endif
