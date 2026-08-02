//! @file linker/vcsc_ld_internal.h
//! @brief Declares linker internal interfaces for the VCSC linker.
//! @ingroup linker

#ifndef VCSC_LD_INTERNAL_H
#define VCSC_LD_INTERNAL_H

#include <stddef.h>
#include <stdint.h>

//! Compile-time element count for fixed arrays.
#define ARRAY_LEN(a) (sizeof(a) / sizeof((a)[0]))
//! Archive magic shared with vcsc-ar.
#define VCSC_AR_MAGIC "VCSL26\1"
#define VCSC_AR_MAGIC_SIZE 7

#define O26_SEG_UNDEF 0
#define O26_SEG_ABS   1
#define O26_SEG_TEXT  2
#define O26_SEG_DATA  3
#define O26_SEG_BSS   4
#define O26_SEG_ZP    5

#define O26_RTYPE_LOW  0x20
#define O26_RTYPE_HIGH 0x40
#define O26_RTYPE_WORD 0x80
#define O26_RTYPE_AUX  0x10
#define O26_RTYPE_INDIRECT_JMP 0x08
#define O26_RTYPE_LAYOUT 0x04
#define O26_RTYPE_CONTROL_MASK 0x03
#define O26_RTYPE_CONTROL_NONE 0x00
#define O26_RTYPE_CONTROL_JSR  0x01
#define O26_RTYPE_CONTROL_JMP  0x02
#define O26_RTYPE_CONTROL_BRANCH 0x03

#define O26_LAYOUT_PAGE_CONTAINED 0x01
#define O26_LAYOUT_INDEX_RANGE    0x02

#define O26_BRANCH_MAGIC_V1 "B26\1"
#define O26_BRANCH_MAGIC_V2 "B26\2"
#define O26_BRANCH_MAGIC_SIZE 4

#define BRANCH_PAGE_FLEX  0
#define BRANCH_PAGE_SAME  1
#define BRANCH_PAGE_CROSS 2

#define SYMBOL_BACKED_META_PREFIX "__sbpmeta$"
#define ABI_META_PREFIX "__abimeta$V1$"
#define CONTRACT_META_PREFIX "__contractmeta$V1$"
#define SEMANTIC_USE_META_PREFIX "__usemeta$V1$"
#define MEM_REGION_META_PREFIX "__memmeta$V1$"

#define MAX_NAME 128
#define MAX_PATH 512

//! Memory region parsed from a linker configuration file.
typedef struct {
   uint16_t start;
   uint16_t size;
   uint16_t physical_size;
   char type[16];
   int define_yes;
   int callstack_callgraph;
   uint16_t callstack_extra;
   char file[MAX_PATH];
   int fill_yes;
   uint8_t fill_value;
   int has_fill_value;
   char bank_name[MAX_NAME];
   char name[MAX_NAME];
} memory_region_t;

//! Segment placement rule parsed from a linker configuration file.
typedef struct {
   char name[MAX_NAME];
   char load_name[MAX_NAME];
   char run_name[MAX_NAME];
   char type[16];
   int define_yes;
   uint16_t align;
   uint16_t start;
   int has_start;
} segment_rule_t;

//! One complete 4K physical bank in a full-window cartridge profile.
typedef struct {
   char name[MAX_NAME];
   uint16_t start;
   uint16_t size;
   uint16_t hotspot;
   int startup;
} cartridge_bank_t;

//! Complete in-memory linker configuration.
typedef struct {
   memory_region_t *mem;
   size_t mem_count;
   segment_rule_t *seg;
   size_t seg_count;
   cartridge_bank_t *banks;
   size_t bank_count;
   char mapper[MAX_NAME];
   uint8_t cartridge_fill_value;
   uint16_t vector_bridge_offset;
   int has_vector_bridge_offset;
   uint16_t trampoline_offset;
   uint16_t trampoline_size;
   int has_trampoline_offset;
   int has_trampoline_size;
   int cartridge_banked;
   int call_stack_enabled;
   char call_stack_region[MAX_NAME];
   uint16_t call_stack_depth;
   uint16_t call_stack_weighted_depth;
   uint16_t call_stack_bank_extra_slots;
   uint16_t call_stack_extra;
   uint16_t call_stack_size;
   uint16_t call_stack_start;
   uint16_t call_stack_top;
} linker_config_t;

//! Exported or imported o26 symbol record.
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
   uint8_t flags;
   uint16_t index_range_start;
   uint16_t index_range_max;
   uint16_t load_addr;
   uint16_t run_addr;
} object_layout_t;

typedef struct {
   uint32_t offset;
   uint8_t type;
   uint8_t segid;
   uint16_t undef_index;
   uint16_t layout_index;
   uint8_t aux_low;
   int has_aux_low;
   int has_layout_index;
} reloc_t;

typedef struct {
   uint8_t segid;
   uint16_t source;
   uint16_t target;
   uint8_t opcode;
   uint8_t page_policy;
} branch_t;

//! One loadable o26 segment plus relocations against it.
typedef struct {
   uint8_t *data;
   size_t length;
   uint16_t base;
   reloc_t *relocs;
   size_t reloc_count;
} o26_segment_t;

typedef struct archive_member_s archive_member_t;

//! Decoded o26 object plus placement state selected by the linker.
typedef struct {
   char origin[MAX_PATH];
   uint16_t mode;
   uint16_t tbase, dbase, bbase, zbase, stack;
   uint16_t blen, zlen;
   o26_segment_t text;
   o26_segment_t data;
   char **undefs;
   size_t undef_count;
   symbol_t *exports;
   size_t export_count;
   object_layout_t *layouts;
   size_t layout_count;
   branch_t *branches;
   size_t branch_count;
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
   uint32_t start;
   uint32_t end;
} memory_hole_t;

typedef struct {
   char name[MAX_NAME];
   uint16_t cur;
   uint32_t end;
   memory_hole_t *holes;
   size_t hole_count;
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

//! One deduplicated direct cross-bank control-transfer entry in the common table.
typedef struct {
   uint8_t kind;
   uint16_t target_addr;
   uint16_t table_offset;
   uint16_t source_hotspot;
   uint16_t destination_hotspot;
   char *target_name;
   char source_bank[MAX_NAME];
   char destination_bank[MAX_NAME];
} bank_trampoline_entry_t;

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
   bank_trampoline_entry_t *bank_trampoline_entries;
   size_t bank_trampoline_entry_count;
   uint16_t bank_trampoline_used;
   int call_stack_enabled;
   uint16_t call_stack_depth;
   uint16_t call_stack_weighted_depth;
   uint16_t call_stack_bank_extra_slots;
   uint16_t call_stack_extra;
   uint16_t call_stack_size;
   uint16_t call_stack_start;
   uint16_t call_stack_top;
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
