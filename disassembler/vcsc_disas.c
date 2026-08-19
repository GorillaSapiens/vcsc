#include <ctype.h>
#include <errno.h>
#include <getopt.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "version.h"
#include "dynamic_video_probe.h"

/*
 * vcsc-disas -- conservative Atari 2600 cartridge disassembler.
 *
 * The output contract is deliberately stronger than the analysis contract:
 * generated .s26 must reproduce the input bytes exactly.  Analysis may become
 * more ambitious over time; when it is uncertain, emission falls back to
 * .byte rather than inventing semantics.
 */

typedef enum {
   AM_IMPLIED,
   AM_ACCUMULATOR,
   AM_IMMEDIATE,
   AM_ZERO_PAGE,
   AM_ZERO_PAGE_X,
   AM_ZERO_PAGE_Y,
   AM_RELATIVE,
   AM_ABSOLUTE,
   AM_ABSOLUTE_X,
   AM_ABSOLUTE_Y,
   AM_INDIRECT,
   AM_INDEXED_INDIRECT,
   AM_INDIRECT_INDEXED
} address_mode_t;

#include "opcode_table.inc"

typedef enum {
   MAP_RAW,
   MAP_2K,
   MAP_4K,
   MAP_F8,
   MAP_F6,
   MAP_F4,
   MAP_FA,
   MAP_DPC,
   MAP_WD,
   MAP_E0,
   MAP_CV,
   MAP_JANE,
   MAP_0840,
   MAP_UA,
   MAP_UASW,
   MAP_0FA0
} mapper_t;

typedef enum {
   FLOW_NEXT,
   FLOW_BRANCH,
   FLOW_JSR,
   FLOW_JMP_ABSOLUTE,
   FLOW_JMP_INDIRECT,
   FLOW_RTS,
   FLOW_STOP
} flow_kind_t;

#define ROLE_CODE_START 0x01u
#define ROLE_CODE_BYTE  0x02u
#define ROLE_OPERAND    0x04u
#define ROLE_DATA_READ  0x08u
#define ROLE_POSSIBLE   0x10u
#define ROLE_LABEL      0x20u
#define ROLE_OVERLAP    0x40u
#define ROLE_VECTOR     0x80u

#define ACCESS_READ  0x01u
#define ACCESS_WRITE 0x02u

#define ZERO_PAGE_SIZE 256u
#define ZERO_PAGE_KNOWN_BYTES (ZERO_PAGE_SIZE / 8u)

static unsigned opcode_memory_access(uint8_t opcode);

typedef struct {
   uint8_t a_known;
   uint8_t a;
   uint8_t x_known;
   uint8_t x;
   uint8_t y_known;
   uint8_t y;
   uint8_t carry_known;
   uint8_t carry;
   uint8_t zero_known;
   uint8_t zero;
   uint8_t negative_known;
   uint8_t negative;
   uint8_t overflow_known;
   uint8_t overflow;
   uint8_t decimal_known;
   uint8_t decimal;
   uint8_t zp_known[ZERO_PAGE_KNOWN_BYTES];
   uint8_t zp_value[ZERO_PAGE_SIZE];
} abstract_state_t;

typedef struct {
   size_t file_offset;
   size_t size;
   uint16_t origin;
   int origin_score;
   int reset_vector_evidence;
   int origin_overridden;
   uint8_t *roles;
   uint8_t *inst_len;
   uint8_t *inst_opcode;
   uint8_t *queued;
   uint8_t *visited;
   uint8_t *state_seen;
   uint8_t *graphics;
   uint8_t *font_start;
   uint8_t *color_start;
   uint8_t *color_len;
   uint8_t *pointer_start;
   uint16_t *pointer_words;
   uint8_t *pointer_manual;
   uint8_t *manual_table_byte;
   uint8_t *manual_table_start;
   uint8_t *manual_pointer_byte;
   uint8_t *manual_pointer_start;
   uint8_t *force_raw;
   uint8_t *spec_rejected;
   uint8_t *spec_strong;
   uint16_t *spec_reject_end;
   uint8_t *spec_barrier;
   uint16_t *spec_barrier_end;
   uint8_t *spec_seed;
   uint32_t *wd_context_seen;
   uint64_t *e0_context_seen;
   uint8_t vector_tail_enabled;
   uint8_t cv_fixed_upper_half;
   abstract_state_t *states;
} bank_t;

typedef struct {
   size_t bank;
   size_t offset;
   uint16_t pc;
   uint16_t mapper_config;
} work_item_t;

static int cart_target_offset(const bank_t *b, uint16_t address, size_t *off);

typedef struct {
   uint8_t *rom;
   size_t rom_size;
   mapper_t mapper;
   size_t bank_size;
   size_t bank_count;
   bank_t *banks;
   size_t reset_bank;
   int mapper_overridden;
   int superchip_override;
   int reset_bank_overridden;
   const char *video_override;
   const char *input_name;
   const char *controller_override[2];
   int verbose;
   int wd_bad_dump;
   int hotspot_refs;
   int superchip_refs;
   int superchip_write_refs;
   int dynamic_control_exits;
   int unresolved_indirect_jumps;
   size_t reachable_halts;
   int mapper_flow_refined;
   size_t mapper_hypotheses_tested;
   size_t mapper_hypotheses_survived;
   size_t speculative_rejected_starts;
   size_t speculative_barriers;
   size_t speculative_islands;
   size_t flow_switch_avoided_halts;
   size_t speculative_switch_avoided_halts;
   work_item_t *work;
   size_t work_count;
   size_t work_cap;
} analysis_t;

#define MAX_HINT_SPECS 128u

typedef struct {
   const char *input;
   const char *output;
   int output_explicit;
   int mapper_override_set;
   mapper_t mapper_override;
   int superchip_override;
   int reset_bank_override;
   const char *video_override;
   const char *controller_override[2];
   const char *origin_specs[MAX_HINT_SPECS];
   size_t origin_count;
   const char *entry_specs[MAX_HINT_SPECS];
   size_t entry_count;
   const char *code_specs[MAX_HINT_SPECS];
   size_t code_count;
   const char *data_specs[MAX_HINT_SPECS];
   size_t data_count;
   const char *table_specs[MAX_HINT_SPECS];
   size_t table_count;
   const char *pointer_specs[MAX_HINT_SPECS];
   size_t pointer_count;
   int verbose;
} options_t;

/* ----------------------------- SHA-256 ---------------------------------- */

typedef struct {
   uint32_t h[8];
   uint64_t bits;
   uint8_t block[64];
   size_t used;
} sha256_ctx_t;

static uint32_t rotr32(uint32_t x, unsigned n)
{
   return (x >> n) | (x << (32u - n));
}

static void sha256_transform(sha256_ctx_t *c, const uint8_t b[64])
{
   static const uint32_t k[64] = {
      0x428a2f98u,0x71374491u,0xb5c0fbcfu,0xe9b5dba5u,
      0x3956c25bu,0x59f111f1u,0x923f82a4u,0xab1c5ed5u,
      0xd807aa98u,0x12835b01u,0x243185beu,0x550c7dc3u,
      0x72be5d74u,0x80deb1feu,0x9bdc06a7u,0xc19bf174u,
      0xe49b69c1u,0xefbe4786u,0x0fc19dc6u,0x240ca1ccu,
      0x2de92c6fu,0x4a7484aau,0x5cb0a9dcu,0x76f988dau,
      0x983e5152u,0xa831c66du,0xb00327c8u,0xbf597fc7u,
      0xc6e00bf3u,0xd5a79147u,0x06ca6351u,0x14292967u,
      0x27b70a85u,0x2e1b2138u,0x4d2c6dfcu,0x53380d13u,
      0x650a7354u,0x766a0abbu,0x81c2c92eu,0x92722c85u,
      0xa2bfe8a1u,0xa81a664bu,0xc24b8b70u,0xc76c51a3u,
      0xd192e819u,0xd6990624u,0xf40e3585u,0x106aa070u,
      0x19a4c116u,0x1e376c08u,0x2748774cu,0x34b0bcb5u,
      0x391c0cb3u,0x4ed8aa4au,0x5b9cca4fu,0x682e6ff3u,
      0x748f82eeu,0x78a5636fu,0x84c87814u,0x8cc70208u,
      0x90befffau,0xa4506cebu,0xbef9a3f7u,0xc67178f2u
   };
   uint32_t w[64];
   uint32_t a, d, e, f, g, h, t1, t2, b0, c0;
   unsigned i;

   for (i = 0; i < 16; ++i) {
      size_t j = (size_t)i * 4u;
      w[i] = ((uint32_t)b[j] << 24) | ((uint32_t)b[j+1] << 16) |
             ((uint32_t)b[j+2] << 8) | (uint32_t)b[j+3];
   }
   for (i = 16; i < 64; ++i) {
      uint32_t s0 = rotr32(w[i-15],7) ^ rotr32(w[i-15],18) ^ (w[i-15] >> 3);
      uint32_t s1 = rotr32(w[i-2],17) ^ rotr32(w[i-2],19) ^ (w[i-2] >> 10);
      w[i] = w[i-16] + s0 + w[i-7] + s1;
   }

   a = c->h[0]; b0 = c->h[1]; c0 = c->h[2]; d = c->h[3];
   e = c->h[4]; f = c->h[5]; g = c->h[6]; h = c->h[7];
   for (i = 0; i < 64; ++i) {
      uint32_t s1 = rotr32(e,6) ^ rotr32(e,11) ^ rotr32(e,25);
      uint32_t ch = (e & f) ^ ((~e) & g);
      uint32_t s0 = rotr32(a,2) ^ rotr32(a,13) ^ rotr32(a,22);
      uint32_t maj = (a & b0) ^ (a & c0) ^ (b0 & c0);
      t1 = h + s1 + ch + k[i] + w[i];
      t2 = s0 + maj;
      h = g; g = f; f = e; e = d + t1;
      d = c0; c0 = b0; b0 = a; a = t1 + t2;
   }
   c->h[0] += a; c->h[1] += b0; c->h[2] += c0; c->h[3] += d;
   c->h[4] += e; c->h[5] += f; c->h[6] += g; c->h[7] += h;
}

static void sha256_init(sha256_ctx_t *c)
{
   static const uint32_t initial[8] = {
      0x6a09e667u,0xbb67ae85u,0x3c6ef372u,0xa54ff53au,
      0x510e527fu,0x9b05688cu,0x1f83d9abu,0x5be0cd19u
   };
   memcpy(c->h, initial, sizeof(initial));
   c->bits = 0;
   c->used = 0;
}

static void sha256_update(sha256_ctx_t *c, const uint8_t *p, size_t n)
{
   while (n != 0) {
      size_t take = 64u - c->used;
      if (take > n) take = n;
      memcpy(c->block + c->used, p, take);
      c->used += take;
      p += take;
      n -= take;
      c->bits += (uint64_t)take * 8u;
      if (c->used == 64u) {
         sha256_transform(c, c->block);
         c->used = 0;
      }
   }
}

static void sha256_final(sha256_ctx_t *c, uint8_t out[32])
{
   uint64_t bits = c->bits;
   unsigned i;
   c->block[c->used++] = 0x80u;
   if (c->used > 56u) {
      while (c->used < 64u) c->block[c->used++] = 0;
      sha256_transform(c, c->block);
      c->used = 0;
   }
   while (c->used < 56u) c->block[c->used++] = 0;
   for (i = 0; i < 8; ++i)
      c->block[63u-i] = (uint8_t)(bits >> (i * 8u));
   sha256_transform(c, c->block);
   for (i = 0; i < 8; ++i) {
      out[i*4u] = (uint8_t)(c->h[i] >> 24);
      out[i*4u+1] = (uint8_t)(c->h[i] >> 16);
      out[i*4u+2] = (uint8_t)(c->h[i] >> 8);
      out[i*4u+3] = (uint8_t)c->h[i];
   }
}

static void sha256_hex(const uint8_t *p, size_t n, char out[65])
{
   static const char hex[] = "0123456789abcdef";
   sha256_ctx_t c;
   uint8_t digest[32];
   unsigned i;
   sha256_init(&c);
   sha256_update(&c, p, n);
   sha256_final(&c, digest);
   for (i = 0; i < 32; ++i) {
      out[i*2u] = hex[digest[i] >> 4];
      out[i*2u+1] = hex[digest[i] & 15u];
   }
   out[64] = '\0';
}

/* --------------------------- basic helpers ------------------------------ */

static int parse_mapper_name(const char *s, mapper_t *mapper, int *superchip)
{
   *superchip = -1;
   if (strcmp(s, "2k") == 0) *mapper = MAP_2K;
   else if (strcmp(s, "4k") == 0) *mapper = MAP_4K;
   else if (strcmp(s, "4ksc") == 0) { *mapper = MAP_4K; *superchip = 1; }
   else if (strcmp(s, "f8") == 0) { *mapper = MAP_F8; *superchip = 0; }
   else if (strcmp(s, "f6") == 0) { *mapper = MAP_F6; *superchip = 0; }
   else if (strcmp(s, "f4") == 0) { *mapper = MAP_F4; *superchip = 0; }
   else if (strcmp(s, "f8sc") == 0) { *mapper = MAP_F8; *superchip = 1; }
   else if (strcmp(s, "f6sc") == 0) { *mapper = MAP_F6; *superchip = 1; }
   else if (strcmp(s, "f4sc") == 0) { *mapper = MAP_F4; *superchip = 1; }
   else if (strcmp(s, "fa") == 0) *mapper = MAP_FA;
   else if (strcmp(s, "dpc") == 0) *mapper = MAP_DPC;
   else if (strcmp(s, "wd") == 0) *mapper = MAP_WD;
   else if (strcmp(s, "e0") == 0) *mapper = MAP_E0;
   else if (strcmp(s, "cv") == 0) *mapper = MAP_CV;
   else if (strcmp(s, "jane") == 0) *mapper = MAP_JANE;
   else if (strcmp(s, "0840") == 0) *mapper = MAP_0840;
   else if (strcmp(s, "ua") == 0) *mapper = MAP_UA;
   else if (strcmp(s, "uasw") == 0) *mapper = MAP_UASW;
   else if (strcmp(s, "0fa0") == 0) *mapper = MAP_0FA0;
   else return 0;
   return 1;
}

static int valid_video_override(const char *s)
{
   return strcmp(s, "ntsc") == 0 || strcmp(s, "pal") == 0 ||
          strcmp(s, "secam") == 0 || strcmp(s, "pal-family") == 0 ||
          strcmp(s, "unknown") == 0;
}

static int valid_controller_override(const char *s)
{
   return strcmp(s, "joystick") == 0 || strcmp(s, "paddles") == 0 ||
          strcmp(s, "keypad") == 0 || strcmp(s, "driving") == 0 ||
          strcmp(s, "unused") == 0 || strcmp(s, "unknown") == 0;
}

static int add_hint_spec(const char **array, size_t *count, const char *value,
                         const char *kind, const char *argv0)
{
   if (*count >= MAX_HINT_SPECS) {
      fprintf(stderr, "%s: too many --%s hints (maximum %u)\n",
              argv0, kind, (unsigned)MAX_HINT_SPECS);
      return 0;
   }
   array[(*count)++] = value;
   return 1;
}

static void usage(const char *argv0)
{
   fprintf(stderr,
      "usage: %s [options] cartridge.bin\n"
      "\n"
      "options:\n"
      "   -i, --input <file>       compatibility alias for positional input\n"
      "   -o, --output <file>      write generated VCSC assembly (.s26)\n"
      "       --mapper <name>      force 2k|4k|4ksc|f8|f8sc|f6|f6sc|f4|f4sc|fa|dpc|wd|e0|cv|jane|0840|ua|uasw|0fa0\n"
      "       --reset-bank <n>     force power-on/reset physical bank\n"
      "       --origin <b:addr>    force logical origin for a bank (repeatable)\n"
      "       --entry <b:addr>     add executable entry point (repeatable)\n"
      "       --code <b:a-b>       force a linear code range (repeatable)\n"
      "       --data <b:a-b>       mark a definite data range (repeatable)\n"
      "       --table <b:a-b>      mark/present a known generic data table\n"
      "       --pointer <b:a-b>    mark/present a little-endian pointer table\n"
      "       --video <name>       force ntsc|pal|secam|pal-family|unknown metadata\n"
      "       --controller0 <name> force joystick|paddles|keypad|driving|unused|unknown\n"
      "       --controller1 <name> force joystick|paddles|keypad|driving|unused|unknown\n"
      "       --verbose            include detailed inference evidence comments\n"
      "   -h, --help               show this help\n"
      "   -V, --version            show version information\n"
      "\n"
      "hint syntax:\n"
      "   addresses accept decimal, 0xFFFF, or $FFFF; bank may be omitted for\n"
      "   one-bank cartridges (for example --entry $F000 or --data $F200-$F2FF)\n"
      "\n"
      "notes:\n"
      "   without -o, output is derived from the input name with suffix .s26\n"
      "   -o - writes generated assembly to standard output\n"
      "   forced code/data/table/pointer roles may overlap executable bytes\n"
      "   --pointer ranges must contain an even number of bytes\n"
      "   exact bytes remain authoritative over presentation hints\n"
      "   exact byte reconstruction takes priority over speculative decoding\n"
      "\n"
      "example:\n"
      "   %s --origin 0:$D000 --entry 0:$D120 -o game.s26 game.bin\n",
      argv0, argv0);
}

static int parse_args(int argc, char **argv, options_t *opt)
{
   enum {
      OPT_MAPPER = 256, OPT_RESET_BANK, OPT_ORIGIN, OPT_ENTRY,
      OPT_CODE, OPT_DATA, OPT_TABLE, OPT_POINTER, OPT_VIDEO, OPT_CONTROLLER0, OPT_CONTROLLER1,
      OPT_VERBOSE
   };
   int ch;
   int option_index = 0;
   const char *positional = NULL;
   static struct option long_options[] = {
      { "input", required_argument, NULL, 'i' },
      { "output", required_argument, NULL, 'o' },
      { "mapper", required_argument, NULL, OPT_MAPPER },
      { "reset-bank", required_argument, NULL, OPT_RESET_BANK },
      { "origin", required_argument, NULL, OPT_ORIGIN },
      { "entry", required_argument, NULL, OPT_ENTRY },
      { "code", required_argument, NULL, OPT_CODE },
      { "data", required_argument, NULL, OPT_DATA },
      { "table", required_argument, NULL, OPT_TABLE },
      { "pointer", required_argument, NULL, OPT_POINTER },
      { "video", required_argument, NULL, OPT_VIDEO },
      { "controller0", required_argument, NULL, OPT_CONTROLLER0 },
      { "controller1", required_argument, NULL, OPT_CONTROLLER1 },
      { "verbose", no_argument, NULL, OPT_VERBOSE },
      { "help", no_argument, NULL, 'h' },
      { "version", no_argument, NULL, 'V' },
      { NULL, 0, NULL, 0 }
   };

   memset(opt, 0, sizeof(*opt));
   opt->reset_bank_override = -1;
   opt->superchip_override = -1;
   opterr = 0;
   while ((ch = getopt_long(argc, argv, ":Vhi:o:", long_options,
                            &option_index)) != -1) {
      switch (ch) {
      case 'h': usage(argv[0]); exit(0);
      case 'V': puts(VERSION); exit(0);
      case 'i':
         if (opt->input) {
            fprintf(stderr, "%s: input file specified more than once\n", argv[0]);
            return 0;
         }
         opt->input = optarg;
         break;
      case 'o':
         if (opt->output_explicit) {
            fprintf(stderr, "%s: output file specified more than once\n", argv[0]);
            return 0;
         }
         opt->output = optarg;
         opt->output_explicit = 1;
         break;
      case OPT_MAPPER:
         if (opt->mapper_override_set) {
            fprintf(stderr, "%s: --mapper specified more than once\n", argv[0]);
            return 0;
         }
         if (!parse_mapper_name(optarg, &opt->mapper_override,
                                &opt->superchip_override)) {
            fprintf(stderr, "%s: unsupported mapper override '%s'\n", argv[0], optarg);
            return 0;
         }
         opt->mapper_override_set = 1;
         break;
      case OPT_RESET_BANK: {
         char *endp;
         long n;
         if (opt->reset_bank_override >= 0) {
            fprintf(stderr, "%s: --reset-bank specified more than once\n", argv[0]);
            return 0;
         }
         errno = 0;
         n = strtol(optarg, &endp, 10);
         if (errno || *optarg == '\0' || *endp != '\0' || n < 0 || n > 65535) {
            fprintf(stderr, "%s: invalid --reset-bank value '%s'\n", argv[0], optarg);
            return 0;
         }
         opt->reset_bank_override = (int)n;
         break;
      }
      case OPT_ORIGIN:
         if (!add_hint_spec(opt->origin_specs, &opt->origin_count, optarg,
                            "origin", argv[0])) return 0;
         break;
      case OPT_ENTRY:
         if (!add_hint_spec(opt->entry_specs, &opt->entry_count, optarg,
                            "entry", argv[0])) return 0;
         break;
      case OPT_CODE:
         if (!add_hint_spec(opt->code_specs, &opt->code_count, optarg,
                            "code", argv[0])) return 0;
         break;
      case OPT_DATA:
         if (!add_hint_spec(opt->data_specs, &opt->data_count, optarg,
                            "data", argv[0])) return 0;
         break;
      case OPT_TABLE:
         if (!add_hint_spec(opt->table_specs, &opt->table_count, optarg,
                            "table", argv[0])) return 0;
         break;
      case OPT_POINTER:
         if (!add_hint_spec(opt->pointer_specs, &opt->pointer_count, optarg,
                            "pointer", argv[0])) return 0;
         break;
      case OPT_VIDEO:
         if (opt->video_override) {
            fprintf(stderr, "%s: --video specified more than once\n", argv[0]);
            return 0;
         }
         if (!valid_video_override(optarg)) {
            fprintf(stderr, "%s: invalid --video value '%s'\n", argv[0], optarg);
            return 0;
         }
         opt->video_override = optarg;
         break;
      case OPT_CONTROLLER0:
      case OPT_CONTROLLER1: {
         unsigned port = ch == OPT_CONTROLLER0 ? 0u : 1u;
         if (opt->controller_override[port]) {
            fprintf(stderr, "%s: --controller%u specified more than once\n",
                    argv[0], port);
            return 0;
         }
         if (!valid_controller_override(optarg)) {
            fprintf(stderr, "%s: invalid --controller%u value '%s'\n",
                    argv[0], port, optarg);
            return 0;
         }
         opt->controller_override[port] = optarg;
         break;
      }
      case OPT_VERBOSE:
         opt->verbose = 1;
         break;
      case ':':
         fprintf(stderr, "%s: missing argument for option '%s'\n",
                 argv[0], argv[optind - 1]);
         fprintf(stderr, "Try '%s --help' for a list of supported options.\n",
                 argv[0]);
         return 0;
      default:
         fprintf(stderr, "%s: unsupported option '%s'\n",
                 argv[0], argv[optind - 1]);
         fprintf(stderr, "Try '%s --help' for a list of supported options.\n",
                 argv[0]);
         return 0;
      }
   }

   while (optind < argc) {
      if (positional) {
         fprintf(stderr, "%s: unexpected positional argument '%s'\n",
                 argv[0], argv[optind]);
         return 0;
      }
      positional = argv[optind++];
   }
   if (positional) {
      if (opt->input) {
         fprintf(stderr, "%s: input file specified both positionally and with -i/--input\n",
                 argv[0]);
         return 0;
      }
      opt->input = positional;
   }
   if (!opt->input) {
      fprintf(stderr, "%s: input file is required\n", argv[0]);
      fprintf(stderr, "Try '%s --help' for a list of supported options.\n",
              argv[0]);
      return 0;
   }
   return 1;
}

static char *derived_output_name(const char *input)
{
   const char *slash = strrchr(input, '/');
#ifdef _WIN32
   const char *back = strrchr(input, '\\');
   if (!slash || (back && back > slash)) slash = back;
#endif
   const char *base = slash ? slash + 1 : input;
   const char *dot = strrchr(base, '.');
   size_t stem = dot ? (size_t)(dot - input) : strlen(input);
   char *out = (char *)malloc(stem + 5u);
   if (!out) return NULL;
   memcpy(out, input, stem);
   memcpy(out + stem, ".s26", 5u);
   return out;
}

static int read_file(const char *path, uint8_t **data, size_t *size)
{
   FILE *fp;
   long end;
   uint8_t *p;

   fp = fopen(path, "rb");
   if (!fp) {
      fprintf(stderr, "%s: %s\n", path, strerror(errno));
      return 0;
   }
   if (fseek(fp, 0, SEEK_END) != 0 || (end = ftell(fp)) < 0 ||
       fseek(fp, 0, SEEK_SET) != 0) {
      fprintf(stderr, "%s: cannot determine file size\n", path);
      fclose(fp);
      return 0;
   }
   if (end == 0) {
      fprintf(stderr, "%s: empty cartridge image\n", path);
      fclose(fp);
      return 0;
   }
   p = (uint8_t *)malloc((size_t)end);
   if (!p) {
      fprintf(stderr, "out of memory\n");
      fclose(fp);
      return 0;
   }
   if (fread(p, 1, (size_t)end, fp) != (size_t)end) {
      fprintf(stderr, "%s: short read\n", path);
      free(p);
      fclose(fp);
      return 0;
   }
   if (fclose(fp) != 0) {
      fprintf(stderr, "%s: close failed: %s\n", path, strerror(errno));
      free(p);
      return 0;
   }
   *data = p;
   *size = (size_t)end;
   return 1;
}

static unsigned instruction_length(address_mode_t mode)
{
   switch (mode) {
   case AM_IMPLIED:
   case AM_ACCUMULATOR: return 1;
   case AM_IMMEDIATE:
   case AM_ZERO_PAGE:
   case AM_ZERO_PAGE_X:
   case AM_ZERO_PAGE_Y:
   case AM_RELATIVE:
   case AM_INDEXED_INDIRECT:
   case AM_INDIRECT_INDEXED: return 2;
   case AM_ABSOLUTE:
   case AM_ABSOLUTE_X:
   case AM_ABSOLUTE_Y:
   case AM_INDIRECT: return 3;
   }
   return 1;
}

static flow_kind_t instruction_flow(uint8_t opcode)
{
   switch (opcode) {
   case 0x10: case 0x30: case 0x50: case 0x70:
   case 0x90: case 0xb0: case 0xd0: case 0xf0: return FLOW_BRANCH;
   case 0x20: return FLOW_JSR;
   case 0x4c: return FLOW_JMP_ABSOLUTE;
   case 0x6c: return FLOW_JMP_INDIRECT;
   case 0x60: return FLOW_RTS;
   case 0x00: case 0x40:
   case 0x02: case 0x12: case 0x22: case 0x32:
   case 0x42: case 0x52: case 0x62: case 0x72:
   case 0x92: case 0xb2: case 0xd2: case 0xf2: return FLOW_STOP;
   default: return FLOW_NEXT;
   }
}

static int opcode_is_cpu_halt(uint8_t opcode)
{
   switch (opcode) {
   case 0x02: case 0x12: case 0x22: case 0x32:
   case 0x42: case 0x52: case 0x62: case 0x72:
   case 0x92: case 0xb2: case 0xd2: case 0xf2:
      return 1;
   default:
      return 0;
   }
}

static int opcode_is_write_only(uint8_t opcode)
{
   switch (opcode) {
   case 0x81: case 0x85: case 0x8d: case 0x91: case 0x95: case 0x99: case 0x9d:
   case 0x84: case 0x8c: case 0x94:
   case 0x86: case 0x8e: case 0x96:
   case 0x83: case 0x87: case 0x8f: case 0x97:
   case 0x93: case 0x9b: case 0x9c: case 0x9e: case 0x9f:
      return 1;
   default:
      return 0;
   }
}

static int is_cart_address(uint16_t address)
{
   return (address & 0x1000u) != 0;
}

static int mapper_dimensions(mapper_t mapper, size_t rom_size,
                             size_t *bank_size, size_t *bank_count)
{
   switch (mapper) {
   case MAP_RAW: *bank_size = rom_size; *bank_count = 1u; return 1;
   case MAP_2K: *bank_size = 2048u; *bank_count = 1u; return rom_size == 2048u;
   case MAP_4K: *bank_size = 4096u; *bank_count = 1u; return rom_size == 4096u;
   case MAP_F8: *bank_size = 4096u; *bank_count = 2u; return rom_size == 8192u;
   case MAP_F6: *bank_size = 4096u; *bank_count = 4u; return rom_size == 16384u;
   case MAP_F4: *bank_size = 4096u; *bank_count = 8u; return rom_size == 32768u;
   case MAP_FA: *bank_size = 4096u; *bank_count = 3u; return rom_size == 12288u;
   case MAP_DPC: *bank_size = 4096u; *bank_count = 2u;
      return rom_size == 10240u || rom_size == 10495u;
   case MAP_WD: *bank_size = 1024u; *bank_count = 8u;
      return rom_size == 8192u || rom_size == 8195u;
   case MAP_E0: *bank_size = 1024u; *bank_count = 8u; return rom_size == 8192u;
   case MAP_CV: *bank_size = 2048u; *bank_count = 1u; return rom_size == 2048u;
   case MAP_JANE: *bank_size = 4096u; *bank_count = 4u; return rom_size == 16384u;
   case MAP_0840: *bank_size = 4096u; *bank_count = 2u; return rom_size == 8192u;
   case MAP_UA: *bank_size = 4096u; *bank_count = 2u; return rom_size == 8192u;
   case MAP_UASW: *bank_size = 4096u; *bank_count = 2u; return rom_size == 8192u;
   case MAP_0FA0: *bank_size = 4096u; *bank_count = 2u; return rom_size == 8192u;
   }
   return 0;
}

static int is_probably_cv(const uint8_t *rom, size_t size)
{
   size_t i;
   if (size != 2048u) return 0;
   /* VCSC's common four-byte mapper signature occupies logical $FFF8-$FFFB,
    * which is file $07F8-$07FB in CV's fixed 2K ROM. */
   if (memcmp(rom + size - 8u, "CV\0\0", 4u) == 0) return 1;
   /* Stella's established CV heuristics: indexed stores into either edge of
    * the split write window.  Recognizing the same signatures also identifies
    * historical CV images that predate VCSC's tail signature convention. */
   for (i = 0; i + 2u < size; ++i) {
      if (rom[i] == 0x9du && rom[i + 1u] == 0xffu && rom[i + 2u] == 0xf3u)
         return 1;
      if (rom[i] == 0x99u && rom[i + 1u] == 0x00u && rom[i + 2u] == 0xf4u)
         return 1;
   }
   return 0;
}

static int is_probably_jane(const uint8_t *rom, size_t size)
{
   size_t i;
   if (size != 16384u) return 0;
   if (memcmp(rom + size - 8u, "JANE", 4u) == 0) return 1;
   /* Current Stella heuristic for the Tarzan prototype: LDA $FFF1; RTS. */
   for (i = 0; i + 3u < size; ++i)
      if (rom[i] == 0xADu && rom[i + 1u] == 0xF1u &&
          rom[i + 2u] == 0xFFu && rom[i + 3u] == 0x60u)
         return 1;
   return 0;
}


static int count_signature(const uint8_t *rom, size_t size, const uint8_t *sig, size_t siglen)
{
   size_t i;
   int count = 0;
   if (!siglen || siglen > size) return 0;
   for (i = 0; i + siglen <= size; ++i)
      if (memcmp(rom + i, sig, siglen) == 0) ++count;
   return count;
}

static int is_probably_e0(const uint8_t *rom, size_t size)
{
   static const uint8_t signatures[][3] = {
      { 0x8Du, 0xE0u, 0x1Fu }, /* STA $1FE0 */
      { 0x8Du, 0xE0u, 0x5Fu }, /* STA $5FE0 */
      { 0x8Du, 0xE9u, 0xFFu }, /* STA $FFE9 */
      { 0x0Cu, 0xE0u, 0x1Fu }, /* NOP $1FE0 */
      { 0xADu, 0xE0u, 0x1Fu }, /* LDA $1FE0 */
      { 0xADu, 0xE9u, 0xFFu }, /* LDA $FFE9 */
      { 0xADu, 0xEDu, 0xFFu }, /* LDA $FFED */
      { 0xADu, 0xF3u, 0xBFu }  /* LDA $BFF3 */
   };
   size_t i;
   if (size != 8192u) return 0;
   for (i = 0; i < sizeof(signatures) / sizeof(signatures[0]); ++i)
      if (count_signature(rom, size, signatures[i], sizeof(signatures[i])))
         return 1;
   return 0;
}

static int is_probably_0840(const uint8_t *rom, size_t size)
{
   static const uint8_t lda0800[] = { 0xADu, 0x00u, 0x08u };
   static const uint8_t lda0840[] = { 0xADu, 0x40u, 0x08u };
   static const uint8_t bit0800[] = { 0x2Cu, 0x00u, 0x08u };
   static const uint8_t nop0800jmp[] = { 0x0Cu, 0x00u, 0x08u, 0x4Cu };
   static const uint8_t nop0fffjmp[] = { 0x0Cu, 0xFFu, 0x0Fu, 0x4Cu };
   if (size != 8192u) return 0;
   if (memcmp(rom + size - 8u, "0840", 4u) == 0) return 1;
   /* Match Stella's established EconoBanking detector: repeated direct
      accesses to the below-window selectors, or repeated NOP-read/JMP
      sequences used by state-preserving switch stubs. */
   if (count_signature(rom, size, lda0800, sizeof(lda0800)) >= 2 ||
       count_signature(rom, size, lda0840, sizeof(lda0840)) >= 2 ||
       count_signature(rom, size, bit0800, sizeof(bit0800)) >= 2)
      return 1;
   return count_signature(rom, size, nop0800jmp, sizeof(nop0800jmp)) >= 2 ||
          count_signature(rom, size, nop0fffjmp, sizeof(nop0fffjmp)) >= 2;
}


static mapper_t infer_ua_variant(const uint8_t *rom, size_t size)
{
   static const uint8_t sta0240[] = { 0x8Du, 0x40u, 0x02u };
   static const uint8_t lda0240[] = { 0xADu, 0x40u, 0x02u };
   static const uint8_t lda021fx[] = { 0xBDu, 0x1Fu, 0x02u };
   static const uint8_t bit02c0[] = { 0x2Cu, 0xC0u, 0x02u };
   static const uint8_t sta02c0[] = { 0x8Du, 0xC0u, 0x02u };
   static const uint8_t lda02c0[] = { 0xADu, 0xC0u, 0x02u };
   static const uint8_t bit0fb0[] = { 0x2Cu, 0xB0u, 0x0Fu };
   if (size != 8192u) return MAP_RAW;
   if (memcmp(rom + size - 8u, "UASW", 4u) == 0) return MAP_UASW;
   if (memcmp(rom + size - 8u, "UA\0\0", 4u) == 0) return MAP_UA;
   /* Match current Stella UA inference for historical images. UASW cannot be
      distinguished reliably from UA by access opcodes alone, so only VCSC's
      explicit UASW signature selects the swapped variant automatically. */
   if (count_signature(rom, size, sta0240, sizeof(sta0240)) ||
       count_signature(rom, size, lda0240, sizeof(lda0240)) ||
       count_signature(rom, size, lda021fx, sizeof(lda021fx)) ||
       count_signature(rom, size, bit02c0, sizeof(bit02c0)) ||
       count_signature(rom, size, sta02c0, sizeof(sta02c0)) ||
       count_signature(rom, size, lda02c0, sizeof(lda02c0)) ||
       count_signature(rom, size, bit0fb0, sizeof(bit0fb0)))
      return MAP_UA;
   return MAP_RAW;
}

static int is_probably_0fa0(const uint8_t *rom, size_t size)
{
   static const uint8_t bit0fc0[] = { 0x2Cu, 0xC0u, 0x0Fu };
   static const uint8_t sta0fc0[] = { 0x8Du, 0xC0u, 0x0Fu };
   static const uint8_t lda0fc0[] = { 0xADu, 0xC0u, 0x0Fu };
   static const uint8_t bitefc0[] = { 0x2Cu, 0xC0u, 0xEFu };
   if (size != 8192u) return 0;
   if (memcmp(rom + size - 8u, "0FA0", 4u) == 0) return 1;
   /* Match current Stella's Fotomania/Brazilian detector. */
   return count_signature(rom, size, bit0fc0, sizeof(bit0fc0)) ||
          count_signature(rom, size, sta0fc0, sizeof(sta0fc0)) ||
          count_signature(rom, size, lda0fc0, sizeof(lda0fc0)) ||
          count_signature(rom, size, bitefc0, sizeof(bitefc0));
}


static mapper_t infer_mapper(const uint8_t *rom, size_t size,
                             size_t *bank_size, size_t *bank_count)
{
   mapper_t mapper;
   switch (size) {
   case 2048u: mapper = is_probably_cv(rom, size) ? MAP_CV : MAP_2K; break;
   case 4096u: mapper = MAP_4K; break;
   case 8192u:
      mapper = is_probably_e0(rom, size) ? MAP_E0 : MAP_RAW;
      if (mapper == MAP_RAW) mapper = infer_ua_variant(rom, size);
      if (mapper == MAP_RAW) mapper = is_probably_0fa0(rom, size) ? MAP_0FA0 : MAP_RAW;
      if (mapper == MAP_RAW) mapper = is_probably_0840(rom, size) ? MAP_0840 : MAP_F8;
      break;
   case 12288u: mapper = MAP_FA; break;
   case 16384u: mapper = is_probably_jane(rom, size) ? MAP_JANE : MAP_F6; break;
   case 32768u: mapper = MAP_F4; break;
   case 10240u: case 10495u: mapper = MAP_DPC; break;
   case 8195u: mapper = MAP_WD; break;
   default: mapper = MAP_RAW; break;
   }
   (void)mapper_dimensions(mapper, size, bank_size, bank_count);
   return mapper;
}

static const char *mapper_name(mapper_t mapper)
{
   switch (mapper) {
   case MAP_2K: return "unbanked 2K";
   case MAP_4K: return "unbanked 4K";
   case MAP_F8: return "F8";
   case MAP_F6: return "F6";
   case MAP_F4: return "F4";
   case MAP_FA: return "FA";
   case MAP_DPC: return "DPC";
   case MAP_WD: return "WD";
   case MAP_E0: return "E0";
   case MAP_CV: return "CV";
   case MAP_JANE: return "JANE";
   case MAP_0840: return "0840";
   case MAP_UA: return "UA";
   case MAP_UASW: return "UASW";
   case MAP_0FA0: return "0FA0";
   case MAP_RAW: return "unknown/raw";
   }
   return "unknown/raw";
}

/* Wickstead Design / Pursuit of the Pink Panther mapper.  Each configuration
 * maps four independently selected 1K ROM banks into $1000-$1FFF.  The known
 * 8195-byte dump is a malformed preservation image where physical 1K chunks 2
 * and 3 are reversed; keep file offsets unchanged for exact reconstruction but
 * translate logical WD bank numbers while analyzing runtime mappings. */
static const uint8_t wd_bank_org[8][4] = {
   { 0, 0, 1, 3 }, { 0, 1, 2, 3 }, { 4, 5, 6, 7 }, { 7, 4, 2, 3 },
   { 0, 0, 6, 7 }, { 0, 1, 7, 6 }, { 2, 3, 4, 5 }, { 6, 0, 5, 1 }
};

static size_t wd_logical_to_physical(const analysis_t *a, size_t logical)
{
   if (a->wd_bad_dump) {
      if (logical == 2u) return 3u;
      if (logical == 3u) return 2u;
   }
   return logical;
}

static size_t wd_physical_to_logical(const analysis_t *a, size_t physical)
{
   /* The historical bad dump swap is its own inverse. */
   return wd_logical_to_physical(a, physical);
}

static uint16_t wd_preferred_origin(const analysis_t *a, size_t physical)
{
   size_t logical = wd_physical_to_logical(a, physical);
   unsigned config, segment;
   for (config = 0; config < 8u; ++config) {
      for (segment = 0; segment < 4u; ++segment) {
         if (wd_bank_org[config][segment] == logical)
            return (uint16_t)(0xf000u + segment * 0x0400u);
      }
   }
   return 0xf000u;
}

static int wd_map_address(const analysis_t *a, uint8_t config,
                          uint16_t address, size_t *bank, size_t *off)
{
   uint16_t bus = (uint16_t)(address & 0x1fffu);
   unsigned segment;
   size_t logical;
   if (a->mapper != MAP_WD || bus < 0x1000u) return 0;
   if (bus < 0x1080u) return 0; /* 64-byte RAM read/write ports occupy $1000-$107F. */
   segment = (unsigned)((bus - 0x1000u) >> 10);
   if (segment >= 4u) return 0;
   logical = wd_bank_org[config & 7u][segment];
   *bank = wd_logical_to_physical(a, logical);
   *off = (size_t)(bus & 0x03ffu);
   return *bank < a->bank_count;
}

static int wd_hotspot_config(uint16_t address, uint8_t *config)
{
   uint16_t bus = (uint16_t)(address & 0x1fffu);
   if (bus >= 0x1000u) return 0;
   if ((bus & 0x00ffu) < 0x30u || (bus & 0x00ffu) > 0x3fu) return 0;
   *config = (uint8_t)(bus & 7u);
   return 1;
}

#define E0_RESET_CONFIG ((uint16_t)(4u | (5u << 3) | (6u << 6)))

static unsigned e0_config_bank(uint16_t config, unsigned segment)
{
   if (segment >= 3u) return 7u;
   return (unsigned)((config >> (segment * 3u)) & 7u);
}

static uint16_t e0_config_select(uint16_t config, unsigned segment,
                                 unsigned bank)
{
   uint16_t shift;
   uint16_t mask;
   if (segment >= 3u) return config;
   shift = (uint16_t)(segment * 3u);
   mask = (uint16_t)(7u << shift);
   return (uint16_t)((config & (uint16_t)~mask) |
                     (uint16_t)((bank & 7u) << shift));
}

static int e0_map_address(const analysis_t *a, uint16_t config,
                          uint16_t address, size_t *bank, size_t *off)
{
   uint16_t bus = (uint16_t)(address & 0x1fffu);
   unsigned segment;
   if (a->mapper != MAP_E0 || bus < 0x1000u) return 0;
   segment = (unsigned)((bus - 0x1000u) >> 10);
   if (segment >= 4u) return 0;
   *bank = (size_t)e0_config_bank(config, segment);
   *off = (size_t)(bus & 0x03ffu);
   return *bank < a->bank_count;
}

static int e0_selector_config(uint16_t address, uint16_t old_config,
                              uint16_t *new_config)
{
   uint16_t bus = (uint16_t)(address & 0x1fffu);
   unsigned segment;
   if (bus < 0x1fe0u || bus > 0x1ff7u) return 0;
   segment = (unsigned)((bus - 0x1fe0u) >> 3);
   if (segment >= 3u) return 0;
   *new_config = e0_config_select(old_config, segment, bus & 7u);
   return 1;
}

static uint16_t e0_seed_config(size_t bank, uint16_t pc)
{
   uint16_t bus = (uint16_t)(pc & 0x1fffu);
   unsigned segment;
   uint16_t config = E0_RESET_CONFIG;
   if (bus < 0x1000u) return config;
   segment = (unsigned)((bus - 0x1000u) >> 10);
   if (segment < 3u) return e0_config_select(config, segment, (unsigned)bank);
   return config;
}

static int origin_candidate_valid(uint16_t origin, size_t bank_size)
{
   if (!is_cart_address(origin)) return 0;
   if (bank_size == 4096u) return (origin & 0x0fffu) == 0;
   if (bank_size == 2048u) return (origin & 0x07ffu) == 0;
   if (bank_size == 1024u) return (origin & 0x03ffu) == 0;
   return 0;
}

static uint16_t origin_from_target(uint16_t target, size_t bank_size)
{
   uint16_t mask = (uint16_t)(bank_size - 1u);
   return (uint16_t)(target & (uint16_t)~mask);
}

static uint16_t read_word(const uint8_t *p)
{
   return (uint16_t)(p[0] | ((uint16_t)p[1] << 8));
}

static int origin_index(uint16_t origin, size_t bank_size)
{
   if (bank_size == 4096u) return (int)(origin >> 12);
   if (bank_size == 2048u) return (int)(origin >> 11);
   if (bank_size == 1024u) return (int)(origin >> 10);
   return -1;
}

static uint16_t infer_bank_origin(const uint8_t *data, size_t size,
                                  size_t bank_size, int *score_out,
                                  int *reset_evidence)
{
   int scores[64];
   size_t i;
   int best_score = -1;
   uint16_t best = bank_size == 2048u ? 0xf800u :
                   (bank_size == 1024u ? 0xfc00u : 0xf000u);
   memset(scores, 0, sizeof(scores));
   *reset_evidence = 0;

   if (size >= 6u) {
      static const int weights[3] = { 12, 48, 12 };
      unsigned v;
      for (v = 0; v < 3; ++v) {
         uint16_t target = read_word(data + size - 6u + (size_t)v * 2u);
         if (is_cart_address(target)) {
            uint16_t origin = origin_from_target(target, bank_size);
            int idx = origin_index(origin, bank_size);
            if (idx >= 0 && idx < (int)(sizeof(scores)/sizeof(scores[0])) &&
                origin_candidate_valid(origin, bank_size)) {
               size_t off = (size_t)(target & (uint16_t)(bank_size - 1u));
               scores[idx] += weights[v];
               if (off < size && data[off] != 0x00u && data[off] != 0xffu)
                  scores[idx] += 4;
               if (v == 1) *reset_evidence = 1;
            }
         }
      }
   }

   for (i = 0; i + 2u < size; ++i) {
      if (data[i] == 0x4cu || data[i] == 0x20u) {
         uint16_t target = read_word(data + i + 1u);
         if (is_cart_address(target)) {
            uint16_t origin = origin_from_target(target, bank_size);
            int idx = origin_index(origin, bank_size);
            if (idx >= 0 && idx < (int)(sizeof(scores)/sizeof(scores[0])) &&
                origin_candidate_valid(origin, bank_size)) {
               size_t off = (size_t)(target & (uint16_t)(bank_size - 1u));
               scores[idx] += data[i] == 0x4cu ? 3 : 2;
               if (off < size && data[off] != 0x00u && data[off] != 0xffu)
                  scores[idx] += 1;
            }
         }
      }
   }

   for (i = 0; i < sizeof(scores)/sizeof(scores[0]); ++i) {
      uint16_t origin = bank_size == 4096u
         ? (uint16_t)(i << 12)
         : (bank_size == 2048u ? (uint16_t)(i << 11)
                               : (uint16_t)(i << 10));
      if (!origin_candidate_valid(origin, bank_size)) continue;
      if (scores[i] > best_score ||
          (scores[i] == best_score && origin > best)) {
         best_score = scores[i];
         best = origin;
      }
   }
   if (best_score < 0) best_score = 0;
   *score_out = best_score;
   return best;
}

static int allocate_bank(bank_t *b, size_t size)
{
   b->roles = (uint8_t *)calloc(size, 1);
   b->inst_len = (uint8_t *)calloc(size, 1);
   b->inst_opcode = (uint8_t *)calloc(size, 1);
   b->queued = (uint8_t *)calloc(size, 1);
   b->visited = (uint8_t *)calloc(size, 1);
   b->state_seen = (uint8_t *)calloc(size, 1);
   b->graphics = (uint8_t *)calloc(size, 1);
   b->font_start = (uint8_t *)calloc(size, 1);
   b->color_start = (uint8_t *)calloc(size, 1);
   b->color_len = (uint8_t *)calloc(size, 1);
   b->pointer_start = (uint8_t *)calloc(size, 1);
   b->pointer_words = (uint16_t *)calloc(size, sizeof(*b->pointer_words));
   b->pointer_manual = (uint8_t *)calloc(size, 1);
   b->manual_table_byte = (uint8_t *)calloc(size, 1);
   b->manual_table_start = (uint8_t *)calloc(size, 1);
   b->manual_pointer_byte = (uint8_t *)calloc(size, 1);
   b->manual_pointer_start = (uint8_t *)calloc(size, 1);
   b->force_raw = (uint8_t *)calloc(size, 1);
   b->spec_rejected = (uint8_t *)calloc(size, 1);
   b->spec_strong = (uint8_t *)calloc(size, 1);
   b->spec_reject_end = (uint16_t *)malloc(size * sizeof(*b->spec_reject_end));
   b->spec_barrier = (uint8_t *)calloc(size, 1);
   b->spec_barrier_end = (uint16_t *)malloc(size * sizeof(*b->spec_barrier_end));
   b->spec_seed = (uint8_t *)calloc(size, 1);
   b->wd_context_seen = (uint32_t *)calloc(size, sizeof(*b->wd_context_seen));
   b->states = (abstract_state_t *)calloc(size, sizeof(*b->states));
   return b->roles && b->inst_len && b->inst_opcode && b->queued && b->visited &&
          b->state_seen && b->graphics && b->font_start && b->color_start && b->color_len &&
          b->pointer_start && b->pointer_words && b->pointer_manual &&
          b->manual_table_byte && b->manual_table_start &&
          b->manual_pointer_byte && b->manual_pointer_start &&
          b->force_raw && b->spec_rejected && b->spec_strong &&
          b->spec_reject_end && b->spec_barrier && b->spec_barrier_end && b->spec_seed &&
          b->wd_context_seen && b->states;
}

static void free_analysis(analysis_t *a)
{
   size_t i;
   if (a->banks) {
      for (i = 0; i < a->bank_count; ++i) {
         free(a->banks[i].roles);
         free(a->banks[i].inst_len);
         free(a->banks[i].inst_opcode);
         free(a->banks[i].queued);
         free(a->banks[i].visited);
         free(a->banks[i].state_seen);
         free(a->banks[i].graphics);
         free(a->banks[i].font_start);
         free(a->banks[i].color_start);
         free(a->banks[i].color_len);
         free(a->banks[i].pointer_start);
         free(a->banks[i].pointer_words);
         free(a->banks[i].pointer_manual);
         free(a->banks[i].manual_table_byte);
         free(a->banks[i].manual_table_start);
         free(a->banks[i].manual_pointer_byte);
         free(a->banks[i].manual_pointer_start);
         free(a->banks[i].force_raw);
         free(a->banks[i].spec_rejected);
         free(a->banks[i].spec_strong);
         free(a->banks[i].spec_reject_end);
         free(a->banks[i].spec_barrier);
         free(a->banks[i].spec_barrier_end);
         free(a->banks[i].spec_seed);
         free(a->banks[i].wd_context_seen);
         free(a->banks[i].e0_context_seen);
         free(a->banks[i].states);
      }
   }
   free(a->banks);
   free(a->work);
   memset(a, 0, sizeof(*a));
}

static int init_analysis(analysis_t *a, uint8_t *rom, size_t rom_size,
                         const options_t *opt)
{
   size_t i;
   memset(a, 0, sizeof(*a));
   a->rom = rom;
   a->rom_size = rom_size;
   if (opt->mapper_override_set) {
      a->mapper = opt->mapper_override;
      if (!mapper_dimensions(a->mapper, rom_size, &a->bank_size, &a->bank_count)) {
         fprintf(stderr, "--mapper %s is incompatible with %zu-byte input\n",
                 mapper_name(a->mapper), rom_size);
         return 0;
      }
      a->mapper_overridden = 1;
      a->superchip_override = opt->superchip_override;
   }
   else {
      a->mapper = infer_mapper(rom, rom_size, &a->bank_size, &a->bank_count);
   }
   a->wd_bad_dump = a->mapper == MAP_WD && rom_size == 8195u;
   a->video_override = opt->video_override;
   a->input_name = opt->input;
   a->controller_override[0] = opt->controller_override[0];
   a->controller_override[1] = opt->controller_override[1];
   a->verbose = opt->verbose;
   a->banks = (bank_t *)calloc(a->bank_count, sizeof(*a->banks));
   if (!a->banks) return 0;

   if (a->mapper == MAP_RAW) {
      a->banks[0].file_offset = 0;
      a->banks[0].size = rom_size;
      return allocate_bank(&a->banks[0], rom_size);
   }

   for (i = 0; i < a->bank_count; ++i) {
      bank_t *b = &a->banks[i];
      b->file_offset = i * a->bank_size;
      b->size = a->bank_size;
      b->origin = infer_bank_origin(rom + b->file_offset, b->size,
                                    b->size, &b->origin_score,
                                    &b->reset_vector_evidence);
      if (a->mapper == MAP_WD) {
         b->origin = wd_preferred_origin(a, i);
         b->origin_score = 100;
         b->reset_vector_evidence = 0;
      }
      else if (a->mapper == MAP_E0) {
         /* Physical bank 7 is permanently mapped into the top 1K and owns
          * all hardware vectors. Other 1K banks may appear in any of the
          * lower three windows; retain origin scoring for presentation. */
         if (i == 7u) {
            b->origin = 0xfc00u;
            b->origin_score = 100;
            b->reset_vector_evidence = 1;
         }
         else if (((b->origin & 0x1fffu) - 0x1000u) / 0x0400u >= 3u) {
            b->origin = 0xf000u;
         }
      }
      b->vector_tail_enabled = a->mapper != MAP_WD && a->mapper != MAP_E0;
      b->cv_fixed_upper_half = a->mapper == MAP_CV;
      if (!allocate_bank(b, b->size)) return 0;
      if (a->mapper == MAP_E0) {
         /* E0 has 512 selector configurations and four runtime 1K windows.
          * Keep a per-byte context bitset so the same physical byte can be
          * traced at more than one runtime address/configuration. */
         b->e0_context_seen = (uint64_t *)calloc(b->size * 32u,
                                                sizeof(*b->e0_context_seen));
         if (!b->e0_context_seen) return 0;
      }
   }

   if (a->mapper == MAP_E0) {
      /* Parker Brothers E0 always fetches vectors from physical 1K bank 7.
       * Stella's deterministic reset arrangement maps banks 4,5,6 into the
       * lower three windows; bank 7 remains fixed at $xC00-$xFFF. */
      a->reset_bank = 7u;
      a->banks[7].vector_tail_enabled = 1u;
      a->banks[7].reset_vector_evidence = 1;
      return 1;
   }

   if (a->mapper == MAP_WD) {
      /* Configuration 0 is the fixed power-on mapping.  Its top 1K segment
       * supplies the hardware vectors; the RESET target itself may resolve to
       * any of the four segments in that configuration. */
      a->reset_bank = wd_logical_to_physical(a, wd_bank_org[0][3]);
      a->banks[a->reset_bank].vector_tail_enabled = 1u;
      a->banks[a->reset_bank].reset_vector_evidence = 1;
      return 1;
   }

   /* F8/F6/F4 conventionally power up/reset through the final physical bank.
    * Prefer a bank with a plausible reset vector; ties deliberately favor the
    * final bank.  This is analysis metadata, not an emitted-byte assumption. */
   a->reset_bank = a->bank_count - 1u;
   {
      int best = -1;
      for (i = 0; i < a->bank_count; ++i) {
         bank_t *b = &a->banks[i];
         int score = 0;
         if (b->size >= 4u) {
            uint16_t reset = read_word(rom + b->file_offset + b->size - 4u);
            if (is_cart_address(reset)) {
               size_t off = (size_t)(reset & (uint16_t)(b->size - 1u));
               score += 10;
               if (off < b->size && rom[b->file_offset + off] != 0x00u &&
                   rom[b->file_offset + off] != 0xffu)
                  score += 4;
            }
         }
         score += b->origin_score > 20 ? 2 : 0;
         if (score > best || (score == best && i > a->reset_bank)) {
            best = score;
            a->reset_bank = i;
         }
      }
   }
   /* CBS RAM Plus (FA) hardware powers up in physical bank 2. */
   if (a->mapper == MAP_FA) a->reset_bank = 2u;
   if (a->mapper == MAP_JANE) a->reset_bank = 1u;
   if (a->mapper == MAP_0840) a->reset_bank = 0u;
   if (a->mapper == MAP_UA || a->mapper == MAP_UASW) a->reset_bank = 0u;
   if (a->mapper == MAP_0FA0) a->reset_bank = 1u;
   return 1;
}

static int parse_uint_text(const char *text, unsigned long max,
                           unsigned long *value)
{
   char *endp;
   int base = 0;
   const char *p = text;
   unsigned long v;
   if (*p == '$') { ++p; base = 16; }
   if (*p == '\0') return 0;
   errno = 0;
   v = strtoul(p, &endp, base);
   if (errno || *endp != '\0' || v > max) return 0;
   *value = v;
   return 1;
}

static int parse_bank_prefix(const analysis_t *a, const char *text,
                             size_t prefix_len, size_t *bank)
{
   char tmp[32];
   unsigned long value;
   if (prefix_len == 0u) {
      if (a->bank_count != 1u) return 0;
      *bank = 0u;
      return 1;
   }
   if (prefix_len >= sizeof(tmp)) return 0;
   memcpy(tmp, text, prefix_len);
   tmp[prefix_len] = '\0';
   if (!parse_uint_text(tmp, (unsigned long)(a->bank_count - 1u), &value))
      return 0;
   *bank = (size_t)value;
   return 1;
}

static int parse_bank_address(const analysis_t *a, const char *spec,
                              size_t *bank, uint16_t *address)
{
   const char *colon = strchr(spec, ':');
   const char *addr = spec;
   unsigned long value;
   if (colon) {
      if (!parse_bank_prefix(a, spec, (size_t)(colon - spec), bank)) return 0;
      addr = colon + 1;
   }
   else {
      if (a->bank_count != 1u) return 0;
      *bank = 0u;
   }
   if (!parse_uint_text(addr, 0xffffu, &value)) return 0;
   *address = (uint16_t)value;
   return 1;
}

static int parse_bank_range(const analysis_t *a, const char *spec,
                            size_t *bank, uint16_t *first, uint16_t *last)
{
   const char *colon = strchr(spec, ':');
   const char *body = spec;
   const char *dash;
   char left[32];
   unsigned long a0, a1;
   if (colon) {
      if (!parse_bank_prefix(a, spec, (size_t)(colon - spec), bank)) return 0;
      body = colon + 1;
   }
   else {
      if (a->bank_count != 1u) return 0;
      *bank = 0u;
   }
   dash = strchr(body, '-');
   if (!dash || strchr(dash + 1, '-')) return 0;
   if ((size_t)(dash - body) == 0u || (size_t)(dash - body) >= sizeof(left))
      return 0;
   memcpy(left, body, (size_t)(dash - body));
   left[dash - body] = '\0';
   if (!parse_uint_text(left, 0xffffu, &a0) ||
       !parse_uint_text(dash + 1, 0xffffu, &a1) || a1 < a0)
      return 0;
   *first = (uint16_t)a0;
   *last = (uint16_t)a1;
   return 1;
}

static int apply_layout_overrides(analysis_t *a, const options_t *opt)
{
   size_t i;
   if (a->mapper == MAP_RAW &&
       (opt->origin_count || opt->entry_count || opt->code_count || opt->data_count ||
        opt->table_count || opt->pointer_count || opt->reset_bank_override >= 0)) {
      fprintf(stderr, "analysis address hints require a supported/forced mapper, not raw mode\n");
      return 0;
   }
   for (i = 0; i < opt->origin_count; ++i) {
      size_t bank;
      uint16_t origin;
      if (!parse_bank_address(a, opt->origin_specs[i], &bank, &origin)) {
         fprintf(stderr, "invalid --origin hint '%s'\n", opt->origin_specs[i]);
         return 0;
      }
      if (!origin_candidate_valid(origin, a->banks[bank].size)) {
         fprintf(stderr, "--origin '%s' is not a valid page-aligned cartridge origin\n",
                 opt->origin_specs[i]);
         return 0;
      }
      if (a->banks[bank].origin_overridden && a->banks[bank].origin != origin) {
         fprintf(stderr, "conflicting --origin hints for bank %zu\n", bank);
         return 0;
      }
      a->banks[bank].origin = origin;
      a->banks[bank].origin_overridden = 1;
   }
   if (opt->reset_bank_override >= 0) {
      if ((size_t)opt->reset_bank_override >= a->bank_count) {
         fprintf(stderr, "--reset-bank %d is outside the %zu-bank cartridge\n",
                 opt->reset_bank_override, a->bank_count);
         return 0;
      }
      a->reset_bank = (size_t)opt->reset_bank_override;
      a->reset_bank_overridden = 1;
   }
   return 1;
}

static int hint_address_offset(const analysis_t *a, const char *kind,
                               const char *spec, size_t *bank, size_t *off)
{
   uint16_t address;
   if (!parse_bank_address(a, spec, bank, &address) ||
       !cart_target_offset(&a->banks[*bank], address, off) ||
       (uint16_t)(a->banks[*bank].origin + (uint16_t)*off) != address) {
      fprintf(stderr, "invalid --%s hint '%s' for inferred/forced bank origins\n",
              kind, spec);
      return 0;
   }
   return 1;
}

static int hint_range_offsets(const analysis_t *a, const char *kind,
                              const char *spec, size_t *bank,
                              size_t *first, size_t *last)
{
   uint16_t a0, a1;
   if (!parse_bank_range(a, spec, bank, &a0, &a1) ||
       !cart_target_offset(&a->banks[*bank], a0, first) ||
       !cart_target_offset(&a->banks[*bank], a1, last) ||
       (uint16_t)(a->banks[*bank].origin + (uint16_t)*first) != a0 ||
       (uint16_t)(a->banks[*bank].origin + (uint16_t)*last) != a1) {
      fprintf(stderr, "invalid --%s range '%s' for inferred/forced bank origins\n",
              kind, spec);
      return 0;
   }
   return 1;
}

static int state_zp_is_known(const abstract_state_t *state, uint8_t address)
{
   return (state->zp_known[address >> 3] &
           (uint8_t)(1u << (address & 7u))) != 0;
}

static void state_zp_set_known(abstract_state_t *state, uint8_t address,
                               uint8_t value)
{
   state->zp_known[address >> 3] |= (uint8_t)(1u << (address & 7u));
   state->zp_value[address] = value;
}

static void state_zp_set_unknown(abstract_state_t *state, uint8_t address)
{
   state->zp_known[address >> 3] &=
      (uint8_t)~(uint8_t)(1u << (address & 7u));
}

static void state_zp_set_all_unknown(abstract_state_t *state)
{
   memset(state->zp_known, 0, sizeof(state->zp_known));
}

static int state_zp_get(const abstract_state_t *state, uint8_t address,
                        uint8_t *value)
{
   if (!state_zp_is_known(state, address)) return 0;
   *value = state->zp_value[address];
   return 1;
}

/* Meet two forward abstract states.  Knowledge only decreases at joins, so a
 * changed state is safe to re-run until the work list reaches a fixed point. */
static int state_merge(abstract_state_t *dst, const abstract_state_t *src)
{
   unsigned address;
   int changed = 0;

#define MERGE_SCALAR(name)                                                     \
   do {                                                                        \
      if (dst->name##_known &&                                                 \
          (!src->name##_known || dst->name != src->name)) {                   \
         dst->name##_known = 0;                                                \
         changed = 1;                                                          \
      }                                                                        \
   } while (0)
   MERGE_SCALAR(a);
   MERGE_SCALAR(x);
   MERGE_SCALAR(y);
   MERGE_SCALAR(carry);
   MERGE_SCALAR(zero);
   MERGE_SCALAR(negative);
   MERGE_SCALAR(overflow);
   MERGE_SCALAR(decimal);
#undef MERGE_SCALAR

   for (address = 0; address < ZERO_PAGE_SIZE; ++address) {
      uint8_t zp = (uint8_t)address;
      if (state_zp_is_known(dst, zp) &&
          (!state_zp_is_known(src, zp) || dst->zp_value[zp] != src->zp_value[zp])) {
         state_zp_set_unknown(dst, zp);
         changed = 1;
      }
   }
   return changed;
}

static int push_work_state_ctx(analysis_t *a, size_t bank, size_t offset,
                               const abstract_state_t *state,
                               uint16_t pc, uint16_t mapper_config)
{
   bank_t *b;
   work_item_t *nw;
   int changed;
   uint32_t wd_bit = 0;
   if (bank >= a->bank_count) return 1;
   b = &a->banks[bank];
   if (offset >= b->size) return 1;
   if (a->mapper == MAP_WD) {
      unsigned segment = (unsigned)(((pc & 0x1fffu) - 0x1000u) >> 10);
      unsigned context = ((unsigned)mapper_config & 7u) * 4u + (segment & 3u);
      wd_bit = (uint32_t)1u << context;
      if ((b->wd_context_seen[offset] & wd_bit) != 0) return 1;
      b->wd_context_seen[offset] |= wd_bit;
   }
   else if (a->mapper == MAP_E0) {
      uint16_t bus = (uint16_t)(pc & 0x1fffu);
      unsigned segment;
      unsigned context;
      size_t word;
      uint64_t bit;
      if (bus < 0x1000u) return 1;
      segment = (unsigned)((bus - 0x1000u) >> 10) & 3u;
      context = (((unsigned)mapper_config & 0x1ffu) << 2) | segment;
      word = (size_t)(context >> 6);
      bit = (uint64_t)1u << (context & 63u);
      if ((b->e0_context_seen[offset * 32u + word] & bit) != 0) return 1;
      b->e0_context_seen[offset * 32u + word] |= bit;
   }
   if (!b->state_seen[offset]) {
      b->states[offset] = *state;
      b->state_seen[offset] = 1;
      changed = 1;
   }
   else {
      changed = state_merge(&b->states[offset], state);
   }
   if (a->mapper != MAP_WD && a->mapper != MAP_E0 &&
       (!changed || b->queued[offset])) return 1;
   if (a->work_count == a->work_cap) {
      size_t new_cap = a->work_cap ? a->work_cap * 2u : 256u;
      nw = (work_item_t *)realloc(a->work, new_cap * sizeof(*nw));
      if (!nw) return 0;
      a->work = nw;
      a->work_cap = new_cap;
   }
   b->queued[offset] = 1;
   a->work[a->work_count].bank = bank;
   a->work[a->work_count].offset = offset;
   a->work[a->work_count].pc = pc;
   a->work[a->work_count].mapper_config = mapper_config;
   ++a->work_count;
   return 1;
}

static int push_work_state(analysis_t *a, size_t bank, size_t offset,
                           const abstract_state_t *state)
{
   uint16_t pc = (uint16_t)(a->banks[bank].origin + (uint16_t)offset);
   uint16_t config = a->mapper == MAP_E0 ? e0_seed_config(bank, pc) : 0u;
   return push_work_state_ctx(a, bank, offset, state, pc, config);
}

static int push_wd_address_state(analysis_t *a, uint8_t config,
                                 uint16_t address,
                                 const abstract_state_t *state)
{
   size_t bank, off;
   if (!wd_map_address(a, config, address, &bank, &off)) return 1;
   return push_work_state_ctx(a, bank, off, state, address, config);
}

static int push_e0_address_state(analysis_t *a, uint16_t config,
                                 uint16_t address,
                                 const abstract_state_t *state)
{
   size_t bank, off;
   if (!e0_map_address(a, config, address, &bank, &off)) return 1;
   return push_work_state_ctx(a, bank, off, state, address, config);
}

static int push_work(analysis_t *a, size_t bank, size_t offset)
{
   abstract_state_t state;
   memset(&state, 0, sizeof(state));
   return push_work_state(a, bank, offset, &state);
}

static int cart_target_offset(const bank_t *b, uint16_t address, size_t *off)
{
   uint16_t bus;
   if (!is_cart_address(address)) return 0;
   bus = (uint16_t)(address & 0x1fffu);
   /* CV devotes the lower half of the cartridge window to RAM; unlike a
    * conventional mirrored 2K ROM, its ROM exists only at $1800-$1FFF. */
   if (b->cv_fixed_upper_half && bus < 0x1800u) return 0;
   *off = (size_t)(address & (uint16_t)(b->size - 1u));
   return *off < b->size;
}

static int selector_bank(mapper_t mapper, uint16_t address, size_t *bank)
{
   uint16_t bus = (uint16_t)(address & 0x1fffu);
   switch (mapper) {
   case MAP_F8:
   case MAP_DPC:
      if (bus >= 0x1ff8u && bus <= 0x1ff9u) { *bank = bus - 0x1ff8u; return 1; }
      break;
   case MAP_F6:
      if (bus >= 0x1ff6u && bus <= 0x1ff9u) { *bank = bus - 0x1ff6u; return 1; }
      break;
   case MAP_F4:
      if (bus >= 0x1ff4u && bus <= 0x1ffbu) { *bank = bus - 0x1ff4u; return 1; }
      break;
   case MAP_FA:
      if (bus >= 0x1ff8u && bus <= 0x1ffau) { *bank = bus - 0x1ff8u; return 1; }
      break;
   case MAP_JANE:
      if (bus == 0x1ff0u) { *bank = 0u; return 1; }
      if (bus == 0x1ff1u) { *bank = 1u; return 1; }
      if (bus == 0x1ff8u) { *bank = 2u; return 1; }
      if (bus == 0x1ff9u) { *bank = 3u; return 1; }
      break;
   case MAP_0840:
      switch (bus & 0x1840u) {
      case 0x0800u: *bank = 0u; return 1;
      case 0x0840u: *bank = 1u; return 1;
      default: break;
      }
      break;
   case MAP_UA:
   case MAP_UASW:
      switch (bus & 0x1260u) {
      case 0x0220u: *bank = mapper == MAP_UASW ? 1u : 0u; return 1;
      case 0x0240u: *bank = mapper == MAP_UASW ? 0u : 1u; return 1;
      default: break;
      }
      break;
   case MAP_0FA0:
      switch (bus & 0x16e0u) {
      case 0x06a0u: *bank = 0u; return 1;
      case 0x06c0u: *bank = 1u; return 1;
      default: break;
      }
      break;
   default:
      break;
   }
   return 0;
}

static int resolve_zp_word(const abstract_state_t *state, uint8_t pointer,
                           uint16_t *value)
{
   uint8_t lo, hi;
   if (!state_zp_get(state, pointer, &lo) ||
       !state_zp_get(state, (uint8_t)(pointer + 1u), &hi))
      return 0;
   *value = (uint16_t)(lo | ((uint16_t)hi << 8));
   return 1;
}

static int resolve_effective_address(const abstract_state_t *state,
                                     address_mode_t mode, uint16_t operand,
                                     uint16_t *address)
{
   uint16_t pointer;
   switch (mode) {
   case AM_ZERO_PAGE:
      *address = (uint8_t)operand;
      return 1;
   case AM_ZERO_PAGE_X:
      if (!state->x_known) return 0;
      *address = (uint8_t)((uint8_t)operand + state->x);
      return 1;
   case AM_ZERO_PAGE_Y:
      if (!state->y_known) return 0;
      *address = (uint8_t)((uint8_t)operand + state->y);
      return 1;
   case AM_ABSOLUTE:
      *address = operand;
      return 1;
   case AM_ABSOLUTE_X:
      if (!state->x_known) return 0;
      *address = (uint16_t)(operand + state->x);
      return 1;
   case AM_ABSOLUTE_Y:
      if (!state->y_known) return 0;
      *address = (uint16_t)(operand + state->y);
      return 1;
   case AM_INDEXED_INDIRECT:
      if (!state->x_known ||
          !resolve_zp_word(state,
                           (uint8_t)((uint8_t)operand + state->x), &pointer))
         return 0;
      *address = pointer;
      return 1;
   case AM_INDIRECT_INDEXED:
      if (!resolve_zp_word(state, (uint8_t)operand, &pointer) ||
          !state->y_known)
         return 0;
      *address = (uint16_t)(pointer + state->y);
      return 1;
   default:
      return 0;
   }
}

/* Resolve a mapper selector from an instruction that actually performs a
 * memory access.  Keeping this in one place is important: ordinary recursive
 * tracing, speculative-island validation, and mapper-hypothesis testing all
 * need to agree about which physical bank supplies the *next* opcode fetch. */
static int instruction_selector_bank(const analysis_t *a,
                                     const abstract_state_t *state,
                                     uint8_t opcode, address_mode_t mode,
                                     uint16_t operand, size_t *bank)
{
   uint16_t effective;
   if (instruction_flow(opcode) != FLOW_NEXT) return 0;
   if (!(opcode_memory_access(opcode) & (ACCESS_READ | ACCESS_WRITE))) return 0;
   if (!resolve_effective_address(state, mode, operand, &effective)) return 0;
   return selector_bank(a->mapper, effective, bank);
}

static int superchip_active(const analysis_t *a)
{
   if (a->mapper_overridden && a->superchip_override >= 0)
      return a->superchip_override != 0;
   /* Reads from $x080-$x0FF are ambiguous with ordinary ROM accesses.
    * A decoded write into the Superchip write window is the discriminator:
    * useful SC RAM cannot be consumed without first being written. */
   return a->superchip_write_refs != 0;
}

static int fa_ram_address(const analysis_t *a, uint16_t address)
{
   uint16_t bus = (uint16_t)(address & 0x1fffu);
   return a->mapper == MAP_FA && bus >= 0x1000u && bus <= 0x11ffu;
}

static size_t rom_hidden_prefix(const analysis_t *a)
{
   if (a->mapper == MAP_FA) return 0x200u;
   if (superchip_active(a)) return 0x100u;
   return 0u;
}

static int rom_offset_hidden(const analysis_t *a, size_t off)
{
   return off < rom_hidden_prefix(a);
}

static int dpc_register_address(const analysis_t *a, uint16_t address)
{
   uint16_t bus = (uint16_t)(address & 0x1fffu);
   return a->mapper == MAP_DPC && bus >= 0x1000u && bus <= 0x107fu;
}

static int state_read_byte(const analysis_t *a, size_t bank,
                           const abstract_state_t *state, uint16_t address,
                           uint8_t *value)
{
   size_t off;
   if (address <= 0x00ffu)
      return state_zp_get(state, (uint8_t)address, value);
   if (a->mapper == MAP_WD || a->mapper == MAP_E0) return 0;
   if (bank >= a->bank_count || !cart_target_offset(&a->banks[bank], address, &off))
      return 0;
   if (dpc_register_address(a, address) || fa_ram_address(a, address)) return 0;
   /* Once Superchip evidence exists, its read window is RAM rather than ROM. */
   if (superchip_active(a) && ((address & 0x1fffu) >= 0x1080u) &&
       ((address & 0x1fffu) <= 0x10ffu))
      return 0;
   *value = a->rom[a->banks[bank].file_offset + off];
   return 1;
}

static int state_read_operand(const analysis_t *a, size_t bank,
                              const abstract_state_t *state,
                              address_mode_t mode, uint16_t operand,
                              uint8_t *value)
{
   uint16_t address;
   if (mode == AM_IMMEDIATE) {
      *value = (uint8_t)operand;
      return 1;
   }
   if (!resolve_effective_address(state, mode, operand, &address)) return 0;
   return state_read_byte(a, bank, state, address, value);
}

static int known_store_value(uint8_t opcode, const abstract_state_t *state,
                             uint8_t *value)
{
   const char *mnemonic = opcode_mnemonics[opcode];
   if (strcmp(mnemonic, "STA") == 0) {
      if (!state->a_known) return 0;
      *value = state->a;
      return 1;
   }
   if (strcmp(mnemonic, "STX") == 0) {
      if (!state->x_known) return 0;
      *value = state->x;
      return 1;
   }
   if (strcmp(mnemonic, "STY") == 0) {
      if (!state->y_known) return 0;
      *value = state->y;
      return 1;
   }
   return 0;
}

static void state_apply_memory_write(const abstract_state_t *input,
                                     abstract_state_t *output,
                                     uint8_t opcode, address_mode_t mode,
                                     uint16_t operand)
{
   uint16_t address;
   uint8_t value;
   unsigned access = opcode_memory_access(opcode);
   if (!(access & ACCESS_WRITE)) return;
   if (!resolve_effective_address(input, mode, operand, &address)) {
      if (mode == AM_ZERO_PAGE_X || mode == AM_ZERO_PAGE_Y ||
          mode == AM_INDEXED_INDIRECT || mode == AM_INDIRECT_INDEXED)
         state_zp_set_all_unknown(output);
      return;
   }
   if (address > 0x00ffu) return;
   if ((access & ACCESS_READ) || !known_store_value(opcode, input, &value))
      state_zp_set_unknown(output, (uint8_t)address);
   else
      state_zp_set_known(output, (uint8_t)address, value);
}

static void state_set_nz(abstract_state_t *state, int known, uint8_t value)
{
   state->zero_known = (uint8_t)(known != 0);
   state->negative_known = (uint8_t)(known != 0);
   if (known) {
      state->zero = (uint8_t)(value == 0u);
      state->negative = (uint8_t)((value & 0x80u) != 0u);
   }
}

static int mnemonic_affects_carry(const char *m)
{
   return strcmp(m,"ADC") == 0 || strcmp(m,"SBC") == 0 ||
          strcmp(m,"CMP") == 0 || strcmp(m,"CPX") == 0 ||
          strcmp(m,"CPY") == 0 || strcmp(m,"ASL") == 0 ||
          strcmp(m,"LSR") == 0 || strcmp(m,"ROL") == 0 ||
          strcmp(m,"ROR") == 0 || strcmp(m,"CLC") == 0 ||
          strcmp(m,"SEC") == 0 || strcmp(m,"PLP") == 0 ||
          strcmp(m,"RTI") == 0;
}

static void transfer_state(const analysis_t *a, size_t bank,
                           const abstract_state_t *input,
                           abstract_state_t *output, uint8_t opcode,
                           address_mode_t mode, uint16_t operand)
{
   const char *m = opcode_mnemonics[opcode];
   uint8_t value;
   *output = *input;
   state_apply_memory_write(input, output, opcode, mode, operand);

   /* Unofficial encodings are deliberately treated as opaque for abstract
    * register state.  Exact disassembly still uses the generated opcode table. */
   if (strncmp(m, "op", 2) == 0) {
      output->a_known = output->x_known = output->y_known = 0;
      output->carry_known = 0;
      output->zero_known = output->negative_known = output->overflow_known = 0;
      return;
   }

   if (mnemonic_affects_carry(m)) output->carry_known = 0;

   if (strcmp(m,"LDA") == 0) {
      if (state_read_operand(a, bank, input, mode, operand, &value)) {
         output->a_known = 1; output->a = value;
         state_set_nz(output, 1, value);
      } else { output->a_known = 0; state_set_nz(output, 0, 0); }
   }
   else if (strcmp(m,"LDX") == 0) {
      if (state_read_operand(a, bank, input, mode, operand, &value)) {
         output->x_known = 1; output->x = value;
         state_set_nz(output, 1, value);
      } else { output->x_known = 0; state_set_nz(output, 0, 0); }
   }
   else if (strcmp(m,"LDY") == 0) {
      if (state_read_operand(a, bank, input, mode, operand, &value)) {
         output->y_known = 1; output->y = value;
         state_set_nz(output, 1, value);
      } else { output->y_known = 0; state_set_nz(output, 0, 0); }
   }
   else if (strcmp(m,"TAX") == 0) {
      output->x_known = input->a_known; output->x = input->a;
      state_set_nz(output, input->a_known, input->a);
   }
   else if (strcmp(m,"TAY") == 0) {
      output->y_known = input->a_known; output->y = input->a;
      state_set_nz(output, input->a_known, input->a);
   }
   else if (strcmp(m,"TXA") == 0) {
      output->a_known = input->x_known; output->a = input->x;
      state_set_nz(output, input->x_known, input->x);
   }
   else if (strcmp(m,"TYA") == 0) {
      output->a_known = input->y_known; output->a = input->y;
      state_set_nz(output, input->y_known, input->y);
   }
   else if (strcmp(m,"TSX") == 0) output->x_known = 0;
   else if (strcmp(m,"PLA") == 0) { output->a_known = 0; state_set_nz(output, 0, 0); }
   else if (strcmp(m,"INX") == 0) {
      if (input->x_known) { output->x_known = 1; output->x = (uint8_t)(input->x + 1u); state_set_nz(output, 1, output->x); }
      else { output->x_known = 0; state_set_nz(output, 0, 0); }
   }
   else if (strcmp(m,"DEX") == 0) {
      if (input->x_known) { output->x_known = 1; output->x = (uint8_t)(input->x - 1u); state_set_nz(output, 1, output->x); }
      else { output->x_known = 0; state_set_nz(output, 0, 0); }
   }
   else if (strcmp(m,"INY") == 0) {
      if (input->y_known) { output->y_known = 1; output->y = (uint8_t)(input->y + 1u); state_set_nz(output, 1, output->y); }
      else { output->y_known = 0; state_set_nz(output, 0, 0); }
   }
   else if (strcmp(m,"DEY") == 0) {
      if (input->y_known) { output->y_known = 1; output->y = (uint8_t)(input->y - 1u); state_set_nz(output, 1, output->y); }
      else { output->y_known = 0; state_set_nz(output, 0, 0); }
   }
   else if (strcmp(m,"CLC") == 0) { output->carry_known = 1; output->carry = 0; }
   else if (strcmp(m,"SEC") == 0) { output->carry_known = 1; output->carry = 1; }
   else if (strcmp(m,"CLD") == 0) { output->decimal_known = 1; output->decimal = 0; }
   else if (strcmp(m,"SED") == 0) { output->decimal_known = 1; output->decimal = 1; }
   else if (strcmp(m,"CLV") == 0) { output->overflow_known = 1; output->overflow = 0; }
   else if (strcmp(m,"PLP") == 0 || strcmp(m,"RTI") == 0) {
      output->carry_known = output->zero_known = output->negative_known = 0;
      output->overflow_known = output->decimal_known = 0;
   }
   else if (strcmp(m,"AND") == 0 || strcmp(m,"ORA") == 0 ||
            strcmp(m,"EOR") == 0) {
      if (input->a_known && state_read_operand(a, bank, input, mode, operand, &value)) {
         output->a_known = 1;
         if (strcmp(m,"AND") == 0) output->a = (uint8_t)(input->a & value);
         else if (strcmp(m,"ORA") == 0) output->a = (uint8_t)(input->a | value);
         else output->a = (uint8_t)(input->a ^ value);
         state_set_nz(output, 1, output->a);
      }
      else { output->a_known = 0; state_set_nz(output, 0, 0); }
   }
   else if (strcmp(m,"ADC") == 0 || strcmp(m,"SBC") == 0) {
      if (input->a_known && input->carry_known && input->decimal_known &&
          !input->decimal && state_read_operand(a, bank, input, mode, operand, &value)) {
         unsigned sum;
         if (strcmp(m,"ADC") == 0)
            sum = (unsigned)input->a + (unsigned)value + (unsigned)input->carry;
         else
            sum = (unsigned)input->a + (unsigned)(uint8_t)~value + (unsigned)input->carry;
         output->a_known = 1; output->a = (uint8_t)sum;
         output->carry_known = 1; output->carry = sum > 0xffu;
         state_set_nz(output, 1, output->a);
         output->overflow_known = 1;
         if (strcmp(m,"ADC") == 0)
            output->overflow = (uint8_t)(((~(input->a ^ value) & (input->a ^ output->a)) & 0x80u) != 0u);
         else
            output->overflow = (uint8_t)((((input->a ^ value) & (input->a ^ output->a)) & 0x80u) != 0u);
      }
      else { output->a_known = 0; output->carry_known = 0; output->overflow_known = 0; state_set_nz(output, 0, 0); }
   }
   else if ((strcmp(m,"ASL") == 0 || strcmp(m,"LSR") == 0 ||
             strcmp(m,"ROL") == 0 || strcmp(m,"ROR") == 0) &&
            mode == AM_ACCUMULATOR) {
      if (input->a_known &&
          ((strcmp(m,"ROL") != 0 && strcmp(m,"ROR") != 0) || input->carry_known)) {
         uint8_t old = input->a;
         output->a_known = 1;
         output->carry_known = 1;
         if (strcmp(m,"ASL") == 0) { output->carry = old >> 7; output->a = (uint8_t)(old << 1); }
         else if (strcmp(m,"LSR") == 0) { output->carry = old & 1u; output->a = (uint8_t)(old >> 1); }
         else if (strcmp(m,"ROL") == 0) { output->carry = old >> 7; output->a = (uint8_t)((old << 1) | input->carry); }
         else { output->carry = old & 1u; output->a = (uint8_t)((old >> 1) | (input->carry << 7)); }
         state_set_nz(output, 1, output->a);
      }
      else { output->a_known = 0; output->carry_known = 0; state_set_nz(output, 0, 0); }
   }
   else if (strcmp(m,"CMP") == 0 || strcmp(m,"CPX") == 0 || strcmp(m,"CPY") == 0) {
      uint8_t reg = 0;
      int known = strcmp(m,"CMP") == 0 ? input->a_known :
                  strcmp(m,"CPX") == 0 ? input->x_known : input->y_known;
      if (strcmp(m,"CMP") == 0) reg = input->a;
      else if (strcmp(m,"CPX") == 0) reg = input->x;
      else reg = input->y;
      if (known && state_read_operand(a, bank, input, mode, operand, &value)) {
         uint8_t diff = (uint8_t)(reg - value);
         output->carry_known = 1; output->carry = reg >= value;
         output->zero_known = 1; output->zero = reg == value;
         output->negative_known = 1; output->negative = (uint8_t)((diff & 0x80u) != 0u);
      }
      else state_set_nz(output, 0, 0);
   }
   else if (strcmp(m,"BIT") == 0) {
      if (state_read_operand(a, bank, input, mode, operand, &value)) {
         output->negative_known = 1; output->negative = (uint8_t)((value & 0x80u) != 0u);
         output->overflow_known = 1; output->overflow = (uint8_t)((value & 0x40u) != 0u);
         if (input->a_known) { output->zero_known = 1; output->zero = (uint8_t)((input->a & value) == 0u); }
         else output->zero_known = 0;
      }
      else output->zero_known = output->negative_known = output->overflow_known = 0;
   }
   else if (strcmp(m,"INC") == 0 || strcmp(m,"DEC") == 0) {
      if (state_read_operand(a, bank, input, mode, operand, &value)) {
         uint8_t changed = strcmp(m,"INC") == 0 ? (uint8_t)(value + 1u) : (uint8_t)(value - 1u);
         state_set_nz(output, 1, changed);
      }
      else state_set_nz(output, 0, 0);
   }
}

static void mark_instruction(bank_t *b, size_t off, uint8_t opcode,
                             unsigned len)
{
   unsigned i;
   b->roles[off] |= ROLE_CODE_START | ROLE_CODE_BYTE;
   b->inst_len[off] = (uint8_t)len;
   b->inst_opcode[off] = opcode;
   for (i = 1; i < len && off + i < b->size; ++i)
      b->roles[off+i] |= ROLE_CODE_BYTE | ROLE_OPERAND;
}

static void mark_label(bank_t *b, size_t off)
{
   if (off < b->size) b->roles[off] |= ROLE_LABEL;
}

static void detect_overlaps(analysis_t *a)
{
   size_t bi;
   for (bi = 0; bi < a->bank_count; ++bi) {
      bank_t *b = &a->banks[bi];
      size_t i;
      for (i = 0; i < b->size; ++i) {
         unsigned len;
         size_t j;
         if (!(b->roles[i] & ROLE_CODE_START)) continue;
         len = b->inst_len[i];
         for (j = i + 1u; j < b->size && j < i + len; ++j) {
            if (b->roles[j] & ROLE_CODE_START) {
               size_t k;
               for (k = i; k < b->size && k < i + len; ++k)
                  b->roles[k] |= ROLE_OVERLAP;
               for (k = j; k < b->size && k < j + b->inst_len[j]; ++k)
                  b->roles[k] |= ROLE_OVERLAP;
            }
         }
      }
   }
}

typedef enum {
   SPEC_SAFE_WEAK,
   SPEC_SAFE_STRONG,
   SPEC_REJECT
} spec_result_t;

typedef struct {
   uint8_t *visiting;
   uint8_t *counted;
   size_t steps;
   size_t step_limit;
   size_t instructions;
   size_t official_instructions;
   size_t unofficial_instructions;
   size_t control_transfers;
   size_t mapper_switches;
   size_t switch_avoided_halts;
   size_t terminals;
   size_t unresolved_terminals;
   size_t joins;
   int strict_conflicts;
} spec_context_t;

static spec_result_t spec_safe_merge(spec_result_t a, spec_result_t b)
{
   if (a == SPEC_REJECT || b == SPEC_REJECT) return SPEC_REJECT;
   if (a == SPEC_SAFE_STRONG || b == SPEC_SAFE_STRONG) return SPEC_SAFE_STRONG;
   return SPEC_SAFE_WEAK;
}

static int speculative_branch_outcome(uint8_t opcode,
                                      const abstract_state_t *state,
                                      int *taken)
{
   switch (opcode) {
   case 0x10: if (!state->negative_known) return 0; *taken = state->negative == 0u; return 1; /* BPL */
   case 0x30: if (!state->negative_known) return 0; *taken = state->negative != 0u; return 1; /* BMI */
   case 0x50: if (!state->overflow_known) return 0; *taken = state->overflow == 0u; return 1; /* BVC */
   case 0x70: if (!state->overflow_known) return 0; *taken = state->overflow != 0u; return 1; /* BVS */
   case 0x90: if (!state->carry_known) return 0; *taken = state->carry == 0u; return 1; /* BCC */
   case 0xb0: if (!state->carry_known) return 0; *taken = state->carry != 0u; return 1; /* BCS */
   case 0xd0: if (!state->zero_known) return 0; *taken = state->zero == 0u; return 1; /* BNE */
   case 0xf0: if (!state->zero_known) return 0; *taken = state->zero != 0u; return 1; /* BEQ */
   default: return 0;
   }
}

static spec_result_t speculative_flow_ctx(const analysis_t *a, size_t bi,
                                          size_t off, uint16_t runtime_pc,
                                          uint16_t mapper_config,
                                          const abstract_state_t *input_state,
                                          spec_context_t *ctx)
{
   const bank_t *b = &a->banks[bi];
   size_t node;
   uint8_t opcode;
   address_mode_t mode;
   unsigned len;
   uint16_t operand = 0;
   uint16_t canonical_pc;
   abstract_state_t output_state;
   flow_kind_t flow;
   spec_result_t result = SPEC_SAFE_WEAK;
   size_t successor_bank = bi;
   int switched = 0;
   int e0_switched = 0;
   uint16_t e0_successor_config = mapper_config;

   if (off >= b->size) return SPEC_SAFE_WEAK;
   if (rom_offset_hidden(a, off)) return SPEC_SAFE_WEAK;

   /* Established control flow is authoritative, even if it deliberately
    * reaches a CPU-locking opcode.  The JAM/KIL rule applies only to newly
    * speculative decoding. */
   if (b->roles[off] & ROLE_CODE_START) {
      if (ctx->counted) ++ctx->joins;
      return SPEC_SAFE_WEAK;
   }

   if (ctx->strict_conflicts &&
       (b->roles[off] & (ROLE_CODE_BYTE | ROLE_DATA_READ | ROLE_POSSIBLE | ROLE_VECTOR)))
      return SPEC_REJECT;

   if (++ctx->steps > ctx->step_limit) return SPEC_SAFE_WEAK;
   node = b->file_offset + off;
   if (ctx->visiting[node]) return SPEC_SAFE_WEAK; /* legitimate loop */

   opcode = a->rom[b->file_offset + off];
   if (opcode_is_cpu_halt(opcode)) return SPEC_REJECT;

   mode = (address_mode_t)opcode_modes[opcode];
   len = instruction_length(mode);
   if (len == 0u || off + len > b->size) return SPEC_SAFE_WEAK;
   if (ctx->strict_conflicts) {
      unsigned i;
      for (i = 1u; i < len; ++i) {
         uint8_t rr = b->roles[off + i];
         if (rr & (ROLE_CODE_START | ROLE_DATA_READ | ROLE_POSSIBLE | ROLE_VECTOR))
            return SPEC_REJECT;
      }
   }
   if (ctx->counted && !ctx->counted[node]) {
      ctx->counted[node] = 1u;
      ++ctx->instructions;
      if (strncmp(opcode_mnemonics[opcode], "op", 2) == 0)
         ++ctx->unofficial_instructions;
      else
         ++ctx->official_instructions;
   }
   if (len >= 2u) operand = a->rom[b->file_offset + off + 1u];
   if (len >= 3u) operand |= (uint16_t)a->rom[b->file_offset + off + 2u] << 8;
   canonical_pc = a->mapper == MAP_E0 ? runtime_pc
                                      : (uint16_t)(b->origin + (uint16_t)off);
   transfer_state(a, bi, input_state, &output_state, opcode, mode, operand);
   flow = instruction_flow(opcode);
   if (flow == FLOW_NEXT && a->mapper == MAP_E0 &&
       (opcode_memory_access(opcode) & (ACCESS_READ | ACCESS_WRITE))) {
      uint16_t effective;
      if (resolve_effective_address(input_state, mode, operand, &effective) &&
          e0_selector_config(effective, mapper_config, &e0_successor_config)) {
         e0_switched = 1;
         if (ctx->counted) ++ctx->mapper_switches;
      }
   }
   else if (flow == FLOW_NEXT &&
            instruction_selector_bank(a, input_state, opcode, mode, operand,
                                      &successor_bank) &&
            successor_bank < a->bank_count) {
      switched = 1;
      if (ctx->counted) ++ctx->mapper_switches;
   }

   ctx->visiting[node] = 1u;
   switch (flow) {
   case FLOW_NEXT:
      if (a->mapper == MAP_E0) {
         uint16_t next_pc = (uint16_t)(canonical_pc + len);
         uint16_t next_config = e0_switched ? e0_successor_config : mapper_config;
         size_t next_bank, next_off;
         if (e0_map_address(a, next_config, next_pc, &next_bank, &next_off)) {
            size_t old_bank, old_off;
            if (e0_switched &&
                e0_map_address(a, mapper_config, next_pc, &old_bank, &old_off) &&
                old_bank != next_bank &&
                opcode_is_cpu_halt(a->rom[a->banks[old_bank].file_offset + old_off]) &&
                !opcode_is_cpu_halt(a->rom[a->banks[next_bank].file_offset + next_off]))
               ++ctx->switch_avoided_halts;
            result = speculative_flow_ctx(a, next_bank, next_off, next_pc,
                                          next_config, &output_state, ctx);
         }
         else
            result = SPEC_SAFE_WEAK;
      }
      else if (off + len < b->size) {
         if (switched && successor_bank != bi &&
             opcode_is_cpu_halt(a->rom[b->file_offset + off + len]) &&
             !opcode_is_cpu_halt(a->rom[a->banks[successor_bank].file_offset + off + len]))
            ++ctx->switch_avoided_halts;
         result = speculative_flow_ctx(a, switched ? successor_bank : bi,
                                       off + len,
                                       (uint16_t)(a->banks[switched ? successor_bank : bi].origin +
                                                  (uint16_t)(off + len)),
                                       0u, &output_state, ctx);
      }
      else
         result = SPEC_SAFE_WEAK;
      break;

   case FLOW_BRANCH: {
      if (ctx->counted) ++ctx->control_transfers;
      int8_t disp = (int8_t)(uint8_t)operand;
      uint16_t target = (uint16_t)(canonical_pc + 2u + disp);
      int known = 0, taken = 0;
      spec_result_t fall = SPEC_SAFE_WEAK, branch = SPEC_SAFE_WEAK;

      known = speculative_branch_outcome(opcode, &output_state, &taken);
      if (a->mapper == MAP_E0) {
         if (!known || !taken) {
            uint16_t fall_pc = (uint16_t)(canonical_pc + 2u);
            size_t fbank, foff;
            if (e0_map_address(a, mapper_config, fall_pc, &fbank, &foff))
               fall = speculative_flow_ctx(a, fbank, foff, fall_pc,
                                           mapper_config, &output_state, ctx);
            if (fall == SPEC_REJECT) { result = SPEC_REJECT; break; }
         }
         if (!known || taken) {
            size_t tbank, toff;
            if (e0_map_address(a, mapper_config, target, &tbank, &toff))
               branch = speculative_flow_ctx(a, tbank, toff, target,
                                             mapper_config, &output_state, ctx);
            if (branch == SPEC_REJECT) { result = SPEC_REJECT; break; }
         }
      }
      else {
         size_t toff = 0;
         int target_local = target >= b->origin &&
            (uint32_t)target < (uint32_t)b->origin + (uint32_t)b->size;
         if (!known || !taken) {
            if (off + 2u < b->size)
               fall = speculative_flow_ctx(a, bi, off + 2u,
                                           (uint16_t)(canonical_pc + 2u), 0u,
                                           &output_state, ctx);
            if (fall == SPEC_REJECT) { result = SPEC_REJECT; break; }
         }
         if (!known || taken) {
            if (target_local) {
               toff = (size_t)(target - b->origin);
               if (!(rom_offset_hidden(a, toff)))
                  branch = speculative_flow_ctx(a, bi, toff, target, 0u,
                                                &output_state, ctx);
            }
            if (branch == SPEC_REJECT) { result = SPEC_REJECT; break; }
         }
      }
      result = known ? (taken ? branch : fall) : spec_safe_merge(fall, branch);
      break;
   }

   case FLOW_JSR: {
      if (ctx->counted) ++ctx->control_transfers;
      spec_result_t called = SPEC_SAFE_WEAK;
      spec_result_t cont = SPEC_SAFE_WEAK;
      abstract_state_t after_call;
      memset(&after_call, 0, sizeof(after_call));

      if (a->mapper == MAP_E0) {
         size_t tbank, toff, cbank, coff;
         uint16_t cont_pc = (uint16_t)(canonical_pc + 3u);
         if (e0_map_address(a, mapper_config, operand, &tbank, &toff))
            called = speculative_flow_ctx(a, tbank, toff, operand,
                                          mapper_config, &output_state, ctx);
         if (called == SPEC_REJECT) { result = SPEC_REJECT; break; }
         if (e0_map_address(a, mapper_config, cont_pc, &cbank, &coff))
            cont = speculative_flow_ctx(a, cbank, coff, cont_pc,
                                        mapper_config, &after_call, ctx);
      }
      else {
         size_t toff;
         if (cart_target_offset(b, operand, &toff) &&
             !(rom_offset_hidden(a, toff)))
            called = speculative_flow_ctx(a, bi, toff, operand, 0u,
                                          &output_state, ctx);
         if (called == SPEC_REJECT) { result = SPEC_REJECT; break; }
         if (off + 3u < b->size)
            cont = speculative_flow_ctx(a, bi, off + 3u,
                                        (uint16_t)(canonical_pc + 3u), 0u,
                                        &after_call, ctx);
      }
      result = spec_safe_merge(called, cont);
      break;
   }

   case FLOW_JMP_ABSOLUTE:
      if (ctx->counted) { ++ctx->control_transfers; ++ctx->terminals; }
      /* A local speculative island has reached an ordinary hard terminator.
       * JMP targets are analyzed independently; per the island rule the local
       * linear candidate succeeds here. */
      result = SPEC_SAFE_STRONG;
      break;

   case FLOW_JMP_INDIRECT:
      if (ctx->counted) {
         ++ctx->control_transfers;
         ++ctx->terminals;
         ++ctx->unresolved_terminals;
      }
      result = SPEC_SAFE_STRONG;
      break;

   case FLOW_RTS:
      if (ctx->counted) ++ctx->terminals;
      result = SPEC_SAFE_STRONG;
      break;

   case FLOW_STOP:
      if (ctx->counted) ++ctx->terminals;
      /* HLT/JAM/KIL was handled before entering the switch.  BRK and RTI are
       * legitimate terminating instructions for speculative validation. */
      result = SPEC_SAFE_STRONG;
      break;
   }
   ctx->visiting[node] = 0u;
   return result;
}

static spec_result_t speculative_flow(const analysis_t *a, size_t bi,
                                      size_t off,
                                      const abstract_state_t *input_state,
                                      spec_context_t *ctx)
{
   uint16_t pc = (uint16_t)(a->banks[bi].origin + (uint16_t)off);
   uint16_t config = 0u;
   if (a->mapper == MAP_E0) config = e0_seed_config(bi, pc);
   return speculative_flow_ctx(a, bi, off, pc, config, input_state, ctx);
}

static int speculative_linear_jam_end(const analysis_t *a, size_t bi,
                                      size_t start, uint16_t *end_out)
{
   const bank_t *b = &a->banks[bi];
   abstract_state_t state;
   size_t off = start;
   size_t steps = 0;
   uint16_t pc = (uint16_t)(b->origin + (uint16_t)start);
   uint16_t mapper_config = a->mapper == MAP_E0 ? e0_seed_config(bi, pc) : 0u;
   memset(&state, 0, sizeof(state));

   while (off < b->size && steps++ < 512u) {
      uint8_t opcode;
      address_mode_t mode;
      unsigned len;
      uint16_t operand = 0;
      abstract_state_t next;
      flow_kind_t flow;

      if (rom_offset_hidden(a, off)) return 0;
      if (b->roles[off] & ROLE_CODE_START) return 0;
      opcode = a->rom[b->file_offset + off];
      if (opcode_is_cpu_halt(opcode)) {
         *end_out = (uint16_t)off;
         return 1;
      }
      mode = (address_mode_t)opcode_modes[opcode];
      len = instruction_length(mode);
      if (len == 0u || off + len > b->size) return 0;
      if (len >= 2u) operand = a->rom[b->file_offset + off + 1u];
      if (len >= 3u) operand |= (uint16_t)a->rom[b->file_offset + off + 2u] << 8;
      transfer_state(a, bi, &state, &next, opcode, mode, operand);
      flow = instruction_flow(opcode);

      if (flow == FLOW_NEXT) {
         if (a->mapper == MAP_E0) {
            uint16_t next_pc = (uint16_t)(pc + len);
            uint16_t next_config = mapper_config;
            uint16_t effective;
            size_t next_bank, next_off;
            if ((opcode_memory_access(opcode) & (ACCESS_READ | ACCESS_WRITE)) &&
                resolve_effective_address(&state, mode, operand, &effective))
               (void)e0_selector_config(effective, mapper_config, &next_config);
            if (!e0_map_address(a, next_config, next_pc, &next_bank, &next_off) ||
                next_bank != bi)
               return 0;
            state = next;
            mapper_config = next_config;
            pc = next_pc;
            off = next_off;
            continue;
         }
         else {
            size_t successor_bank = bi;
            if (instruction_selector_bank(a, &state, opcode, mode, operand,
                                          &successor_bank) &&
                successor_bank != bi)
               return 0;
            state = next;
            off += len;
            continue;
         }
      }
      if (flow == FLOW_BRANCH) {
         int known = 0, taken = 0;
         known = speculative_branch_outcome(opcode, &next, &taken);
         /* Only a proved not-taken branch remains a straight-line decode.
          * A taken/unknown branch makes the interval between start and a later
          * JAM non-contiguous, so it cannot justify the user's "everything up
          * to the JAM is non-code" barrier span. */
         if (known && !taken) {
            state = next;
            off += 2u;
            continue;
         }
      }
      return 0;
   }
   return 0;
}

static size_t speculative_inbound_references(const analysis_t *a,
                                             size_t bi, size_t target_off)
{
   const bank_t *b = &a->banks[bi];
   uint16_t target_addr = (uint16_t)(b->origin + (uint16_t)target_off);
   size_t off, count = 0;
   for (off = 0; off < b->size; ++off) {
      uint8_t opcode = a->rom[b->file_offset + off];
      address_mode_t mode = (address_mode_t)opcode_modes[opcode];
      unsigned len = instruction_length(mode);
      flow_kind_t flow;
      uint16_t operand = 0;
      uint16_t dest;
      if (off + len > b->size) continue;
      flow = instruction_flow(opcode);
      if (flow == FLOW_BRANCH) {
         dest = (uint16_t)(b->origin + (uint16_t)off + 2u +
                          (int8_t)a->rom[b->file_offset + off + 1u]);
      }
      else if (flow == FLOW_JSR || flow == FLOW_JMP_ABSOLUTE) {
         if (len < 3u) continue;
         operand = (uint16_t)(a->rom[b->file_offset + off + 1u] |
                   ((uint16_t)a->rom[b->file_offset + off + 2u] << 8));
         dest = operand;
      }
      else continue;
      if (dest == target_addr) ++count;
   }
   return count;
}

static int speculative_candidate_credible(const analysis_t *a,
                                          size_t bi, size_t off,
                                          size_t *switch_saves_out)
{
   const bank_t *b = &a->banks[bi];
   uint8_t *scratch = NULL;
   uint8_t *counted = NULL;
   abstract_state_t initial;
   spec_context_t ctx;
   spec_result_t result;
   size_t inbound;
   size_t allowed_unofficial;
   int credible = 0;
   if (switch_saves_out) *switch_saves_out = 0u;

   scratch = (uint8_t *)calloc(a->rom_size, 1);
   counted = (uint8_t *)calloc(a->rom_size, 1);
   if (!scratch || !counted) goto done;
   memset(&initial, 0, sizeof(initial));
   memset(&ctx, 0, sizeof(ctx));
   ctx.visiting = scratch;
   ctx.counted = counted;
   ctx.step_limit = b->size < 256u ? b->size * 2u : 512u;
   ctx.strict_conflicts = 1;
   result = speculative_flow(a, bi, off, &initial, &ctx);
   if (result != SPEC_SAFE_STRONG || ctx.instructions < 4u) goto done;
   /* For segmented E0, an unreferenced physical 1K chunk has no unique
    * runtime address/configuration.  Promote only speculative routines that
    * actually exercise an E0 selector; those are the bank-aware islands whose
    * validity can contribute mapper evidence without manufacturing dozens of
    * ordinary-code islands from an arbitrary presentation mapping. */
   if (a->mapper == MAP_E0 && ctx.mapper_switches == 0u) goto done;
   if (ctx.terminals == 0u && ctx.joins == 0u) goto done;
   if (ctx.unresolved_terminals != 0u &&
       ctx.terminals == ctx.unresolved_terminals && ctx.joins == 0u)
      goto done;

   allowed_unofficial = ctx.instructions / 10u;
   if (allowed_unofficial < 1u) allowed_unofficial = 1u;
   if (ctx.unofficial_instructions > allowed_unofficial) goto done;
   if (ctx.official_instructions * 100u < ctx.instructions * 80u) goto done;

   inbound = speculative_inbound_references(a, bi, off);
   if (inbound == 0u && ctx.control_transfers == 0u && ctx.instructions < 8u)
      goto done;
   credible = 1;
   if (switch_saves_out) *switch_saves_out = ctx.switch_avoided_halts;

done:
   free(scratch);
   free(counted);
   return credible;
}

typedef struct {
   size_t from;
   size_t next;
} spec_reverse_edge_t;

static int spec_reverse_add_edge(size_t *heads, spec_reverse_edge_t *edges,
                                 size_t edge_cap, size_t *edge_count,
                                 size_t from, size_t to)
{
   if (*edge_count >= edge_cap) return 0;
   edges[*edge_count].from = from;
   edges[*edge_count].next = heads[to];
   heads[to] = *edge_count;
   ++*edge_count;
   return 1;
}

/* Fast structural prefilter for the expensive stateful JAM/KIL walk.  Build
 * the speculative control-flow graph once, reverse it, and mark only starts
 * from which a halt opcode is structurally reachable.  Branch-state analysis
 * still gets the final say, so a structurally reachable but provably dead halt
 * arm is not rejected. */
static uint8_t *speculative_halt_reachability(const analysis_t *a)
{
   size_t n = a->rom_size;
   uint8_t *may = NULL;
   size_t *heads = NULL;
   spec_reverse_edge_t *edges = NULL;
   size_t *queue = NULL;
   size_t edge_count = 0u;
   size_t qhead = 0u, qtail = 0u;
   size_t bi;

   may = (uint8_t *)calloc(n, 1);
   heads = (size_t *)malloc(n * sizeof(*heads));
   edges = (spec_reverse_edge_t *)malloc((n * 2u + 1u) * sizeof(*edges));
   queue = (size_t *)malloc(n * sizeof(*queue));
   if (!may || !heads || !edges || !queue) goto fail;
   for (bi = 0; bi < n; ++bi) heads[bi] = SIZE_MAX;

   for (bi = 0; bi < a->bank_count; ++bi) {
      const bank_t *b = &a->banks[bi];
      size_t off;
      for (off = 0; off < b->size; ++off) {
         size_t node = b->file_offset + off;
         uint8_t opcode;
         address_mode_t mode;
         unsigned len;
         flow_kind_t flow;
         uint16_t operand = 0;
         if (b->roles[off] & ROLE_CODE_START) continue;
         if (rom_offset_hidden(a, off)) continue;
         opcode = a->rom[node];
         if (opcode_is_cpu_halt(opcode)) {
            may[node] = 1u;
            queue[qtail++] = node;
            continue;
         }
         mode = (address_mode_t)opcode_modes[opcode];
         len = instruction_length(mode);
         if (len == 0u || off + len > b->size) continue;
         if (len >= 2u) operand = a->rom[node + 1u];
         if (len >= 3u) operand |= (uint16_t)a->rom[node + 2u] << 8;
         flow = instruction_flow(opcode);
         if (flow == FLOW_NEXT) {
            size_t successor_bank = bi;
            size_t tooff = off + len;
            size_t to;
            /* The structural prefilter has no incoming abstract register
             * state, so only directly encoded absolute selector accesses are
             * recognized here.  Missing an indexed selector merely makes the
             * prefilter conservative; speculative_flow() does the stateful
             * final check. */
            if (mode == AM_ABSOLUTE &&
                selector_bank(a->mapper, operand, &successor_bank) &&
                successor_bank >= a->bank_count)
               successor_bank = bi;
            if (tooff < a->banks[successor_bank].size &&
                !(a->banks[successor_bank].roles[tooff] & ROLE_CODE_START) &&
                !(rom_offset_hidden(a, tooff))) {
               to = a->banks[successor_bank].file_offset + tooff;
               if (!spec_reverse_add_edge(heads, edges, n * 2u + 1u,
                                          &edge_count, node, to))
                  goto fail;
            }
         }
         else if (flow == FLOW_BRANCH) {
            size_t fall = off + 2u;
            int8_t disp = (int8_t)(uint8_t)operand;
            uint16_t pc = (uint16_t)(b->origin + (uint16_t)off);
            uint16_t target = (uint16_t)(pc + 2u + disp);
            if (fall < b->size && !(b->roles[fall] & ROLE_CODE_START) &&
                !(rom_offset_hidden(a, fall))) {
               size_t to = b->file_offset + fall;
               if (!spec_reverse_add_edge(heads, edges, n * 2u + 1u,
                                          &edge_count, node, to))
                  goto fail;
            }
            if (target >= b->origin &&
                (uint32_t)target < (uint32_t)b->origin + (uint32_t)b->size) {
               size_t tooff = (size_t)(target - b->origin);
               if (!(b->roles[tooff] & ROLE_CODE_START) &&
                   !(rom_offset_hidden(a, tooff))) {
                  size_t to = b->file_offset + tooff;
                  if (!spec_reverse_add_edge(heads, edges, n * 2u + 1u,
                                             &edge_count, node, to))
                     goto fail;
               }
            }
         }
         else if (flow == FLOW_JSR) {
            size_t tooff;
            size_t cont = off + 3u;
            if (cont < b->size && !(b->roles[cont] & ROLE_CODE_START) &&
                !(rom_offset_hidden(a, cont))) {
               size_t to = b->file_offset + cont;
               if (!spec_reverse_add_edge(heads, edges, n * 2u + 1u,
                                          &edge_count, node, to))
                  goto fail;
            }
            if (cart_target_offset(b, operand, &tooff) &&
                !(b->roles[tooff] & ROLE_CODE_START) &&
                !(rom_offset_hidden(a, tooff))) {
               size_t to = b->file_offset + tooff;
               if (!spec_reverse_add_edge(heads, edges, n * 2u + 1u,
                                          &edge_count, node, to))
                  goto fail;
            }
         }
         /* JMP/RTS/RTI/BRK terminate the local speculative candidate exactly
          * as speculative_flow() does, so no reverse edge crosses them. */
      }
   }

   while (qhead < qtail) {
      size_t to = queue[qhead++];
      size_t ei;
      for (ei = heads[to]; ei != SIZE_MAX; ei = edges[ei].next) {
         size_t from = edges[ei].from;
         if (!may[from]) {
            may[from] = 1u;
            queue[qtail++] = from;
         }
      }
   }

   free(heads);
   free(edges);
   free(queue);
   return may;

fail:
   free(may);
   free(heads);
   free(edges);
   free(queue);
   return NULL;
}

static int speculative_candidate_promotable(const analysis_t *a,
                                             size_t bi, size_t off,
                                             size_t *switch_saves_out)
{
   const bank_t *b = &a->banks[bi];
   flow_kind_t flow;
   uint8_t r;
   if (switch_saves_out) *switch_saves_out = 0u;
   if (off >= b->size || b->spec_rejected[off]) return 0;
   if (rom_offset_hidden(a, off)) return 0;
   r = b->roles[off];
   if (r & (ROLE_CODE_BYTE | ROLE_DATA_READ | ROLE_POSSIBLE | ROLE_VECTOR)) return 0;
   flow = instruction_flow(a->rom[b->file_offset + off]);
   /* Do not manufacture one-byte "islands" from random terminator bytes. */
   if (flow == FLOW_RTS || flow == FLOW_JMP_ABSOLUTE ||
       flow == FLOW_JMP_INDIRECT || flow == FLOW_STOP)
      return 0;
   return speculative_candidate_credible(a, bi, off, switch_saves_out);
}

static int discover_speculative_islands(analysis_t *a)
{
   size_t bi;
   uint8_t *scratch = NULL;
   uint8_t *halt_reachable = NULL;
   a->speculative_rejected_starts = 0;
   a->speculative_barriers = 0;
   a->speculative_islands = 0;

   scratch = (uint8_t *)calloc(a->rom_size, 1);
   if (!scratch) return 0;
   halt_reachable = speculative_halt_reachability(a);
   if (!halt_reachable) { free(scratch); return 0; }

   for (bi = 0; bi < a->bank_count; ++bi) {
      bank_t *b = &a->banks[bi];
      size_t off;
      abstract_state_t initial;

      memset(b->spec_rejected, 0, b->size);
      memset(b->spec_strong, 0, b->size);
      memset(b->spec_reject_end, 0xff, b->size * sizeof(*b->spec_reject_end));
      memset(b->spec_barrier, 0, b->size);
      memset(b->spec_barrier_end, 0xff, b->size * sizeof(*b->spec_barrier_end));
      memset(b->spec_seed, 0, b->size);
      memset(&initial, 0, sizeof(initial));

      /* Negative evidence is computed for every not-yet-established start,
       * including operand/data bytes.  It remains non-exclusive metadata and
       * never erases a definite role discovered by ordinary control flow. */
      for (off = 0; off < b->size; ++off) {
         spec_context_t ctx;
         spec_result_t r;
         if (b->roles[off] & ROLE_CODE_START) continue;
         if (rom_offset_hidden(a, off)) continue;
         if (!halt_reachable[b->file_offset + off]) continue;
         memset(scratch, 0, a->rom_size);
         memset(&ctx, 0, sizeof(ctx));
         ctx.visiting = scratch;
         ctx.steps = 0u;
         ctx.step_limit = b->size < 256u ? b->size * 2u : 512u;
         r = speculative_flow(a, bi, off, &initial, &ctx);
         if (r == SPEC_REJECT) {
            uint16_t reject_end;
            b->spec_rejected[off] = 1u;
            ++a->speculative_rejected_starts;
            if (speculative_linear_jam_end(a, bi, off, &reject_end))
               b->spec_reject_end[off] = reject_end;
         }
         else if (r == SPEC_SAFE_STRONG) {
            b->spec_strong[off] = 1u;
         }
      }

      /* Three consecutive rejected instruction starts are a sequential-flow
       * barrier because no 6502/6507 instruction is longer than three bytes.
       * This never forbids an explicit control-transfer entry on either side. */
      for (off = 0; off + 2u < b->size; ++off) {
         if (b->spec_rejected[off] && b->spec_rejected[off + 1u] &&
             b->spec_rejected[off + 2u] &&
             !(b->roles[off] & ROLE_CODE_START) &&
             !(b->roles[off + 1u] & ROLE_CODE_START) &&
             !(b->roles[off + 2u] & ROLE_CODE_START)) {
            b->spec_barrier[off] = 1u;
            ++a->speculative_barriers;
            /* The barrier itself follows solely from three impossible starts.
             * A contiguous non-code span through a particular JAM endpoint is
             * stronger evidence and is recorded only when all three rejections
             * were proved by straight-line fallthrough. */
            if (b->spec_reject_end[off] != UINT16_MAX &&
                b->spec_reject_end[off + 1u] != UINT16_MAX &&
                b->spec_reject_end[off + 2u] != UINT16_MAX) {
               uint16_t end = b->spec_reject_end[off];
               if (b->spec_reject_end[off + 1u] > end) end = b->spec_reject_end[off + 1u];
               if (b->spec_reject_end[off + 2u] > end) end = b->spec_reject_end[off + 2u];
               b->spec_barrier_end[off] = end;
            }
         }
      }

      /* Promote only the first safe, nontrivial candidate immediately after a
       * rejected-start barrier.  This is deliberately much more conservative
       * than treating every legal decode as unreachable utility code. */
      for (off = 0; off + 2u < b->size; ++off) {
         size_t candidate;
         size_t switch_saves = 0u;
         if (!b->spec_barrier[off] || b->spec_barrier_end[off] == UINT16_MAX) continue;
         candidate = (size_t)b->spec_barrier_end[off] + 1u;
         if (candidate >= b->size) continue;
         if (!speculative_candidate_promotable(a, bi, candidate,
                                               &switch_saves)) continue;
         b->spec_seed[candidate] = 1u;
         a->speculative_switch_avoided_halts += switch_saves;
         mark_label(b, candidate);
         if (!push_work(a, bi, candidate)) {
            free(halt_reachable);
            free(scratch);
            return 0;
         }
         ++a->speculative_islands;
      }
   }
   free(halt_reachable);
   free(scratch);
   return 1;
}

static int trace_analysis_internal(analysis_t *a, const options_t *opt,
                                   int reset_only, int run_speculative)
{
   size_t bi;
   int speculative_done = 0;
   if (a->mapper == MAP_RAW) return 1;
   a->reachable_halts = 0u;

   if (a->mapper == MAP_E0) {
      /* E0 hardware vectors are always in fixed physical 1K bank 7.
       * Power-on maps banks 4,5,6 into the lower three runtime windows. */
      bank_t *vb = &a->banks[7];
      unsigned v;
      unsigned first_v = reset_only ? 1u : 0u;
      unsigned last_v = reset_only ? 1u : 2u;
      for (v = first_v; v <= last_v; ++v) {
         size_t voff = vb->size - 6u + (size_t)v * 2u;
         uint16_t target = read_word(a->rom + vb->file_offset + voff);
         size_t tbank, toff;
         vb->roles[voff] |= ROLE_VECTOR;
         vb->roles[voff + 1u] |= ROLE_VECTOR;
         if (e0_map_address(a, E0_RESET_CONFIG, target, &tbank, &toff)) {
            abstract_state_t state;
            mark_label(&a->banks[tbank], toff);
            memset(&state, 0, sizeof(state));
            if (!push_work_state_ctx(a, tbank, toff, &state, target,
                                     E0_RESET_CONFIG)) return 0;
         }
      }
   }
   else if (a->mapper == MAP_WD) {
      /* WD powers up in arrangement 0.  Only its top 1K segment supplies the
       * hardware vectors.  Resolve the vector targets through that complete
       * four-segment arrangement rather than pretending a 1K physical bank
       * owns the entire cartridge window. */
      bank_t *vb = &a->banks[a->reset_bank];
      unsigned v;
      unsigned first_v = reset_only ? 1u : 0u;
      unsigned last_v = reset_only ? 1u : 2u;
      for (v = first_v; v <= last_v; ++v) {
         size_t voff = vb->size - 6u + (size_t)v * 2u;
         uint16_t target = read_word(a->rom + vb->file_offset + voff);
         size_t tbank, toff;
         vb->roles[voff] |= ROLE_VECTOR;
         vb->roles[voff + 1u] |= ROLE_VECTOR;
         if (wd_map_address(a, 0u, target, &tbank, &toff)) {
            mark_label(&a->banks[tbank], toff);
            {
               abstract_state_t state;
               memset(&state, 0, sizeof(state));
               if (!push_work_state_ctx(a, tbank, toff, &state, target, 0u)) return 0;
            }
         }
      }
   }
   else {
      /* Normal analysis seeds every physical bank from all three vectors so
       * bank-local trampolines are recovered. Mapper-hypothesis validation is
       * stricter: start only from the hardware/reset-bank RESET vector so a
       * wrong mapper cannot rescue itself using unrelated vector-shaped data. */
      size_t first_bank = reset_only ? a->reset_bank : 0u;
      size_t last_bank = reset_only ? a->reset_bank : a->bank_count - 1u;
      for (bi = first_bank; bi <= last_bank; ++bi) {
         bank_t *b = &a->banks[bi];
         unsigned v;
         unsigned first_v = reset_only ? 1u : 0u;
         unsigned last_v = reset_only ? 1u : 2u;
         for (v = first_v; v <= last_v; ++v) {
            size_t voff = b->size - 6u + (size_t)v * 2u;
            uint16_t target = read_word(a->rom + b->file_offset + voff);
            size_t toff;
            b->roles[voff] |= ROLE_VECTOR;
            b->roles[voff+1] |= ROLE_VECTOR;
            if (cart_target_offset(b, target, &toff) && !rom_offset_hidden(a, toff)) {
               mark_label(b, toff);
               if (!push_work(a, bi, toff)) return 0;
            }
         }
      }
   }

   /* Manual data roles are deliberately non-exclusive with code. */
   for (bi = 0; bi < opt->data_count; ++bi) {
      size_t bank, first, last, off;
      if (!hint_range_offsets(a, "data", opt->data_specs[bi],
                              &bank, &first, &last)) return 0;
      mark_label(&a->banks[bank], first);
      for (off = first; off <= last; ++off)
         a->banks[bank].roles[off] |= ROLE_DATA_READ;
   }

   /* Extra entry points participate in the same recursive analysis as vectors. */
   for (bi = 0; bi < opt->entry_count; ++bi) {
      size_t bank, off;
      if (!hint_address_offset(a, "entry", opt->entry_specs[bi], &bank, &off))
         return 0;
      mark_label(&a->banks[bank], off);
      if (!push_work(a, bank, off)) return 0;
   }

   /* A forced code range is a linear decode assertion.  Seed every sequential
    * instruction start so a deliberate RTS/JMP inside the range does not stop
    * the human's explicit code declaration.  Normal recursive edges are still
    * followed from each seed, and data roles may overlap this range. */
   for (bi = 0; bi < opt->code_count; ++bi) {
      size_t bank, first, last, off;
      bank_t *b;
      if (!hint_range_offsets(a, "code", opt->code_specs[bi],
                              &bank, &first, &last)) return 0;
      b = &a->banks[bank];
      mark_label(b, first);
      off = first;
      while (off <= last) {
         unsigned len = instruction_length((address_mode_t)
                           opcode_modes[a->rom[b->file_offset + off]]);
         if (len == 0u || off + len - 1u > last) {
            fprintf(stderr, "--code range '%s' ends inside an instruction at $%04X\n",
                    opt->code_specs[bi],
                    (unsigned)(b->origin + (uint16_t)off));
            return 0;
         }
         if (!push_work(a, bank, off)) return 0;
         off += len;
      }
   }

drain_work:
   while (a->work_count != 0) {
      work_item_t item = a->work[--a->work_count];
      bank_t *b = &a->banks[item.bank];
      size_t off = item.offset;
      uint8_t opcode;
      address_mode_t mode;
      unsigned len;
      flow_kind_t flow;
      uint16_t operand = 0;
      uint16_t canonical_pc;
      size_t successor_bank = item.bank;
      int switched = 0;
      int wd_switched = 0;
      uint8_t wd_successor_config = (uint8_t)item.mapper_config;
      int e0_switched = 0;
      uint16_t e0_successor_config = item.mapper_config;
      abstract_state_t input_state;
      abstract_state_t output_state;

      b->queued[off] = 0;
      if (!b->state_seen[off]) continue;
      if (rom_offset_hidden(a, off)) continue;
      input_state = b->states[off];
      b->visited[off] = 1;
      opcode = a->rom[b->file_offset + off];
      if (opcode_is_cpu_halt(opcode)) ++a->reachable_halts;
      mode = (address_mode_t)opcode_modes[opcode];
      len = instruction_length(mode);
      if (off + len > b->size) continue;
      mark_instruction(b, off, opcode, len);
      canonical_pc = (a->mapper == MAP_WD || a->mapper == MAP_E0)
                       ? item.pc
                       : (uint16_t)(b->origin + (uint16_t)off);
      flow = instruction_flow(opcode);

      if (len >= 2u) operand = a->rom[b->file_offset + off + 1u];
      if (len >= 3u) operand |= (uint16_t)a->rom[b->file_offset + off + 2u] << 8;
      /* vcsc-as deliberately rejects JMP ($xxFF) because the NMOS CPU fetches
       * the vector high byte from $xx00.  Preserve a real cartridge using that
       * silicon behavior as raw bytes rather than emitting source the assembler
       * refuses to accept. */
      if (opcode == 0x6cu && (operand & 0x00ffu) == 0x00ffu)
         b->force_raw[off] = 1u;
      transfer_state(a, item.bank, &input_state, &output_state,
                     opcode, mode, operand);

      /* Superchip RAM uses write $x000-$x07F and read $x080-$x0FF
       * aliases in the cartridge window.  A direct access with the matching
       * direction is strong evidence for 4KSC or an SC F8/F6/F4 variant. */
      {
         unsigned access = opcode_memory_access(opcode);
         uint16_t bus = (uint16_t)(operand & 0x1fffu);
         if (mode == AM_ABSOLUTE &&
             (a->mapper == MAP_4K || a->mapper == MAP_F8 ||
              a->mapper == MAP_F6 || a->mapper == MAP_F4)) {
            if ((access & ACCESS_WRITE) && bus >= 0x1000u && bus <= 0x107fu) {
               ++a->superchip_refs;
               ++a->superchip_write_refs;
            }
            if ((access & ACCESS_READ) && bus >= 0x1080u && bus <= 0x10ffu)
               ++a->superchip_refs;
         }
      }

      /* Definite ROM reads are independent from executable-byte roles.  Use
       * abstract register/pointer state where available; otherwise keep the
       * conservative possible-range semantics below. */
      if (flow != FLOW_JSR && flow != FLOW_JMP_ABSOLUTE &&
          flow != FLOW_JMP_INDIRECT &&
          (opcode_memory_access(opcode) & ACCESS_READ)) {
         uint16_t effective;
         int exact = resolve_effective_address(&input_state, mode, operand,
                                               &effective);
         if (mode == AM_ABSOLUTE) exact = 1, effective = operand;
         if (exact) {
            size_t doff;
            uint16_t bus = (uint16_t)(effective & 0x1fffu);
            int sc_read = superchip_active(a) &&
                          bus >= 0x1080u && bus <= 0x10ffu;
            int dpc_reg = dpc_register_address(a, effective);
            int fa_ram = fa_ram_address(a, effective);
            if (!sc_read && !dpc_reg && !fa_ram) {
               if (a->mapper == MAP_WD) {
                  size_t dbank;
                  if (wd_map_address(a, (uint8_t)item.mapper_config, effective, &dbank, &doff)) {
                     a->banks[dbank].roles[doff] |= ROLE_DATA_READ;
                     mark_label(&a->banks[dbank], doff);
                  }
               }
               else if (a->mapper == MAP_E0) {
                  size_t dbank;
                  if (e0_map_address(a, item.mapper_config, effective, &dbank, &doff)) {
                     a->banks[dbank].roles[doff] |= ROLE_DATA_READ;
                     mark_label(&a->banks[dbank], doff);
                  }
               }
               else if (cart_target_offset(b, effective, &doff)) {
                  b->roles[doff] |= ROLE_DATA_READ;
                  mark_label(b, doff);
               }
            }
         }
         else if (a->mapper != MAP_WD && a->mapper != MAP_E0 &&
                  (mode == AM_ABSOLUTE_X || mode == AM_ABSOLUTE_Y)) {
            unsigned ix;
            for (ix = 0; ix < 256u; ++ix) {
               uint16_t addr = (uint16_t)(operand + (uint16_t)ix);
               size_t doff;
               if (cart_target_offset(b, addr, &doff))
                  b->roles[doff] |= ROLE_POSSIBLE;
            }
            {
               size_t baseoff;
               if (cart_target_offset(b, operand, &baseoff)) mark_label(b, baseoff);
            }
         }
         else if (a->mapper != MAP_WD && a->mapper != MAP_E0 &&
                  mode == AM_INDIRECT_INDEXED) {
            uint16_t pointer;
            if (resolve_zp_word(&input_state, (uint8_t)operand, &pointer)) {
               unsigned iy;
               for (iy = 0; iy < 256u; ++iy) {
                  uint16_t addr = (uint16_t)(pointer + (uint16_t)iy);
                  size_t doff;
                  if (cart_target_offset(b, addr, &doff))
                     b->roles[doff] |= ROLE_POSSIBLE;
               }
               {
                  size_t baseoff;
                  if (cart_target_offset(b, pointer, &baseoff)) mark_label(b, baseoff);
               }
            }
            else {
               size_t poff;
               for (poff = 0; poff < b->size; ++poff)
                  b->roles[poff] |= ROLE_POSSIBLE;
            }
         }
         else if (a->mapper != MAP_WD && a->mapper != MAP_E0 &&
                  mode == AM_INDEXED_INDIRECT) {
            size_t poff;
            for (poff = 0; poff < b->size; ++poff)
               b->roles[poff] |= ROLE_POSSIBLE;
         }
      }

      /* Any statically resolved memory access to a mapper selector changes
       * which physical bank supplies the following opcode fetch. */
      if (instruction_selector_bank(a, &input_state, opcode, mode, operand,
                                    &successor_bank) &&
          successor_bank < a->bank_count) {
         switched = 1;
         ++a->hotspot_refs;
      }
      if (a->mapper == MAP_WD && flow == FLOW_NEXT &&
          (opcode_memory_access(opcode) & ACCESS_READ)) {
         uint16_t effective;
         if ((mode == AM_ZERO_PAGE || mode == AM_ABSOLUTE) &&
             resolve_effective_address(&input_state, mode, operand, &effective) &&
             wd_hotspot_config(effective, &wd_successor_config)) {
            wd_switched = 1;
            ++a->hotspot_refs;
         }
      }
      if (a->mapper == MAP_E0 && flow == FLOW_NEXT &&
          (opcode_memory_access(opcode) & (ACCESS_READ | ACCESS_WRITE))) {
         uint16_t effective;
         if (resolve_effective_address(&input_state, mode, operand, &effective) &&
             e0_selector_config(effective, item.mapper_config,
                                &e0_successor_config)) {
            e0_switched = 1;
            ++a->hotspot_refs;
         }
      }

      switch (flow) {
      case FLOW_NEXT:
         if (a->mapper == MAP_E0) {
            uint16_t next_pc = (uint16_t)(canonical_pc + len);
            uint16_t next_config = e0_switched ? e0_successor_config
                                               : item.mapper_config;
            if (e0_switched) {
               size_t old_bank, old_off, next_bank, next_off;
               if (e0_map_address(a, item.mapper_config, next_pc, &old_bank, &old_off) &&
                   e0_map_address(a, next_config, next_pc, &next_bank, &next_off) &&
                   old_bank != next_bank) {
                  mark_label(&a->banks[next_bank], next_off);
                  if (opcode_is_cpu_halt(a->rom[a->banks[old_bank].file_offset + old_off]) &&
                      !opcode_is_cpu_halt(a->rom[a->banks[next_bank].file_offset + next_off]))
                     ++a->flow_switch_avoided_halts;
               }
            }
            if (!push_e0_address_state(a, next_config, next_pc, &output_state))
               return 0;
         }
         else if (a->mapper == MAP_WD) {
            uint16_t next_pc = (uint16_t)(canonical_pc + len);
            if (!push_wd_address_state(a, item.mapper_config, next_pc, &output_state))
               return 0;
            /* WD latches a TIA $30-$3F read and applies the new arrangement
             * after a short hardware delay.  Static analysis deliberately
             * keeps both old and new arrangement successors so a routine is
             * never lost merely because instruction-level cycle placement is
             * ambiguous. */
            if (wd_switched && wd_successor_config != item.mapper_config &&
                !push_wd_address_state(a, wd_successor_config, next_pc, &output_state))
               return 0;
         }
         else if (off + len < b->size) {
            if (switched && successor_bank != item.bank) {
               if (opcode_is_cpu_halt(a->rom[b->file_offset + off + len]) &&
                   !opcode_is_cpu_halt(a->rom[a->banks[successor_bank].file_offset + off + len]))
                  ++a->flow_switch_avoided_halts;
               mark_label(&a->banks[successor_bank], off + len);
            }
            if (!push_work_state(a, switched ? successor_bank : item.bank,
                                 off + len, &output_state))
               return 0;
         }
         break;
      case FLOW_BRANCH: {
         int8_t disp = (int8_t)(uint8_t)operand;
         uint16_t target = (uint16_t)(canonical_pc + 2u + disp);
         size_t toff;
         int known = 0, taken = 0;
         if (reset_only)
            known = speculative_branch_outcome(opcode, &output_state, &taken);
         if (a->mapper == MAP_E0) {
            if (!known || !taken) {
               uint16_t fall_pc = (uint16_t)(canonical_pc + 2u);
               size_t fbank, foff;
               if (e0_map_address(a, item.mapper_config, fall_pc, &fbank, &foff) &&
                   fbank != item.bank)
                  mark_label(&a->banks[fbank], foff);
               if (!push_e0_address_state(a, item.mapper_config, fall_pc, &output_state))
                  return 0;
            }
            if (!known || taken) {
               size_t tbank, toff;
               if (e0_map_address(a, item.mapper_config, target, &tbank, &toff))
                  mark_label(&a->banks[tbank], toff);
               if (!push_e0_address_state(a, item.mapper_config, target, &output_state))
                  return 0;
            }
         }
         else if (a->mapper == MAP_WD) {
            if ((!known || !taken) &&
                !push_wd_address_state(a, (uint8_t)item.mapper_config,
                                       (uint16_t)(canonical_pc + 2u), &output_state))
               return 0;
            if ((!known || taken) &&
                !push_wd_address_state(a, (uint8_t)item.mapper_config, target, &output_state))
               return 0;
         }
         else {
         if ((!known || !taken) && off + 2u < b->size &&
             !push_work_state(a, item.bank, off + 2u, &output_state)) return 0;
         if ((!known || taken) && target >= b->origin &&
             (uint32_t)target < (uint32_t)b->origin + (uint32_t)b->size) {
            toff = (size_t)(target - b->origin);
            if (rom_offset_hidden(a, toff)) ++a->dynamic_control_exits;
            else {
               mark_label(b, toff);
               if (!push_work_state(a, item.bank, toff, &output_state)) return 0;
            }
         }
         }
         break;
      }
      case FLOW_JSR: {
         size_t toff;
         abstract_state_t after_call;
         memset(&after_call, 0, sizeof(after_call));
         if (a->mapper == MAP_E0) {
            uint16_t cont_pc = (uint16_t)(canonical_pc + 3u);
            size_t tbank, toff, cbank, coff;
            if (e0_map_address(a, item.mapper_config, operand, &tbank, &toff))
               mark_label(&a->banks[tbank], toff);
            if (e0_map_address(a, item.mapper_config, cont_pc, &cbank, &coff) &&
                cbank != item.bank)
               mark_label(&a->banks[cbank], coff);
            if (!push_e0_address_state(a, item.mapper_config, cont_pc, &after_call) ||
                !push_e0_address_state(a, item.mapper_config, operand, &output_state))
               return 0;
         }
         else if (a->mapper == MAP_WD) {
            if (!push_wd_address_state(a, (uint8_t)item.mapper_config,
                                       (uint16_t)(canonical_pc + 3u), &after_call) ||
                !push_wd_address_state(a, (uint8_t)item.mapper_config, operand, &output_state))
               return 0;
         }
         else {
         if (off + 3u < b->size &&
             !push_work_state(a, item.bank, off + 3u, &after_call)) return 0;
         if (cart_target_offset(b, operand, &toff) &&
             !(rom_offset_hidden(a, toff))) {
            mark_label(b, toff);
            if (!push_work_state(a, item.bank, toff, &output_state)) return 0;
         }
         else ++a->dynamic_control_exits;
         }
         break;
      }
      case FLOW_JMP_ABSOLUTE: {
         size_t toff;
         if (a->mapper == MAP_E0) {
            size_t tbank, toff;
            if (e0_map_address(a, item.mapper_config, operand, &tbank, &toff))
               mark_label(&a->banks[tbank], toff);
            if (!push_e0_address_state(a, item.mapper_config, operand, &output_state))
               return 0;
         }
         else if (a->mapper == MAP_WD) {
            if (!push_wd_address_state(a, (uint8_t)item.mapper_config, operand, &output_state))
               return 0;
         }
         else if (cart_target_offset(b, operand, &toff) &&
             !(rom_offset_hidden(a, toff))) {
            mark_label(b, toff);
            if (!push_work_state(a, item.bank, toff, &output_state)) return 0;
         }
         else ++a->dynamic_control_exits;
         break;
      }
      case FLOW_JMP_INDIRECT: {
         if (a->mapper == MAP_E0) {
            uint16_t ptr = operand;
            uint16_t high_addr = (uint16_t)((ptr & 0xff00u) |
                                 ((uint16_t)(ptr + 1u) & 0x00ffu));
            size_t lbank, loff, hbank, hoff;
            if (e0_map_address(a, item.mapper_config, ptr, &lbank, &loff) &&
                e0_map_address(a, item.mapper_config, high_addr, &hbank, &hoff)) {
               uint16_t target = (uint16_t)(a->rom[a->banks[lbank].file_offset + loff] |
                                 ((uint16_t)a->rom[a->banks[hbank].file_offset + hoff] << 8));
               size_t tbank, toff;
               a->banks[lbank].roles[loff] |= ROLE_DATA_READ;
               a->banks[hbank].roles[hoff] |= ROLE_DATA_READ;
               if (e0_map_address(a, item.mapper_config, target, &tbank, &toff))
                  mark_label(&a->banks[tbank], toff);
               if (!push_e0_address_state(a, item.mapper_config, target, &output_state))
                  return 0;
            }
            else ++a->unresolved_indirect_jumps;
            break;
         }
         if (a->mapper == MAP_WD) {
            ++a->unresolved_indirect_jumps;
            break;
         }
         uint16_t ptr = operand;
         uint16_t high_addr = (uint16_t)((ptr & 0xff00u) |
                              ((uint16_t)(ptr + 1u) & 0x00ffu));
         size_t loff, hoff;
         if (cart_target_offset(b, ptr, &loff) &&
             cart_target_offset(b, high_addr, &hoff)) {
            uint16_t target = (uint16_t)(a->rom[b->file_offset + loff] |
                              ((uint16_t)a->rom[b->file_offset + hoff] << 8));
            size_t toff;
            b->roles[loff] |= ROLE_DATA_READ;
            b->roles[hoff] |= ROLE_DATA_READ;
            if (cart_target_offset(b, target, &toff) &&
                !(rom_offset_hidden(a, toff))) {
               mark_label(b, toff);
               if (!push_work_state(a, item.bank, toff, &output_state)) return 0;
            }
            else ++a->dynamic_control_exits;
         }
         else ++a->unresolved_indirect_jumps;
         break;
      }
      case FLOW_RTS:
      case FLOW_STOP:
         break;
      }
   }

   if (run_speculative && !speculative_done) {
      speculative_done = 1;
      if (!discover_speculative_islands(a)) return 0;
      if (a->work_count != 0) goto drain_work;
   }

   detect_overlaps(a);
   return 1;
}

static int trace_analysis(analysis_t *a, const options_t *opt)
{
   return trace_analysis_internal(a, opt, 0, 1);
}

typedef struct {
   mapper_t mapper;
   int viable;
   size_t instructions;
   size_t halts;
   int hotspots;
   size_t switch_avoided_halts;
   int dynamic_exits;
   int explicit_signature;
} mapper_hypothesis_t;

static size_t mapper_candidates_for_size(size_t size, mapper_t *out,
                                         size_t capacity)
{
   size_t n = 0u;
#define ADD_MAPPER(m) do { if (n < capacity) out[n] = (m); ++n; } while (0)
   switch (size) {
   case 2048u:
      ADD_MAPPER(MAP_2K); ADD_MAPPER(MAP_CV);
      break;
   case 4096u:
      ADD_MAPPER(MAP_4K);
      break;
   case 8192u:
      ADD_MAPPER(MAP_F8); ADD_MAPPER(MAP_E0); ADD_MAPPER(MAP_0840);
      ADD_MAPPER(MAP_UA); ADD_MAPPER(MAP_UASW); ADD_MAPPER(MAP_0FA0);
      ADD_MAPPER(MAP_WD);
      break;
   case 12288u:
      ADD_MAPPER(MAP_FA);
      break;
   case 16384u:
      ADD_MAPPER(MAP_F6); ADD_MAPPER(MAP_JANE);
      break;
   case 32768u:
      ADD_MAPPER(MAP_F4);
      break;
   case 10240u: case 10495u:
      ADD_MAPPER(MAP_DPC);
      break;
   case 8195u:
      ADD_MAPPER(MAP_WD);
      break;
   default:
      break;
   }
#undef ADD_MAPPER
   return n;
}

static int mapper_tail_signature_matches(const uint8_t *rom, size_t size,
                                         mapper_t mapper)
{
   const uint8_t *p;
   if (size < 8u) return 0;
   p = rom + size - 8u;
   switch (mapper) {
   case MAP_CV: return memcmp(p, "CV\0\0", 4u) == 0;
   case MAP_F8: return memcmp(p, "F8\0\0", 4u) == 0 ||
                       memcmp(p, "F8SC", 4u) == 0;
   case MAP_F6: return memcmp(p, "F6\0\0", 4u) == 0 ||
                       memcmp(p, "F6SC", 4u) == 0;
   case MAP_F4: return memcmp(p, "F4\0\0", 4u) == 0 ||
                       memcmp(p, "F4SC", 4u) == 0;
   case MAP_FA: return memcmp(p, "FA\0\0", 4u) == 0;
   case MAP_JANE: return memcmp(p, "JANE", 4u) == 0;
   case MAP_0840: return memcmp(p, "0840", 4u) == 0;
   case MAP_UA: return memcmp(p, "UA\0\0", 4u) == 0;
   case MAP_UASW: return memcmp(p, "UASW", 4u) == 0;
   case MAP_0FA0: return memcmp(p, "0FA0", 4u) == 0;
   default: return 0;
   }
}

static size_t analysis_instruction_count(const analysis_t *a)
{
   size_t bi, off, count = 0u;
   for (bi = 0; bi < a->bank_count; ++bi)
      for (off = 0; off < a->banks[bi].size; ++off)
         if (a->banks[bi].roles[off] & ROLE_CODE_START) ++count;
   return count;
}

/* Mapper byte signatures remain useful evidence, but they are no longer
 * allowed to choose an ambiguous mapper before execution has had a vote.
 * Competing size-compatible mapper models are run from the RESET path.  A
 * model that leads established execution into JAM/KIL is discarded; decoded
 * selector accesses then eliminate models that fail to explain real bank
 * transitions.  Only after that do explicit VCSC metadata and the legacy
 * byte-pattern heuristic break a genuine remaining tie. */
static mapper_t refine_mapper_by_control_flow(const uint8_t *rom, size_t size,
                                              mapper_t legacy,
                                              size_t *tested_out,
                                              size_t *survived_out,
                                              int *refined_out)
{
   mapper_t candidates[8];
   mapper_hypothesis_t h[8];
   size_t n, i, survivors = 0u;
   size_t best_count = 0u;
   mapper_t winner = legacy;

   *tested_out = 0u;
   *survived_out = 0u;
   *refined_out = 0;
   n = mapper_candidates_for_size(size, candidates,
                                  sizeof(candidates) / sizeof(candidates[0]));
   if (n <= 1u || n > sizeof(h) / sizeof(h[0])) return legacy;

   memset(h, 0, sizeof(h));
   for (i = 0; i < n; ++i) {
      options_t probe_opt;
      analysis_t probe;
      memset(&probe_opt, 0, sizeof(probe_opt));
      probe_opt.mapper_override_set = 1;
      probe_opt.mapper_override = candidates[i];
      probe_opt.superchip_override = -1;
      probe_opt.reset_bank_override = -1;
      h[i].mapper = candidates[i];
      h[i].explicit_signature =
         mapper_tail_signature_matches(rom, size, candidates[i]);
      ++*tested_out;

      if (!init_analysis(&probe, (uint8_t *)rom, size, &probe_opt)) continue;
      /* Run each candidate to the same conservative fixed point used by the
       * real analysis: RESET-reachable code first, then credible speculative
       * islands.  An otherwise unreachable switch trampoline can therefore
       * provide the evidence that eliminates a wrong mapper hypothesis. */
      if (trace_analysis_internal(&probe, &probe_opt, 1, 1)) {
         h[i].instructions = analysis_instruction_count(&probe);
         h[i].halts = probe.reachable_halts;
         h[i].hotspots = probe.hotspot_refs;
         h[i].switch_avoided_halts = probe.flow_switch_avoided_halts +
                                      probe.speculative_switch_avoided_halts;
         h[i].dynamic_exits = probe.dynamic_control_exits;
         h[i].viable = h[i].instructions != 0u && h[i].halts == 0u;
      }
      free_analysis(&probe);
      if (h[i].viable) ++survivors;
   }

   if (survivors == 0u) return legacy;

   /* Do not rank mapper families by raw selector-hit count.  Alias-heavy
    * schemes such as 0840 can classify ordinary accesses as hotspots and
    * therefore manufacture more "evidence" than a narrower, correct mapper.
    * A much stronger observation is a selector whose bank transition avoids a
    * HLT/JAM/KIL byte that would have been fetched from the old mapping.  If
    * any viable hypothesis explains such a continuation, hypotheses with no
    * such proof are weaker and can be discarded. */
   {
      int have_switch_save = 0;
      for (i = 0; i < n; ++i)
         if (h[i].viable && h[i].switch_avoided_halts != 0u)
            have_switch_save = 1;
      if (have_switch_save) {
         for (i = 0; i < n; ++i)
            if (h[i].viable && h[i].switch_avoided_halts == 0u)
               h[i].viable = 0;
      }
   }

   survivors = 0u;
   for (i = 0; i < n; ++i) if (h[i].viable) ++survivors;
   if (survivors == 1u) {
      for (i = 0; i < n; ++i) if (h[i].viable) winner = h[i].mapper;
   }
   else {
      /* An explicit VCSC tail signature is deliberate metadata, unlike a raw
       * opcode substring.  Use it only after impossible execution models have
       * already been removed. */
      size_t signed_count = 0u;
      mapper_t signed_mapper = legacy;
      for (i = 0; i < n; ++i) {
         if (h[i].viable && h[i].explicit_signature) {
            ++signed_count;
            signed_mapper = h[i].mapper;
         }
      }
      if (signed_count == 1u) winner = signed_mapper;
      else {
         /* Prefer fewer unexplained control exits if that uniquely separates
          * the remaining models. */
         int best_exits = -1;
         size_t exit_count = 0u;
         mapper_t exit_mapper = legacy;
         for (i = 0; i < n; ++i) {
            if (!h[i].viable) continue;
            if (best_exits < 0 || h[i].dynamic_exits < best_exits) {
               best_exits = h[i].dynamic_exits;
               exit_count = 1u;
               exit_mapper = h[i].mapper;
            }
            else if (h[i].dynamic_exits == best_exits) ++exit_count;
         }
         if (exit_count == 1u) winner = exit_mapper;
         else {
            /* Genuine ambiguity remains. Preserve historical behavior rather
             * than inventing certainty; the header will report survivor count. */
            int legacy_survives = 0;
            for (i = 0; i < n; ++i)
               if (h[i].viable && h[i].mapper == legacy) legacy_survives = 1;
            if (!legacy_survives) {
               for (i = 0; i < n; ++i)
                  if (h[i].viable) { winner = h[i].mapper; break; }
            }
         }
      }
   }

   best_count = 0u;
   for (i = 0; i < n; ++i) if (h[i].viable) ++best_count;
   *survived_out = best_count;
   *refined_out = winner != legacy || best_count == 1u;
   return winner;
}

static void apply_superchip_window_semantics(analysis_t *a)
{
   size_t bi;
   if (!superchip_active(a)) return;
   for (bi = 0; bi < a->bank_count; ++bi) {
      bank_t *b = &a->banks[bi];
      size_t off;
      size_t end = b->size < 0x100u ? b->size : 0x100u;
      for (off = 0; off < end; ++off) {
         b->roles[off] = 0;
         b->inst_len[off] = 0;
         b->inst_opcode[off] = 0;
         b->graphics[off] = 0;
         b->force_raw[off] = 0;
      }
   }
}

static int instruction_can_emit(const bank_t *b, size_t off)
{
   unsigned len;
   size_t i;
   if (!(b->roles[off] & ROLE_CODE_START)) return 0;
   if (b->force_raw[off]) return 0;
   len = b->inst_len[off];
   if (len == 0 || off + len > b->size) return 0;

   /*
    * A reachable entry inside this instruction means the outer spelling cannot
    * own those operand bytes in source.  Emit the bytes before the inner entry
    * raw and let the inner instruction become the primary source spelling.
    * This naturally represents BIT-skip and other overlapping streams without
    * special-casing opcode $2c.
    */
   for (i = off + 1u; i < off + len; ++i)
      if (b->roles[i] & ROLE_CODE_START) return 0;
   return 1;
}


static int emitted_container_start(const bank_t *b, size_t off, size_t *start)
{
   size_t i;
   size_t begin = off >= 2u ? off - 2u : 0u;
   for (i = begin; i < off; ++i) {
      unsigned len;
      if (!instruction_can_emit(b, i)) continue;
      len = b->inst_len[i];
      if (i + len > off) {
         *start = i;
         return 1;
      }
   }

   /* The three cartridge vectors are normally emitted as two-byte .word
    * containers.  A vector can legally point at the high byte of another
    * vector (or even its own high byte), so that interior address cannot own
    * a standalone source label while the .word spelling is in use.  Treat it
    * exactly like an instruction operand: promote the label to the emitted
    * container and reference it as label + 1.
    *
    * Do NOT do that when either vector byte is established executable code.
    * Real cartridges can deliberately execute bytes in the vector table
    * (Stellar Track uses the NMI bytes as LSR A / RTS and JSRs the high byte).
    * In that case emit the executable spelling instead of an indivisible
    * .word, so every real instruction entry can own its source label. */
   if (b->size >= 6u) {
      size_t base = b->size - 6u;
      if (off >= base && off < b->size && ((off - base) & 1u)) {
         size_t low = off - 1u;
         if (!(b->roles[low] & ROLE_CODE_START) &&
             !(b->roles[off] & ROLE_CODE_START)) {
            *start = low;
            return 1;
         }
      }
   }
   return 0;
}

static void promote_interior_reference_labels(analysis_t *a)
{
   size_t bi;
   for (bi = 0; bi < a->bank_count; ++bi) {
      bank_t *b = &a->banks[bi];
      size_t off;
      for (off = 0; off < b->size; ++off) {
         size_t start;
         if ((b->roles[off] & ROLE_LABEL) &&
             emitted_container_start(b, off, &start))
            b->roles[start] |= ROLE_LABEL;
      }
   }
}

static void print_label_name(FILE *fp, const analysis_t *a, size_t bi, size_t off)
{
   const bank_t *b = &a->banks[bi];
   uint16_t addr = (uint16_t)(b->origin + (uint16_t)off);
   if (a->bank_count == 1u)
      fprintf(fp, "L_%04X", addr);
   else
      fprintf(fp, "B%zu_%04X", bi, addr);
}


static void print_exact_cart_reference(FILE *fp, const analysis_t *a,
                                       size_t bi, size_t toff)
{
   const bank_t *b = &a->banks[bi];
   size_t start;
   if (emitted_container_start(b, toff, &start)) {
      print_label_name(fp, a, bi, start);
      fprintf(fp, " + %zu", toff - start);
   }
   else {
      print_label_name(fp, a, bi, toff);
   }
}

static int raw_opcode_mnemonic(const char *mnemonic)
{
   return mnemonic[0] == 'o' && mnemonic[1] == 'p' &&
          isxdigit((unsigned char)mnemonic[2]) &&
          isxdigit((unsigned char)mnemonic[3]) && mnemonic[4] == '\0';
}

static const char *mode_suffix(uint8_t opcode, address_mode_t mode,
                               uint16_t operand)
{
   int raw = raw_opcode_mnemonic(opcode_mnemonics[opcode]);
   switch (mode) {
   /* Ordinary mnemonics relax naturally to zero page when the resolved operand
      fits.  Raw opXX spellings are intentionally different: vcsc-as requires
      an explicit suffix for ambiguous raw-opcode operand shapes. */
   case AM_ZERO_PAGE: return raw ? ".z" : "";
   case AM_ZERO_PAGE_X: return raw ? ".zx" : "";
   case AM_ZERO_PAGE_Y: return raw ? ".zy" : "";
   /* Preserve an originally wide encoding when its value could otherwise relax
      to zero page.  Values above $ff already select the wide form unambiguously. */
   case AM_ABSOLUTE: return raw || operand <= 0xffu ? ".a" : "";
   case AM_ABSOLUTE_X: return raw || operand <= 0xffu ? ".ax" : "";
   case AM_ABSOLUTE_Y: return raw || operand <= 0xffu ? ".ay" : "";
   case AM_INDIRECT: return ".i";
   case AM_INDEXED_INDIRECT: return ".ix";
   case AM_INDIRECT_INDEXED: return ".iy";
   default: return "";
   }
}



typedef struct {
   const char *name;
   uint16_t canonical;
   int mirrored;
} hw_symbol_t;

static unsigned opcode_memory_access(uint8_t opcode)
{
   if (opcode_is_write_only(opcode)) return ACCESS_WRITE;
   switch (opcode) {
   /* Official read-modify-write families. */
   case 0x06: case 0x0e: case 0x16: case 0x1e:
   case 0x26: case 0x2e: case 0x36: case 0x3e:
   case 0x46: case 0x4e: case 0x56: case 0x5e:
   case 0x66: case 0x6e: case 0x76: case 0x7e:
   case 0xc6: case 0xce: case 0xd6: case 0xde:
   case 0xe6: case 0xee: case 0xf6: case 0xfe:
   /* Common unofficial RMW composite families. */
   case 0x03: case 0x07: case 0x0f: case 0x13: case 0x17: case 0x1b: case 0x1f:
   case 0x23: case 0x27: case 0x2f: case 0x33: case 0x37: case 0x3b: case 0x3f:
   case 0x43: case 0x47: case 0x4f: case 0x53: case 0x57: case 0x5b: case 0x5f:
   case 0x63: case 0x67: case 0x6f: case 0x73: case 0x77: case 0x7b: case 0x7f:
   case 0xc3: case 0xc7: case 0xcf: case 0xd3: case 0xd7: case 0xdb: case 0xdf:
   case 0xe3: case 0xe7: case 0xef: case 0xf3: case 0xf7: case 0xfb: case 0xff:
      return ACCESS_READ | ACCESS_WRITE;
   default:
      return ACCESS_READ;
   }
}

static int tia_write_symbol(unsigned reg, const char **name)
{
   static const char *const names[0x2d] = {
      "VSYNC","VBLANK","WSYNC","RSYNC","NUSIZ0","NUSIZ1","COLUP0","COLUP1",
      "COLUPF","COLUBK","CTRLPF","REFP0","REFP1","PF0","PF1","PF2",
      "RESP0","RESP1","RESM0","RESM1","RESBL","AUDC0","AUDC1","AUDF0",
      "AUDF1","AUDV0","AUDV1","GRP0","GRP1","ENAM0","ENAM1","ENABL",
      "HMP0","HMP1","HMM0","HMM1","HMBL","VDELP0","VDELP1","VDELBL",
      "RESMP0","RESMP1","HMOVE","HMCLR","CXCLR"
   };
   if (reg > 0x2cu) return 0;
   *name = names[reg];
   return 1;
}

static int tia_read_symbol(unsigned reg, const char **name)
{
   static const char *const names[14] = {
      "CXM0P","CXM1P","CXP0FB","CXP1FB","CXM0FB","CXM1FB","CXBLPF",
      "CXPPMM","INPT0","INPT1","INPT2","INPT3","INPT4","INPT5"
   };
   if (reg < 0x30u || reg > 0x3du) return 0;
   *name = names[reg - 0x30u];
   return 1;
}

static int riot_symbol(uint16_t bus, unsigned access, const char **name,
                       uint16_t *canonical)
{
   unsigned reg;
   if ((bus & 0x0280u) != 0x0280u) return 0;
   reg = bus & 0x001fu;
   switch (reg) {
   case 0x00: *name="SWCHA";  *canonical=0x0280u; return 1;
   case 0x01: *name="SWACNT"; *canonical=0x0281u; return 1;
   case 0x02: *name="SWCHB";  *canonical=0x0282u; return 1;
   case 0x03: *name="SWBCNT"; *canonical=0x0283u; return 1;
   case 0x04:
      if (access == ACCESS_READ) { *name="INTIM"; *canonical=0x0284u; return 1; }
      break;
   case 0x05:
      if (access == ACCESS_READ) { *name="TIMINT"; *canonical=0x0285u; return 1; }
      break;
   case 0x14:
      if (access == ACCESS_WRITE) { *name="TIM1T"; *canonical=0x0294u; return 1; }
      break;
   case 0x15:
      if (access == ACCESS_WRITE) { *name="TIM8T"; *canonical=0x0295u; return 1; }
      break;
   case 0x16:
      if (access == ACCESS_WRITE) { *name="TIM64T"; *canonical=0x0296u; return 1; }
      break;
   case 0x17:
      if (access == ACCESS_WRITE) { *name="T1024T"; *canonical=0x0297u; return 1; }
      break;
   default:
      break;
   }
   return 0;
}

static int hardware_symbol(uint8_t opcode, address_mode_t mode,
                           uint16_t operand, hw_symbol_t *out)
{
   unsigned access;
   uint16_t bus;
   const char *name = NULL;
   uint16_t canonical = 0;

   if (mode != AM_ZERO_PAGE && mode != AM_ABSOLUTE) return 0;
   if (instruction_flow(opcode) == FLOW_JSR ||
       instruction_flow(opcode) == FLOW_JMP_ABSOLUTE ||
       instruction_flow(opcode) == FLOW_JMP_INDIRECT)
      return 0;
   access = opcode_memory_access(opcode);
   if (access == (ACCESS_READ | ACCESS_WRITE))
      return 0;
   bus = (uint16_t)(operand & 0x1fffu);
   if (bus & 0x1000u) return 0;

   if ((bus & 0x0080u) == 0) {
      unsigned reg = bus & 0x003fu;
      if (access == ACCESS_WRITE) {
         if (!tia_write_symbol(reg, &name)) return 0;
         canonical = (uint16_t)reg;
      }
      else if (access == ACCESS_READ) {
         if (!tia_read_symbol(reg, &name)) return 0;
         canonical = (uint16_t)reg;
      }
      else {
         /* TIA read-modify-write semantics are not represented by one honest
          * canonical symbol because read and write register meanings differ. */
         return 0;
      }
   }
   else {
      if (!riot_symbol(bus, access, &name, &canonical)) return 0;
   }

   out->name = name;
   out->canonical = canonical;
   out->mirrored = operand != canonical;
   return 1;
}

static void emit_hardware_rmw_comment(FILE *fp, uint8_t opcode,
                                      address_mode_t mode, uint16_t operand)
{
   unsigned access = opcode_memory_access(opcode);
   uint16_t bus;
   if (access != (ACCESS_READ | ACCESS_WRITE) ||
       (mode != AM_ZERO_PAGE && mode != AM_ABSOLUTE))
      return;
   bus = (uint16_t)(operand & 0x1fffu);
   if (bus & 0x1000u) return;

   if ((bus & 0x0080u) == 0) {
      unsigned reg = bus & 0x003fu;
      const char *read_name = NULL;
      const char *write_name = NULL;
      int have_read = tia_read_symbol(reg, &read_name);
      int have_write = tia_write_symbol(reg, &write_name);
      if (!have_read && !have_write) return;
      fputs("    ; TIA read-modify-write: ", fp);
      if (have_read) fprintf(fp, "reads %s ($%04X)", read_name, reg);
      else fprintf(fp, "read side $%04X has no canonical readable register", reg);
      fputs(", ", fp);
      if (have_write) fprintf(fp, "writes %s ($%04X)", write_name, reg);
      else fprintf(fp, "write side $%04X has no canonical writable register", reg);
      if (operand != reg) fprintf(fp, "; mirrored operand $%04X", operand);
      return;
   }
   else {
      const char *read_name = NULL;
      const char *write_name = NULL;
      uint16_t read_canon = 0, write_canon = 0;
      int have_read = riot_symbol(bus, ACCESS_READ, &read_name, &read_canon);
      int have_write = riot_symbol(bus, ACCESS_WRITE, &write_name, &write_canon);
      if (!have_read && !have_write) return;
      fputs("    ; RIOT read-modify-write: ", fp);
      if (have_read) fprintf(fp, "reads %s ($%04X)", read_name, read_canon);
      else fputs("read side has no canonical register", fp);
      fputs(", ", fp);
      if (have_write) fprintf(fp, "writes %s ($%04X)", write_name, write_canon);
      else fputs("write side has no canonical register", fp);
      if ((have_read && operand != read_canon) ||
          (have_write && operand != write_canon))
         fprintf(fp, "; mirrored operand $%04X", operand);
   }
}

static void emit_hw_operand(FILE *fp, const hw_symbol_t *sym, uint16_t operand)
{
   if (!sym->mirrored) {
      fputs(sym->name, fp);
   }
   else {
      uint16_t delta = (uint16_t)(operand - sym->canonical);
      fprintf(fp, "%s + $%04X", sym->name, delta);
   }
}

static int analysis_uses_hardware_symbols(const analysis_t *a)
{
   size_t bi;
   for (bi = 0; bi < a->bank_count; ++bi) {
      const bank_t *b = &a->banks[bi];
      size_t off;
      for (off = 0; off < b->size; ++off) {
         uint8_t opcode;
         address_mode_t mode;
         uint16_t operand;
         hw_symbol_t sym;
         if (!instruction_can_emit(b, off)) continue;
         opcode = b->inst_opcode[off];
         mode = (address_mode_t)opcode_modes[opcode];
         if (b->inst_len[off] < 2u) continue;
         operand = a->rom[b->file_offset + off + 1u];
         if (b->inst_len[off] >= 3u)
            operand |= (uint16_t)a->rom[b->file_offset + off + 2u] << 8;
         if (hardware_symbol(opcode, mode, operand, &sym)) return 1;
      }
   }
   return 0;
}

#define GRAPHICS_TAINT_A 0x01u
#define GRAPHICS_TAINT_X 0x02u
#define GRAPHICS_TAINT_Y 0x04u

static unsigned graphics_store_source(const analysis_t *a, size_t bi,
                                      size_t off)
{
   const bank_t *b = &a->banks[bi];
   uint8_t opcode;
   address_mode_t mode;
   uint16_t operand;
   hw_symbol_t hw;
   const char *mnemonic;
   unsigned source;
   if (off >= b->size || !(b->roles[off] & ROLE_CODE_START)) return 0;
   opcode = b->inst_opcode[off];
   mnemonic = opcode_mnemonics[opcode];
   if (strcmp(mnemonic, "STA") == 0) source = GRAPHICS_TAINT_A;
   else if (strcmp(mnemonic, "STX") == 0) source = GRAPHICS_TAINT_X;
   else if (strcmp(mnemonic, "STY") == 0) source = GRAPHICS_TAINT_Y;
   else return 0;
   mode = (address_mode_t)opcode_modes[opcode];
   operand = b->inst_len[off] >= 2u ? a->rom[b->file_offset + off + 1u] : 0u;
   if (b->inst_len[off] >= 3u)
      operand |= (uint16_t)a->rom[b->file_offset + off + 2u] << 8;
   if (!hardware_symbol(opcode, mode, operand, &hw)) return 0;
   if (strcmp(hw.name, "GRP0") != 0 && strcmp(hw.name, "GRP1") != 0 &&
       strcmp(hw.name, "PF0") != 0 && strcmp(hw.name, "PF1") != 0 &&
       strcmp(hw.name, "PF2") != 0)
      return 0;
   return source;
}

static unsigned graphics_load_destination(uint8_t opcode, address_mode_t mode)
{
   const char *mnemonic = opcode_mnemonics[opcode];
   if (strcmp(mnemonic, "LDA") == 0) {
      if (mode == AM_ABSOLUTE || mode == AM_ABSOLUTE_X ||
          mode == AM_ABSOLUTE_Y || mode == AM_INDEXED_INDIRECT ||
          mode == AM_INDIRECT_INDEXED)
         return GRAPHICS_TAINT_A;
   }
   else if (strcmp(mnemonic, "LDX") == 0) {
      if (mode == AM_ABSOLUTE || mode == AM_ABSOLUTE_Y)
         return GRAPHICS_TAINT_X;
   }
   else if (strcmp(mnemonic, "LDY") == 0) {
      if (mode == AM_ABSOLUTE || mode == AM_ABSOLUTE_X)
         return GRAPHICS_TAINT_Y;
   }
   return 0;
}

/* Advance a tiny dependency state used only for graphics provenance.  A source
 * byte stays graphics evidence through deterministic register transfers and
 * simple ALU/shift transforms because the eventual TIA byte still depends on
 * that source.  Loads/PLA overwrite their destination dependency.  Unknown
 * raw opcodes terminate provenance rather than guessing. */
static int advance_graphics_taint(uint8_t opcode, address_mode_t mode,
                                  unsigned *taint)
{
   const char *mnemonic = opcode_mnemonics[opcode];
   unsigned t = *taint;
   if (strncmp(mnemonic, "op", 2) == 0) return 0;

   if (strcmp(mnemonic, "LDA") == 0 || strcmp(mnemonic, "PLA") == 0)
      t &= ~GRAPHICS_TAINT_A;
   else if (strcmp(mnemonic, "LDX") == 0 || strcmp(mnemonic, "TSX") == 0)
      t &= ~GRAPHICS_TAINT_X;
   else if (strcmp(mnemonic, "LDY") == 0)
      t &= ~GRAPHICS_TAINT_Y;
   else if (strcmp(mnemonic, "TAX") == 0)
      t = (t & ~GRAPHICS_TAINT_X) |
          ((t & GRAPHICS_TAINT_A) ? GRAPHICS_TAINT_X : 0u);
   else if (strcmp(mnemonic, "TAY") == 0)
      t = (t & ~GRAPHICS_TAINT_Y) |
          ((t & GRAPHICS_TAINT_A) ? GRAPHICS_TAINT_Y : 0u);
   else if (strcmp(mnemonic, "TXA") == 0)
      t = (t & ~GRAPHICS_TAINT_A) |
          ((t & GRAPHICS_TAINT_X) ? GRAPHICS_TAINT_A : 0u);
   else if (strcmp(mnemonic, "TYA") == 0)
      t = (t & ~GRAPHICS_TAINT_A) |
          ((t & GRAPHICS_TAINT_Y) ? GRAPHICS_TAINT_A : 0u);
   else if ((strcmp(mnemonic, "ASL") == 0 || strcmp(mnemonic, "LSR") == 0 ||
             strcmp(mnemonic, "ROL") == 0 || strcmp(mnemonic, "ROR") == 0) &&
            mode != AM_ACCUMULATOR) {
      /* Memory shifts do not affect A/X/Y dependencies. */
   }
   /* ADC/SBC/AND/ORA/EOR and accumulator shifts transform A in place, so an
    * existing A dependency remains.  INX/DEX/INY/DEY likewise transform their
    * register in place.  Stores, compares, BIT, flag operations, and stack
    * pushes do not destroy register provenance. */
   *taint = t;
   return 1;
}

static int load_feeds_graphics_store(const analysis_t *a, size_t bi,
                                     size_t off, unsigned initial_taint)
{
   const bank_t *b = &a->banks[bi];
   size_t p = off;
   unsigned steps;
   unsigned taint = initial_taint;
   for (steps = 0; steps < 8u; ++steps) {
      unsigned len;
      uint8_t opcode;
      address_mode_t mode;
      flow_kind_t flow;
      unsigned store_source;
      if (p >= b->size || !(b->roles[p] & ROLE_CODE_START)) return 0;
      len = b->inst_len[p];
      if (len == 0u || p + len >= b->size) return 0;
      p += len;
      if (!(b->roles[p] & ROLE_CODE_START)) return 0;
      store_source = graphics_store_source(a, bi, p);
      if (store_source && (store_source & taint)) return 1;
      opcode = b->inst_opcode[p];
      mode = (address_mode_t)opcode_modes[opcode];
      flow = instruction_flow(opcode);
      if (flow != FLOW_NEXT || !advance_graphics_taint(opcode, mode, &taint) ||
          taint == 0u)
         return 0;
   }
   return 0;
}

static void mark_graphics_range(bank_t *b, size_t start, size_t limit)
{
   size_t off;
   size_t end = start;
   if (start >= b->size) return;
   while (end < b->size && end - start < limit) {
      if (end != start && (b->roles[end] & (ROLE_CODE_START | ROLE_VECTOR | ROLE_LABEL)))
         break;
      if (b->roles[end] & (ROLE_CODE_START | ROLE_VECTOR)) break;
      ++end;
   }
   for (off = start; off < end; ++off) b->graphics[off] = 1;
}

static void mark_graphics_count(bank_t *b, size_t start, unsigned count)
{
   unsigned i;
   for (i = 0; i < count && start + i < b->size; ++i) {
      if (b->roles[start + i] & (ROLE_CODE_START | ROLE_VECTOR)) break;
      b->graphics[start + i] = 1;
   }
}


static int graphics_pointer_is_used(const analysis_t *a, size_t bi,
                                    uint8_t pointer)
{
   const bank_t *b = &a->banks[bi];
   size_t off;
   for (off = 0; off < b->size; ++off) {
      uint8_t opcode;
      address_mode_t mode;
      unsigned taint;
      if (!(b->roles[off] & ROLE_CODE_START) || b->inst_len[off] < 2u) continue;
      opcode = b->inst_opcode[off];
      mode = (address_mode_t)opcode_modes[opcode];
      if (mode != AM_INDIRECT_INDEXED) continue;
      if (a->rom[b->file_offset + off + 1u] != pointer) continue;
      taint = graphics_load_destination(opcode, mode);
      if (taint && load_feeds_graphics_store(a, bi, off, taint)) return 1;
   }
   return 0;
}

/* Recognize a common 2600 graphics-pointer construction:
 *
 *     LDA low_table,X/Y
 *     STA ptr
 *     LDA #high
 *     STA ptr+1
 *
 * when ptr is subsequently used by an indirect-indexed load that feeds a TIA
 * graphics register. Enumerating the low-byte table recovers animation-frame
 * bases even when the runtime index is not statically known. A constant stride
 * between low bytes is strong evidence for the frame height. */
static void detect_graphics_low_pointer_tables(analysis_t *a, size_t bi)
{
   bank_t *b = &a->banks[bi];
   size_t off;
   for (off = 0; off < b->size; ++off) {
      uint8_t opcode;
      address_mode_t mode;
      uint16_t table_addr;
      size_t table_off;
      size_t p1, p2, p3;
      uint8_t pointer, high;
      size_t count, i;
      unsigned stride = 0;
      uint8_t first_low;

      if (!(b->roles[off] & ROLE_CODE_START) || b->inst_len[off] != 3u) continue;
      opcode = b->inst_opcode[off];
      if (strcmp(opcode_mnemonics[opcode], "LDA") != 0) continue;
      mode = (address_mode_t)opcode_modes[opcode];
      if (mode != AM_ABSOLUTE_X && mode != AM_ABSOLUTE_Y) continue;
      table_addr = (uint16_t)(a->rom[b->file_offset + off + 1u] |
                    ((uint16_t)a->rom[b->file_offset + off + 2u] << 8));
      if (!cart_target_offset(b, table_addr, &table_off)) continue;

      p1 = off + 3u;
      if (p1 >= b->size || !(b->roles[p1] & ROLE_CODE_START) ||
          b->inst_len[p1] != 2u || b->inst_opcode[p1] != 0x85u)
         continue; /* STA zp */
      pointer = a->rom[b->file_offset + p1 + 1u];
      if (!graphics_pointer_is_used(a, bi, pointer)) continue;

      p2 = p1 + 2u;
      p3 = p2 + 2u;
      if (p3 >= b->size || !(b->roles[p2] & ROLE_CODE_START) ||
          b->inst_len[p2] != 2u || b->inst_opcode[p2] != 0xa9u ||
          !(b->roles[p3] & ROLE_CODE_START) || b->inst_len[p3] != 2u ||
          b->inst_opcode[p3] != 0x85u ||
          a->rom[b->file_offset + p3 + 1u] != (uint8_t)(pointer + 1u))
         continue;
      high = a->rom[b->file_offset + p2 + 1u];

      count = 0;
      while (table_off + count < b->size && count < 32u) {
         size_t q = table_off + count;
         if (count != 0u &&
             (b->roles[q] & (ROLE_CODE_START | ROLE_VECTOR | ROLE_LABEL)))
            break;
         ++count;
      }
      if (count < 2u) continue;
      first_low = a->rom[b->file_offset + table_off];
      stride = (unsigned)(uint8_t)(a->rom[b->file_offset + table_off + 1u] - first_low);
      if (stride == 0u || stride > 64u) stride = 0u;
      if (stride) {
         for (i = 2u; i < count; ++i) {
            uint8_t prev = a->rom[b->file_offset + table_off + i - 1u];
            uint8_t cur = a->rom[b->file_offset + table_off + i];
            if ((unsigned)(uint8_t)(cur - prev) != stride) {
               stride = 0u;
               break;
            }
         }
      }

      for (i = 0u; i < count; ++i) {
         uint8_t low = a->rom[b->file_offset + table_off + i];
         uint16_t target = (uint16_t)(low | ((uint16_t)high << 8));
         size_t target_off;
         if (!cart_target_offset(b, target, &target_off)) continue;
         mark_label(b, target_off);
         mark_graphics_count(b, target_off, stride ? stride : 8u);
      }
   }
}

static unsigned popcount8(uint8_t value)
{
   unsigned n = 0;
   while (value) {
      n += value & 1u;
      value >>= 1;
   }
   return n;
}

static int looks_like_8x8_glyph(const analysis_t *a, const bank_t *b,
                                size_t start)
{
   unsigned i;
   unsigned nontrivial = 0;
   unsigned repeated = 0;
   unsigned transitions = 0;
   unsigned pixels = 0;
   if (start + 8u > b->size) return 0;
   for (i = 0; i < 8u; ++i) {
      uint8_t v = a->rom[b->file_offset + start + i];
      if ((b->roles[start + i] & ROLE_VECTOR) || instruction_can_emit(b, start + i)) return 0;
      if (v != 0x00u && v != 0xffu) ++nontrivial;
      pixels += popcount8(v);
      if (i) {
         uint8_t prev = a->rom[b->file_offset + start + i - 1u];
         transitions += popcount8((uint8_t)(prev ^ v));
         if (prev == v) ++repeated;
      }
   }
   return nontrivial >= 6u && repeated >= 1u && repeated <= 5u &&
          pixels >= 10u && pixels <= 48u &&
          transitions >= 4u && transitions <= 20u;
}

/* Provenance is preferable, but long fixed-height font tables can be
 * unmistakable even when their runtime pointer arithmetic is too dynamic to
 * recover statically. Require at least eight consecutive address-aligned 8x8
 * glyph-like blocks. This is deliberately much stricter than recognizing one
 * bitmap-shaped object and has negligible random-data false positives. */
static void detect_structural_8x8_fonts(analysis_t *a, size_t bi)
{
   bank_t *b = &a->banks[bi];
   size_t off;
   for (off = 0; off + 64u <= b->size; ) {
      size_t run = 0;
      uint16_t address = (uint16_t)(b->origin + (uint16_t)off);
      if ((address & 7u) != 0u || b->graphics[off] ||
          !looks_like_8x8_glyph(a, b, off)) {
         ++off;
         continue;
      }
      while (off + (run + 1u) * 8u <= b->size &&
             looks_like_8x8_glyph(a, b, off + run * 8u))
         ++run;
      if (run >= 8u) {
         size_t i;
         b->font_start[off] = 1;
         for (i = 0; i < run * 8u; ++i) b->graphics[off + i] = 1;
         off += run * 8u;
      }
      else ++off;
   }
}

static unsigned infer_countdown_graphics_span(const analysis_t *a, size_t bi,
                                              size_t load_off,
                                              address_mode_t mode)
{
   const bank_t *b = &a->banks[bi];
   uint8_t want_load;
   uint8_t want_dec;
   size_t prev;
   size_t p;
   unsigned steps;
   uint8_t initial;

   if (mode == AM_ABSOLUTE_Y || mode == AM_INDIRECT_INDEXED) {
      want_load = 0xa0u; /* LDY #imm */
      want_dec = 0x88u;  /* DEY */
   }
   else if (mode == AM_ABSOLUTE_X) {
      want_load = 0xa2u; /* LDX #imm */
      want_dec = 0xcau;  /* DEX */
   }
   else return 0;

   if (load_off < 2u) return 0;
   prev = load_off - 2u;
   if (!(b->roles[prev] & ROLE_CODE_START) || b->inst_len[prev] != 2u ||
       b->inst_opcode[prev] != want_load)
      return 0;
   initial = a->rom[b->file_offset + prev + 1u];

   p = load_off;
   for (steps = 0; steps < 10u; ++steps) {
      unsigned len;
      uint8_t op;
      if (!(b->roles[p] & ROLE_CODE_START)) return 0;
      len = b->inst_len[p];
      if (len == 0u || p + len >= b->size) return 0;
      p += len;
      if (!(b->roles[p] & ROLE_CODE_START)) return 0;
      op = b->inst_opcode[p];
      if (op == want_dec) {
         size_t branch = p + 1u;
         uint8_t bop;
         uint16_t pc, target;
         if (branch >= b->size || !(b->roles[branch] & ROLE_CODE_START) ||
             b->inst_len[branch] != 2u)
            return 0;
         bop = b->inst_opcode[branch];
         if (bop != 0x10u && bop != 0xd0u) return 0; /* BPL or BNE */
         pc = (uint16_t)(b->origin + (uint16_t)branch);
         target = (uint16_t)(pc + 2u +
                    (int8_t)a->rom[b->file_offset + branch + 1u]);
         if (target == (uint16_t)(b->origin + (uint16_t)load_off))
            return (unsigned)initial + 1u;
         return 0;
      }
      if (instruction_flow(op) != FLOW_NEXT) return 0;
   }
   return 0;
}

/* Mark raw bytes with strong graphics provenance.  This is intentionally not a
 * blind bitmap-shape guess: an indexed/indirect ROM load into A/X/Y must feed
 * GRP0/GRP1 or PF0/PF1/PF2 along a short straight-line dependency chain.
 * Transfers and simple ALU/shift transforms retain provenance; calls, branches,
 * unknown opcodes, and unrelated loads stop it.  Exact index state marks one
 * byte; unresolved indices mark a bounded table candidate ending at the next
 * known code/vector/label boundary. */
static void detect_graphics_data(analysis_t *a)
{
   size_t bi;
   for (bi = 0; bi < a->bank_count; ++bi) {
      bank_t *b = &a->banks[bi];
      size_t off;
      for (off = 0; off < b->size; ++off) {
         uint8_t opcode;
         address_mode_t mode;
         uint16_t operand;
         uint16_t effective;
         size_t source_off;
         int exact;
         unsigned span;
         unsigned load_taint;
         if (!(b->roles[off] & ROLE_CODE_START) || !b->state_seen[off]) continue;
         opcode = b->inst_opcode[off];
         mode = (address_mode_t)opcode_modes[opcode];
         load_taint = graphics_load_destination(opcode, mode);
         if (!load_taint) continue;
         if (!load_feeds_graphics_store(a, bi, off, load_taint)) continue;
         operand = a->rom[b->file_offset + off + 1u];
         if (b->inst_len[off] >= 3u)
            operand |= (uint16_t)a->rom[b->file_offset + off + 2u] << 8;
         exact = resolve_effective_address(&b->states[off], mode, operand, &effective);
         if (mode == AM_ABSOLUTE) { exact = 1; effective = operand; }
         if (exact && cart_target_offset(b, effective, &source_off)) {
            b->graphics[source_off] = 1;
            continue;
         }
         span = infer_countdown_graphics_span(a, bi, off, mode);
         if (mode == AM_ABSOLUTE_X || mode == AM_ABSOLUTE_Y) {
            if (cart_target_offset(b, operand, &source_off)) {
               if (span) mark_graphics_count(b, source_off, span);
               else mark_graphics_range(b, source_off, 32u);
            }
         }
         else if (mode == AM_INDIRECT_INDEXED) {
            uint16_t pointer;
            if (resolve_zp_word(&b->states[off], (uint8_t)operand, &pointer) &&
                cart_target_offset(b, pointer, &source_off)) {
               if (span) mark_graphics_count(b, source_off, span);
               else mark_graphics_range(b, source_off, 32u);
            }
         }
      }
      detect_graphics_low_pointer_tables(a, bi);
      detect_structural_8x8_fonts(a, bi);
   }
}


static unsigned color_store_source(const analysis_t *a, size_t bi,
                                   size_t off)
{
   const bank_t *b = &a->banks[bi];
   uint8_t opcode;
   address_mode_t mode;
   uint16_t operand;
   hw_symbol_t hw;
   const char *mnemonic;
   unsigned source;
   if (off >= b->size || !(b->roles[off] & ROLE_CODE_START)) return 0;
   opcode = b->inst_opcode[off];
   mnemonic = opcode_mnemonics[opcode];
   if (strcmp(mnemonic, "STA") == 0) source = GRAPHICS_TAINT_A;
   else if (strcmp(mnemonic, "STX") == 0) source = GRAPHICS_TAINT_X;
   else if (strcmp(mnemonic, "STY") == 0) source = GRAPHICS_TAINT_Y;
   else return 0;
   mode = (address_mode_t)opcode_modes[opcode];
   operand = b->inst_len[off] >= 2u ? a->rom[b->file_offset + off + 1u] : 0u;
   if (b->inst_len[off] >= 3u)
      operand |= (uint16_t)a->rom[b->file_offset + off + 2u] << 8;
   if (!hardware_symbol(opcode, mode, operand, &hw)) return 0;
   if (strcmp(hw.name, "COLUP0") != 0 && strcmp(hw.name, "COLUP1") != 0 &&
       strcmp(hw.name, "COLUPF") != 0 && strcmp(hw.name, "COLUBK") != 0)
      return 0;
   return source;
}

static int load_feeds_color_store(const analysis_t *a, size_t bi,
                                  size_t off, unsigned initial_taint)
{
   const bank_t *b = &a->banks[bi];
   size_t p = off;
   unsigned steps;
   unsigned taint = initial_taint;
   for (steps = 0; steps < 8u; ++steps) {
      unsigned len;
      uint8_t opcode;
      address_mode_t mode;
      flow_kind_t flow;
      unsigned store_source;
      if (p >= b->size || !(b->roles[p] & ROLE_CODE_START)) return 0;
      len = b->inst_len[p];
      if (len == 0u || p + len >= b->size) return 0;
      p += len;
      if (!(b->roles[p] & ROLE_CODE_START)) return 0;
      store_source = color_store_source(a, bi, p);
      if (store_source && (store_source & taint)) return 1;
      opcode = b->inst_opcode[p];
      mode = (address_mode_t)opcode_modes[opcode];
      flow = instruction_flow(opcode);
      if (flow != FLOW_NEXT || !advance_graphics_taint(opcode, mode, &taint) ||
          taint == 0u)
         return 0;
   }
   return 0;
}

/* Mark color tables only when an indexed ROM load can be followed along a
 * short straight-line dependency chain into a TIA COLU* register.  Unlike
 * graphics rows, arbitrary palette-looking bytes are never enough by
 * themselves. */
static void detect_color_tables(analysis_t *a)
{
   size_t bi;
   for (bi = 0; bi < a->bank_count; ++bi) {
      bank_t *b = &a->banks[bi];
      size_t off;
      for (off = 0; off < b->size; ++off) {
         uint8_t opcode;
         address_mode_t mode;
         uint16_t operand;
         size_t source_off;
         unsigned span;
         unsigned taint;
         if (!(b->roles[off] & ROLE_CODE_START) || !b->state_seen[off]) continue;
         opcode = b->inst_opcode[off];
         mode = (address_mode_t)opcode_modes[opcode];
         if (mode != AM_ABSOLUTE_X && mode != AM_ABSOLUTE_Y) continue;
         taint = graphics_load_destination(opcode, mode);
         if (!taint || !load_feeds_color_store(a, bi, off, taint)) continue;
         operand = (uint16_t)(a->rom[b->file_offset + off + 1u] |
                  ((uint16_t)a->rom[b->file_offset + off + 2u] << 8));
         if (!cart_target_offset(b, operand, &source_off)) continue;
         span = infer_countdown_graphics_span(a, bi, off, mode);
         if (span < 3u || span > 32u || source_off + span > b->size) continue;
         if (b->roles[source_off] & (ROLE_CODE_START | ROLE_VECTOR)) continue;
         {
            unsigned i;
            int interior_boundary = 0;
            for (i = 1u; i < span; ++i) {
               if ((b->roles[source_off + i] & (ROLE_VECTOR | ROLE_CODE_START)) ||
                   b->graphics[source_off + i] || b->font_start[source_off + i]) {
                  interior_boundary = 1;
                  break;
               }
            }
            if (interior_boundary) continue;
         }
         b->color_start[source_off] = 1u;
         b->color_len[source_off] = (uint8_t)span;
         mark_label(b, source_off);
      }
   }
}

/* Require real pointer-construction data flow before presenting bytes as an
 * interleaved little-endian pointer table.  The conservative pattern is the
 * common 6502 sequence
 *
 *     LDA table,X/Y ; STA zp
 *     LDA table+1,X/Y ; STA zp+1
 *
 * (or the high/low stores in the reverse order).  Merely finding words whose
 * numeric values happen to name meaningful ROM addresses is not sufficient;
 * ordinary byte tables routinely contain such coincidences. */
static int pointer_table_has_builder(const analysis_t *a, size_t bi, size_t table_off)
{
   const bank_t *b = &a->banks[bi];
   uint16_t base = (uint16_t)(b->origin + (uint16_t)table_off);
   size_t pc;
   for (pc = 0; pc + 10u <= b->size; ++pc) {
      uint8_t load1, load2, store1, store2;
      uint16_t op1, op2;
      uint8_t zp1, zp2;
      size_t p1, p2, p3;
      if (!(b->roles[pc] & ROLE_CODE_START)) continue;
      load1 = b->inst_opcode[pc];
      if (load1 != 0xbdu && load1 != 0xb9u) continue; /* LDA abs,X/Y */
      if (b->inst_len[pc] != 3u) continue;
      op1 = read_word(a->rom + b->file_offset + pc + 1u);
      p1 = pc + 3u;
      if (p1 >= b->size || !(b->roles[p1] & ROLE_CODE_START)) continue;
      store1 = b->inst_opcode[p1];
      if (store1 != 0x85u || b->inst_len[p1] != 2u) continue; /* STA zp */
      zp1 = a->rom[b->file_offset + p1 + 1u];
      p2 = p1 + 2u;
      if (p2 >= b->size || !(b->roles[p2] & ROLE_CODE_START)) continue;

      /* Explicit table/table+1 accesses.  This proves pointer construction,
       * although presentation may still decline the .word form when the +1
       * operand creates an interior source label. */
      load2 = b->inst_opcode[p2];
      if (load2 == load1 && b->inst_len[p2] == 3u) {
         op2 = read_word(a->rom + b->file_offset + p2 + 1u);
         p3 = p2 + 3u;
         if (p3 < b->size && (b->roles[p3] & ROLE_CODE_START)) {
            store2 = b->inst_opcode[p3];
            if (store2 == 0x85u && b->inst_len[p3] == 2u) {
               zp2 = a->rom[b->file_offset + p3 + 1u];
               if (op1 == base && op2 == (uint16_t)(base + 1u) &&
                   zp2 == (uint8_t)(zp1 + 1u))
                  return 1;
               if (op1 == (uint16_t)(base + 1u) && op2 == base &&
                   zp1 == (uint8_t)(zp2 + 1u))
                  return 1;
            }
         }
      }

      /* Interleaved .word tables are commonly consumed by incrementing the
       * same index between low and high byte loads.  This form names only the
       * table boundary, so it is especially safe to present as .word data. */
      if ((load1 == 0xbdu && b->inst_opcode[p2] == 0xe8u) || /* INX */
          (load1 == 0xb9u && b->inst_opcode[p2] == 0xc8u)) { /* INY */
         size_t p_load2 = p2 + 1u;
         size_t p_store2;
         if (p_load2 >= b->size || !(b->roles[p_load2] & ROLE_CODE_START) ||
             b->inst_opcode[p_load2] != load1 || b->inst_len[p_load2] != 3u)
            continue;
         op2 = read_word(a->rom + b->file_offset + p_load2 + 1u);
         if (op1 != base || op2 != base) continue;
         p_store2 = p_load2 + 3u;
         if (p_store2 >= b->size || !(b->roles[p_store2] & ROLE_CODE_START) ||
             b->inst_opcode[p_store2] != 0x85u || b->inst_len[p_store2] != 2u)
            continue;
         zp2 = a->rom[b->file_offset + p_store2 + 1u];
         if (zp2 == (uint8_t)(zp1 + 1u)) return 1;
      }
   }
   return 0;
}

/* Conservative little-endian pointer-table recognition.  Require at least
 * three consecutive words, an independently established table boundary, real
 * low/high pointer-construction data flow, and every word to resolve exactly
 * into this bank's runtime mapping. */
static void detect_pointer_tables(analysis_t *a)
{
   size_t bi;
   for (bi = 0; bi < a->bank_count; ++bi) {
      bank_t *b = &a->banks[bi];
      size_t off;
      for (off = 0; off + 6u <= b->size; ++off) {
         size_t words = 0;
         int referenced = 0;
         size_t p;
         /* A pointer table must begin at an independently established source
          * boundary.  ROLE_POSSIBLE alone is not enough: an indexed access to
          * the preceding table can make every following byte look possible and
          * otherwise lets a one-byte-shifted interpretation swallow a real
          * label inside a .word container. */
         if (!(b->roles[off] & ROLE_LABEL) ||
             b->pointer_start[off] || b->graphics[off] || b->color_start[off] ||
             instruction_can_emit(b, off) || (b->roles[off] & ROLE_VECTOR) ||
             !pointer_table_has_builder(a, bi, off))
            continue;
         for (p = off; p + 1u < b->size && words < 32u; p += 2u) {
            uint16_t value;
            size_t toff;
            uint16_t canonical;
            /* emit_pointer_table() emits each word as one indivisible source
             * container.  Never recognize a table across a label that must be
             * emitted at an interior byte or at a later word boundary. */
            if ((p != off && (b->roles[p] & ROLE_LABEL)) ||
                (b->roles[p + 1u] & ROLE_LABEL) ||
                b->graphics[p] || b->graphics[p + 1u] ||
                instruction_can_emit(b, p) || instruction_can_emit(b, p + 1u) ||
                (b->roles[p] & ROLE_VECTOR) || (b->roles[p + 1u] & ROLE_VECTOR))
               break;
            value = read_word(a->rom + b->file_offset + p);
            if (!cart_target_offset(b, value, &toff)) break;
            canonical = (uint16_t)(b->origin + (uint16_t)toff);
            if (canonical != value) break;
            /* A table may not create the evidence for its own targets.  Every
             * destination must already be independently meaningful; otherwise
             * random words in a cartridge window generate convincing nonsense. */
            if (!(b->roles[toff] & (ROLE_CODE_START | ROLE_DATA_READ | ROLE_LABEL)) &&
                !b->graphics[toff] && !b->font_start[toff])
               break;
            if ((b->roles[p] | b->roles[p + 1u]) & (ROLE_DATA_READ | ROLE_POSSIBLE))
               referenced = 1;
            ++words;
         }
         if (words >= 3u && referenced) {
            size_t i;
            b->pointer_start[off] = 1u;
            b->pointer_words[off] = (uint16_t)words;
            mark_label(b, off);
            for (i = 0; i < words; ++i) {
               uint16_t value = read_word(a->rom + b->file_offset + off + i * 2u);
               size_t toff;
               if (cart_target_offset(b, value, &toff)) mark_label(b, toff);
            }
            off += words * 2u - 1u;
         }
      }
   }
}

static void detect_analysis_tables(analysis_t *a)
{
   detect_color_tables(a);
   detect_pointer_tables(a);
}

static int ranges_overlap(size_t a0, size_t a1, size_t b0, size_t b1)
{
   return a0 <= b1 && b0 <= a1;
}

/* Manual presentation hints are authoritative over automatic pretty-printing,
 * but never over established executable bytes.  Cancel any inferred table that
 * would otherwise swallow a manual range; the underlying roles/bytes remain. */
static void cancel_auto_presentations(bank_t *b, size_t first, size_t last)
{
   size_t p;
   for (p = 0; p < b->size; ++p) {
      if (b->pointer_start[p] && !b->pointer_manual[p]) {
         size_t end = p + (size_t)b->pointer_words[p] * 2u;
         if (end != 0u && ranges_overlap(first, last, p, end - 1u)) {
            b->pointer_start[p] = 0u;
            b->pointer_words[p] = 0u;
         }
      }
      if (b->color_start[p]) {
         size_t end = p + (size_t)b->color_len[p];
         if (end != 0u && ranges_overlap(first, last, p, end - 1u)) {
            b->color_start[p] = 0u;
            b->color_len[p] = 0u;
         }
      }
   }
   for (p = first; p <= last; ++p) {
      b->graphics[p] = 0u;
      b->font_start[p] = 0u;
   }
}

static int manual_pointer_can_emit(const bank_t *b, size_t first, size_t last)
{
   size_t p;
   for (p = first; p <= last; ++p) {
      if (b->roles[p] & (ROLE_CODE_BYTE | ROLE_VECTOR)) return 0;
      /* Labels on word boundaries can be emitted between .word directives.
       * A label on the high byte of a word cannot be represented without
       * splitting the user's pointer-table presentation, so keep raw bytes. */
      if (p != first && (b->roles[p] & ROLE_LABEL) && ((p - first) & 1u))
         return 0;
   }
   return 1;
}

/* Apply semantic/presentation hints after automatic recognizers.  --table is a
 * generic definite-data table hint; --pointer additionally requests
 * little-endian .word presentation when that does not hide executable/vector
 * bytes or an odd-byte label.  Code and data remain non-exclusive. */
static int apply_semantic_hints(analysis_t *a, const options_t *opt)
{
   size_t i;
   for (i = 0; i < opt->table_count; ++i) {
      size_t bank, first, last, p;
      bank_t *b;
      if (!hint_range_offsets(a, "table", opt->table_specs[i],
                              &bank, &first, &last)) return 0;
      b = &a->banks[bank];
      for (p = first; p <= last; ++p) {
         if (b->manual_table_byte[p] || b->manual_pointer_byte[p]) {
            fprintf(stderr, "overlapping manual table/pointer hint '%s' in bank %zu\n",
                    opt->table_specs[i], bank);
            return 0;
         }
      }
      cancel_auto_presentations(b, first, last);
      mark_label(b, first);
      b->manual_table_start[first] = 1u;
      for (p = first; p <= last; ++p) {
         b->manual_table_byte[p] = 1u;
         b->roles[p] |= ROLE_DATA_READ;
      }
   }

   for (i = 0; i < opt->pointer_count; ++i) {
      size_t bank, first, last, p;
      size_t bytes;
      bank_t *b;
      if (!hint_range_offsets(a, "pointer", opt->pointer_specs[i],
                              &bank, &first, &last)) return 0;
      bytes = last - first + 1u;
      if (bytes < 2u || (bytes & 1u)) {
         fprintf(stderr,
                 "--pointer range '%s' must contain an even number of bytes\n",
                 opt->pointer_specs[i]);
         return 0;
      }
      b = &a->banks[bank];
      for (p = first; p <= last; ++p) {
         if (b->manual_table_byte[p] || b->manual_pointer_byte[p]) {
            fprintf(stderr, "overlapping manual table/pointer hint '%s' in bank %zu\n",
                    opt->pointer_specs[i], bank);
            return 0;
         }
      }
      cancel_auto_presentations(b, first, last);
      mark_label(b, first);
      b->manual_pointer_start[first] = 1u;
      for (p = first; p <= last; ++p) {
         b->manual_pointer_byte[p] = 1u;
         b->roles[p] |= ROLE_DATA_READ;
      }
      if (manual_pointer_can_emit(b, first, last)) {
         b->pointer_start[first] = 1u;
         b->pointer_words[first] = (uint16_t)(bytes / 2u);
         b->pointer_manual[first] = 1u;
      }
   }
   return 1;
}

static void emit_dynamic_control_comment(FILE *fp, const analysis_t *a,
                                         size_t bi, uint8_t opcode,
                                         uint16_t operand)
{
   const bank_t *b = &a->banks[bi];
   flow_kind_t flow = instruction_flow(opcode);
   if (flow == FLOW_JSR || flow == FLOW_JMP_ABSOLUTE) {
      size_t toff;
      if (!cart_target_offset(b, operand, &toff) ||
          (rom_offset_hidden(a, toff)))
         fputs("    ; control transfer leaves statically decoded cartridge ROM", fp);
   }
   else if (flow == FLOW_JMP_INDIRECT) {
      uint16_t ptr = operand;
      uint16_t high_addr = (uint16_t)((ptr & 0xff00u) |
                           ((uint16_t)(ptr + 1u) & 0x00ffu));
      size_t loff, hoff;
      if (cart_target_offset(b, ptr, &loff) &&
          cart_target_offset(b, high_addr, &hoff)) {
         uint16_t target = (uint16_t)(a->rom[b->file_offset + loff] |
                           ((uint16_t)a->rom[b->file_offset + hoff] << 8));
         size_t toff;
         if (!cart_target_offset(b, target, &toff) ||
             (rom_offset_hidden(a, toff)))
            fputs("    ; indirect control transfer leaves statically decoded cartridge ROM", fp);
      }
      else {
         fputs("    ; indirect control-transfer destination unresolved", fp);
      }
   }
}

static void emit_instruction(FILE *fp, const analysis_t *a, size_t bi, size_t off)
{
   const bank_t *b = &a->banks[bi];
   uint8_t opcode = b->inst_opcode[off];
   address_mode_t mode = (address_mode_t)opcode_modes[opcode];
   const char *mn = opcode_mnemonics[opcode];
   const uint8_t *p = a->rom + b->file_offset + off;
   uint16_t operand = b->inst_len[off] >= 2u ? p[1] : 0;
   hw_symbol_t hw;
   int have_hw = 0;
   if (b->inst_len[off] >= 3u) operand |= (uint16_t)p[2] << 8;
   have_hw = hardware_symbol(opcode, mode, operand, &hw);

   fprintf(fp, "    %s", mn);
   if (mode == AM_RELATIVE) {
      uint16_t pc = (uint16_t)(b->origin + (uint16_t)off);
      uint16_t after = (uint16_t)(pc + 2u);
      uint16_t target = (uint16_t)(after + (int8_t)p[1]);
      int same = (after & 0xff00u) == (target & 0xff00u);
      fprintf(fp, ".%s $%04X", same ? "same" : "cross", target);
      /* Keep the target numeric even when we have a label.  vcsc-as starts
         forward conditional branches in long form and relaxes them later; a
         target at original displacement +125..+127 moves three bytes farther
         away while that provisional long form is present, so a label can make
         an originally valid short branch self-prevent relaxation.  The numeric
         runtime target is fixed and therefore preserves the original two-byte
         branch and its hard page contract exactly. */
      if (target >= b->origin &&
          (uint32_t)target < (uint32_t)b->origin + (uint32_t)b->size &&
          (b->roles[target - b->origin] & ROLE_LABEL)) {
         fputs("    ; target ", fp);
         print_label_name(fp, a, bi, (size_t)(target - b->origin));
      }
   }
   else {
      fprintf(fp, "%s", mode_suffix(opcode, mode, operand));
      switch (mode) {
      case AM_IMPLIED:
         break;
      case AM_ACCUMULATOR:
         fprintf(fp, " A");
         break;
      case AM_IMMEDIATE:
         fprintf(fp, " #$%02X", (unsigned)operand);
         break;
      case AM_ZERO_PAGE:
         fputc(' ', fp);
         if (have_hw) emit_hw_operand(fp, &hw, operand);
         else fprintf(fp, "$%02X", (unsigned)operand);
         break;
      case AM_ZERO_PAGE_X:
         fprintf(fp, " $%02X,X", (unsigned)operand);
         break;
      case AM_ZERO_PAGE_Y:
         fprintf(fp, " $%02X,Y", (unsigned)operand);
         break;
      case AM_ABSOLUTE:
         fputc(' ', fp);
         if (have_hw) {
            emit_hw_operand(fp, &hw, operand);
         }
         else if ((opcode == 0x4cu || opcode == 0x20u) &&
                  is_cart_address(operand)) {
            size_t toff = (size_t)(operand & (uint16_t)(b->size - 1u));
            uint16_t canonical = (uint16_t)(b->origin + (uint16_t)toff);
            if (toff < b->size && canonical == operand &&
                (b->roles[toff] & ROLE_LABEL))
               print_exact_cart_reference(fp, a, bi, toff);
            else
               fprintf(fp, "$%04X", operand);
         }
         else {
            size_t toff;
            uint16_t canonical;
            if (cart_target_offset(b, operand, &toff) &&
                (b->roles[toff] & ROLE_LABEL) &&
                (canonical = (uint16_t)(b->origin + (uint16_t)toff)) == operand)
               print_exact_cart_reference(fp, a, bi, toff);
            else
               fprintf(fp, "$%04X", operand);
         }
         break;
      case AM_ABSOLUTE_X:
      case AM_ABSOLUTE_Y: {
         size_t toff;
         uint16_t canonical;
         fputc(' ', fp);
         if (cart_target_offset(b, operand, &toff) &&
             (b->roles[toff] & ROLE_LABEL) &&
             (canonical = (uint16_t)(b->origin + (uint16_t)toff)) == operand)
            print_exact_cart_reference(fp, a, bi, toff);
         else
            fprintf(fp, "$%04X", operand);
         fprintf(fp, ",%c", mode == AM_ABSOLUTE_X ? 'X' : 'Y');
         break;
      }
      case AM_INDIRECT:
         fprintf(fp, " ($%04X)", operand);
         break;
      case AM_INDEXED_INDIRECT:
         fprintf(fp, " ($%02X,X)", (unsigned)operand);
         break;
      case AM_INDIRECT_INDEXED:
         fprintf(fp, " ($%02X),Y", (unsigned)operand);
         break;
      case AM_RELATIVE:
         break;
      }
   }
   if (have_hw && hw.mirrored)
      fprintf(fp, "    ; mirror of %s ($%04X)", hw.name, hw.canonical);
   else if (!have_hw)
      emit_hardware_rmw_comment(fp, opcode, mode, operand);
   if (a->mapper == MAP_WD &&
       (mode == AM_ZERO_PAGE || mode == AM_ABSOLUTE) &&
       (opcode_memory_access(opcode) & ACCESS_READ)) {
      uint8_t config;
      if (wd_hotspot_config(operand, &config))
         fprintf(fp, "    ; WD selector -> arrangement %u (hardware-delayed)",
                 (unsigned)config);
   }
   emit_dynamic_control_comment(fp, a, bi, opcode, operand);
   if (b->roles[off] & ROLE_OVERLAP)
      fprintf(fp, "    ; overlaps another reachable instruction stream");
   {
      unsigned k;
      int code_as_data = 0;
      for (k = 0; k < b->inst_len[off]; ++k)
         if (b->roles[off + k] & ROLE_DATA_READ) code_as_data = 1;
      if (code_as_data)
         fprintf(fp, "    ; instruction byte/operand also read as data");
   }
   fputc('\n', fp);
}

static int raw_run_end(const bank_t *b, size_t start)
{
   size_t end = start;
   while (end < b->size && end - start < 16u) {
      if (end != start && ((b->roles[end] & ROLE_LABEL) ||
                           b->graphics[end] || b->font_start[end] ||
                           b->color_start[end] || b->pointer_start[end] ||
                           b->manual_table_start[end] || b->manual_pointer_start[end] ||
                           b->manual_table_byte[end] != b->manual_table_byte[start] ||
                           b->manual_pointer_byte[end] != b->manual_pointer_byte[start] ||
                           instruction_can_emit(b, end)))
         break;
      if (b->graphics[end] || b->font_start[end] || b->color_start[end] ||
          b->pointer_start[end] || instruction_can_emit(b, end)) break;
      ++end;
   }
   return (int)end;
}

static void emit_raw_run(FILE *fp, const analysis_t *a, size_t bi,
                         size_t start, size_t end)
{
   const bank_t *b = &a->banks[bi];
   size_t i;
   int unreferenced = 1;
   int overlap = 0;
   int sc_hidden = superchip_active(a) && start < 0x100u && end <= 0x100u;
   for (i = start; i < end; ++i) {
      uint8_t r = b->roles[i];
      if (r & (ROLE_CODE_BYTE | ROLE_DATA_READ | ROLE_POSSIBLE | ROLE_VECTOR))
         unreferenced = 0;
      if (r & ROLE_OVERLAP) overlap = 1;
   }
   if (overlap) fprintf(fp, "    ; overlapping executable bytes; exact raw spelling\n");
   else if (sc_hidden) fprintf(fp, "    ; physical ROM bytes hidden by Superchip RAM window\n");
   else if (unreferenced) fprintf(fp, "    ; unreferenced ROM bytes\n");
   fprintf(fp, "    .byte ");
   for (i = start; i < end; ++i) {
      if (i != start) fputs(", ", fp);
      fprintf(fp, "$%02X", a->rom[b->file_offset + i]);
   }
   fputc('\n', fp);
}


static void emit_label_role_comment(FILE *fp, const bank_t *b, size_t off);

static void emit_color_table(FILE *fp, const analysis_t *a, size_t bi,
                             size_t off)
{
   const bank_t *b = &a->banks[bi];
   unsigned count = b->color_len[off];
   unsigned seg = 0u;
   unsigned i;
   fputs("    ; probable TIA color table (proven COLU* data flow)\n", fp);
   for (i = 1u; i <= count; ++i) {
      int boundary = i == count || (b->roles[off + i] & ROLE_LABEL);
      unsigned j;
      if (!boundary) continue;
      fputs("    .byte ", fp);
      for (j = seg; j < i; ++j) {
         if (j != seg) fputs(", ", fp);
         fprintf(fp, "$%02X", a->rom[b->file_offset + off + j]);
      }
      fputc('\n', fp);
      if (i < count) {
         emit_label_role_comment(fp, b, off + i);
         print_label_name(fp, a, bi, off + i);
         fputs(":\n", fp);
      }
      seg = i;
   }
}

static void emit_pointer_table(FILE *fp, const analysis_t *a, size_t bi,
                               size_t off)
{
   const bank_t *b = &a->banks[bi];
   unsigned words = b->pointer_words[off];
   unsigned i;
   if (b->pointer_manual[off])
      fputs("    ; manual little-endian pointer table hint\n", fp);
   else
      fputs("    ; probable little-endian ROM pointer table\n", fp);
   for (i = 0; i < words; ++i) {
      size_t word_off = off + (size_t)i * 2u;
      uint16_t value = read_word(a->rom + b->file_offset + word_off);
      size_t toff;
      if (i != 0u && (b->roles[word_off] & ROLE_LABEL)) {
         emit_label_role_comment(fp, b, word_off);
         print_label_name(fp, a, bi, word_off);
         fputs(":\n", fp);
      }
      fputs("    .word ", fp);
      if (cart_target_offset(b, value, &toff) &&
          (uint16_t)(b->origin + (uint16_t)toff) == value &&
          (b->roles[toff] & ROLE_LABEL))
         print_exact_cart_reference(fp, a, bi, toff);
      else
         fprintf(fp, "$%04X", value);
      fputc('\n', fp);
   }
}

static void emit_label_role_comment(FILE *fp, const bank_t *b, size_t off)
{
   uint8_t role = b->roles[off];
   if ((role & ROLE_CODE_START) && (role & ROLE_DATA_READ))
      fputs("    ; executable entry also referenced as ROM data\n", fp);
   else if (!(role & ROLE_CODE_START) && (role & ROLE_DATA_READ))
      fputs("    ; definite ROM-data target\n", fp);
   else if (!(role & ROLE_CODE_START) && (role & ROLE_POSSIBLE))
      fputs("    ; possible ROM-data target\n", fp);
}

static void emit_graphics_byte(FILE *fp, uint8_t value)
{
   char binary[9];
   char picture[9];
   unsigned bit;
   for (bit = 0; bit < 8u; ++bit) {
      unsigned mask = 0x80u >> bit;
      binary[bit] = (value & mask) ? '1' : '0';
      picture[bit] = (value & mask) ? 'X' : '.';
   }
   binary[8] = '\0';
   picture[8] = '\0';
   /* vcsc-as currently accepts %01 binary literals.  Keep the human bitmap
    * spelling beside it rather than inventing unparseable X/dot syntax. */
   fprintf(fp, "    .byte %%%s    ; %s\n", binary, picture);
}


typedef struct {
   unsigned inpt[6];
   unsigned swcha_read;
   unsigned swcha_unqualified_read;
   unsigned swcha_write;
   unsigned swcha_port_read[2];
   unsigned joystick_direction[2];
   unsigned vblank_write;
   unsigned vsync_write;
   unsigned driving_left;
   unsigned driving_right;
   unsigned tim64_42;
   unsigned tim64_34;
   unsigned tim64_52;
   unsigned tim64_41;
   unsigned tim64_known[256];
   unsigned tim64_known_total;
   unsigned wsync_3;
   unsigned wsync_30;
   unsigned wsync_36;
   unsigned wsync_37;
   unsigned wsync_45;
   unsigned wsync_192;
   unsigned wsync_228;
   unsigned wsync_ntsc_visible;
   unsigned wsync_pal_visible;
   unsigned wsync_ntsc_blank;
   unsigned wsync_pal_blank;
   int dynamic_probe_attempted;
   int dynamic_probe_available;
   vcsc_video_probe_result_t dynamic_probe;
} inference_evidence_t;

static int decoded_instruction_at(const analysis_t *a, size_t bi, size_t off,
                                  uint8_t *opcode, address_mode_t *mode,
                                  uint16_t *operand)
{
   const bank_t *b = &a->banks[bi];
   unsigned len;
   if (off >= b->size || !(b->roles[off] & ROLE_CODE_START)) return 0;
   len = b->inst_len[off];
   if (len == 0u || off + len > b->size) return 0;
   *opcode = b->inst_opcode[off];
   *mode = (address_mode_t)opcode_modes[*opcode];
   *operand = len >= 2u ? a->rom[b->file_offset + off + 1u] : 0u;
   if (len >= 3u)
      *operand |= (uint16_t)a->rom[b->file_offset + off + 2u] << 8;
   return 1;
}

static int next_code_start(const bank_t *b, size_t off, size_t *next)
{
   unsigned len;
   if (off >= b->size || !(b->roles[off] & ROLE_CODE_START)) return 0;
   len = b->inst_len[off];
   if (len == 0u || off + len >= b->size) return 0;
   *next = off + len;
   return (b->roles[*next] & ROLE_CODE_START) != 0;
}

static int immediate_before_store(const analysis_t *a, size_t bi, size_t off,
                                  uint8_t *value)
{
   const bank_t *b = &a->banks[bi];
   size_t prev;
   if (off < 2u) return 0;
   prev = off - 2u;
   if (!(b->roles[prev] & ROLE_CODE_START) || b->inst_len[prev] != 2u)
      return 0;
   if (b->inst_opcode[prev] != 0xa9u || prev + 2u != off) return 0;
   *value = a->rom[b->file_offset + prev + 1u];
   return 1;
}

static int counted_wsync_loop(const analysis_t *a, size_t bi, size_t off,
                              uint16_t *scanlines)
{
   const bank_t *b = &a->banks[bi];
   uint8_t opcode;
   address_mode_t mode;
   uint16_t operand;
   uint8_t dec_opcode;
   size_t p;
   unsigned steps;
   unsigned wsyncs = 0;
   int saw_dec = 0;
   uint8_t count;

   if (!decoded_instruction_at(a, bi, off, &opcode, &mode, &operand) ||
       mode != AM_IMMEDIATE || (opcode != 0xa2u && opcode != 0xa0u))
      return 0;
   count = (uint8_t)operand;
   if (count == 0u) return 0;
   dec_opcode = opcode == 0xa2u ? 0xcau : 0x88u; /* DEX / DEY */
   if (!next_code_start(b, off, &p)) return 0;

   /* Commercial kernels can do a great deal of work between the counter load
    * and the loop-closing branch.  Sixty-four decoded instructions is still a
    * deliberately bounded recognizer, but is much less VCSC-shaped than the
    * old eight-instruction window. */
   for (steps = 0; steps < 64u; ++steps) {
      hw_symbol_t hw;
      unsigned access;
      uint16_t pc;
      int8_t disp;
      uint16_t target;

      if (!decoded_instruction_at(a, bi, p, &opcode, &mode, &operand)) return 0;
      access = opcode_memory_access(opcode);
      if (hardware_symbol(opcode, mode, operand, &hw) &&
          strcmp(hw.name, "WSYNC") == 0 && (access & ACCESS_WRITE))
         ++wsyncs;
      if (opcode == dec_opcode) saw_dec = 1;
      if (opcode == 0xd0u && mode == AM_RELATIVE && wsyncs && saw_dec) {
         pc = (uint16_t)(b->origin + (uint16_t)p);
         disp = (int8_t)(uint8_t)operand;
         target = (uint16_t)(pc + 2u + disp);
         if (target >= (uint16_t)(b->origin + (uint16_t)(off + 2u)) &&
             target <= pc) {
            unsigned total = (unsigned)count * wsyncs;
            if (total > 0xffffu) total = 0xffffu;
            *scanlines = (uint16_t)total;
            return 1;
         }
      }
      if (!next_code_start(b, p, &p)) return 0;
   }
   return 0;
}

static int swcha_port_mask_pattern(const analysis_t *a, size_t bi, size_t off,
                                   int *port)
{
   const bank_t *b = &a->banks[bi];
   size_t p = off;
   uint8_t opcode;
   address_mode_t mode;
   uint16_t operand;
   hw_symbol_t hw;

   if (!decoded_instruction_at(a, bi, p, &opcode, &mode, &operand) ||
       !hardware_symbol(opcode, mode, operand, &hw) ||
       strcmp(hw.name, "SWCHA") != 0 ||
       !(opcode_memory_access(opcode) & ACCESS_READ))
      return 0;
   if (!next_code_start(b, p, &p)) return 0;
   if (b->inst_opcode[p] != 0x29u || b->inst_len[p] != 2u) return 0;
   if (a->rom[b->file_offset + p + 1u] == 0xf0u) { *port = 0; return 1; }
   if (a->rom[b->file_offset + p + 1u] == 0x0fu) { *port = 1; return 1; }
   return 0;
}

static int swcha_joystick_direction_pattern(const analysis_t *a, size_t bi,
                                             size_t off, int *port)
{
   const bank_t *b = &a->banks[bi];
   size_t p = off;
   uint8_t opcode;
   address_mode_t mode;
   uint16_t operand;
   hw_symbol_t hw;
   uint8_t mask;

   if (!decoded_instruction_at(a, bi, p, &opcode, &mode, &operand) ||
       !hardware_symbol(opcode, mode, operand, &hw) ||
       strcmp(hw.name, "SWCHA") != 0 ||
       !(opcode_memory_access(opcode) & ACCESS_READ))
      return 0;
   if (!next_code_start(b, p, &p)) return 0;
   if (b->inst_opcode[p] != 0x29u || b->inst_len[p] != 2u) return 0;
   mask = a->rom[b->file_offset + p + 1u];
   if (mask == 0x10u || mask == 0x20u || mask == 0x40u || mask == 0x80u) {
      *port = 0;
      return 1;
   }
   if (mask == 0x01u || mask == 0x02u || mask == 0x04u || mask == 0x08u) {
      *port = 1;
      return 1;
   }
   return 0;
}

static int swcha_driving_pattern(const analysis_t *a, size_t bi, size_t off,
                                 int *port)
{
   const bank_t *b = &a->banks[bi];
   size_t p = off;
   uint8_t opcode;
   address_mode_t mode;
   uint16_t operand;
   hw_symbol_t hw;
   unsigned shifts = 0;

   if (!decoded_instruction_at(a, bi, p, &opcode, &mode, &operand) ||
       !hardware_symbol(opcode, mode, operand, &hw) ||
       strcmp(hw.name, "SWCHA") != 0 ||
       !(opcode_memory_access(opcode) & ACCESS_READ))
      return 0;
   if (!next_code_start(b, p, &p)) return 0;
   while (shifts < 4u && b->inst_opcode[p] == 0x4au && b->inst_len[p] == 1u) {
      ++shifts;
      if (!next_code_start(b, p, &p)) return 0;
   }
   if (b->inst_opcode[p] != 0x29u || b->inst_len[p] != 2u ||
       a->rom[b->file_offset + p + 1u] != 0x03u)
      return 0;
   if (shifts == 4u) { *port = 0; return 1; }
   if (shifts == 0u) { *port = 1; return 1; }
   return 0;
}

static int callee_tim64_register(const analysis_t *a, size_t bi,
                                  size_t off, char *reg)
{
   const bank_t *b = &a->banks[bi];
   size_t p = off;
   unsigned steps;
   int a_ok = 1, x_ok = 1, y_ok = 1;

   /* Recognize small timer helper routines that preserve one incoming register
    * until storing it to TIM64T.  This recovers call-site constants that the
    * normal meet-at-join abstract state intentionally discards. */
   for (steps = 0; steps < 24u; ++steps) {
      uint8_t opcode;
      address_mode_t mode;
      uint16_t operand;
      hw_symbol_t hw;
      const char *m;
      unsigned access;

      if (!decoded_instruction_at(a, bi, p, &opcode, &mode, &operand)) return 0;
      m = opcode_mnemonics[opcode];
      access = opcode_memory_access(opcode);
      if (hardware_symbol(opcode, mode, operand, &hw) &&
          strcmp(hw.name, "TIM64T") == 0 && (access & ACCESS_WRITE)) {
         if (strcmp(m, "STA") == 0 && a_ok) { *reg = 'A'; return 1; }
         if (strcmp(m, "STX") == 0 && x_ok) { *reg = 'X'; return 1; }
         if (strcmp(m, "STY") == 0 && y_ok) { *reg = 'Y'; return 1; }
         return 0;
      }

      /* Only track whether the incoming value survives.  Loads/transfers and
       * arithmetic into the corresponding register invalidate that argument;
       * compares, stores, branches, and unrelated register operations do not. */
      if (strcmp(m, "LDA") == 0 || strcmp(m, "TXA") == 0 ||
          strcmp(m, "TYA") == 0 || strcmp(m, "PLA") == 0 ||
          strcmp(m, "ADC") == 0 || strcmp(m, "SBC") == 0 ||
          strcmp(m, "AND") == 0 || strcmp(m, "ORA") == 0 ||
          strcmp(m, "EOR") == 0 ||
          ((strcmp(m, "ASL") == 0 || strcmp(m, "LSR") == 0 ||
            strcmp(m, "ROL") == 0 || strcmp(m, "ROR") == 0) &&
           mode == AM_ACCUMULATOR))
         a_ok = 0;
      if (strcmp(m, "LDX") == 0 || strcmp(m, "TAX") == 0 ||
          strcmp(m, "TSX") == 0 || strcmp(m, "INX") == 0 ||
          strcmp(m, "DEX") == 0)
         x_ok = 0;
      if (strcmp(m, "LDY") == 0 || strcmp(m, "TAY") == 0 ||
          strcmp(m, "INY") == 0 || strcmp(m, "DEY") == 0)
         y_ok = 0;

      if (!next_code_start(b, p, &p)) return 0;
   }
   return 0;
}

static void add_tim64_value(inference_evidence_t *e, uint8_t value)
{
   ++e->tim64_known[value];
   ++e->tim64_known_total;
   if (value == 42u) ++e->tim64_42;
   if (value == 34u) ++e->tim64_34;
   if (value == 52u) ++e->tim64_52;
   if (value == 41u) ++e->tim64_41;
}

static void collect_inference_evidence(const analysis_t *a,
                                       inference_evidence_t *e)
{
   size_t bi;
   memset(e, 0, sizeof(*e));
   for (bi = 0; bi < a->bank_count; ++bi) {
      const bank_t *b = &a->banks[bi];
      size_t off;
      for (off = 0; off < b->size; ++off) {
         uint8_t opcode;
         address_mode_t mode;
         uint16_t operand;
         hw_symbol_t hw;
         unsigned access;
         int drive_port;
         if (!decoded_instruction_at(a, bi, off, &opcode, &mode, &operand))
            continue;
         {
            uint16_t lines;
            if (counted_wsync_loop(a, bi, off, &lines)) {
               if (lines == 3u) ++e->wsync_3;
               if (lines == 30u) ++e->wsync_30;
               if (lines == 36u) ++e->wsync_36;
               if (lines == 37u) ++e->wsync_37;
               if (lines == 45u) ++e->wsync_45;
               if (lines == 192u) ++e->wsync_192;
               if (lines == 228u) ++e->wsync_228;
               if (lines >= 176u && lines <= 208u) ++e->wsync_ntsc_visible;
               if (lines >= 216u && lines <= 244u) ++e->wsync_pal_visible;
               if (lines >= 24u && lines <= 39u) ++e->wsync_ntsc_blank;
               if (lines >= 40u && lines <= 56u) ++e->wsync_pal_blank;
            }
         }
         access = opcode_memory_access(opcode);

         /* A common commercial idiom passes a timer value in A/X/Y to a tiny
          * wait helper.  Preserve call-site alternatives as inference evidence
          * even when the helper entry's joined abstract state is unknown. */
         if (opcode == 0x20u && mode == AM_ABSOLUTE && b->state_seen[off]) {
            size_t toff;
            char reg;
            uint8_t value;
            int known = 0;
            if (cart_target_offset(b, operand, &toff) &&
                callee_tim64_register(a, bi, toff, &reg)) {
               if (reg == 'A' && b->states[off].a_known)
                  value = b->states[off].a, known = 1;
               else if (reg == 'X' && b->states[off].x_known)
                  value = b->states[off].x, known = 1;
               else if (reg == 'Y' && b->states[off].y_known)
                  value = b->states[off].y, known = 1;
               if (known) add_tim64_value(e, value);
            }
         }

         if (!hardware_symbol(opcode, mode, operand, &hw)) continue;
         if (strcmp(hw.name, "SWCHA") == 0) {
            if (access & ACCESS_READ) {
               int mask_port;
               int qualified = 0;
               ++e->swcha_read;
               if (swcha_port_mask_pattern(a, bi, off, &mask_port)) {
                  ++e->swcha_port_read[mask_port];
                  qualified = 1;
               }
               if (swcha_joystick_direction_pattern(a, bi, off, &mask_port)) {
                  ++e->swcha_port_read[mask_port];
                  ++e->joystick_direction[mask_port];
                  qualified = 1;
               }
               if (swcha_driving_pattern(a, bi, off, &drive_port)) {
                  if (drive_port == 0) ++e->driving_left;
                  else ++e->driving_right;
                  if (!qualified || mask_port != drive_port)
                     ++e->swcha_port_read[drive_port];
                  qualified = 1;
               }
               if (!qualified) ++e->swcha_unqualified_read;
            }
            if (access & ACCESS_WRITE) ++e->swcha_write;
         }
         else if (strcmp(hw.name, "VBLANK") == 0 && (access & ACCESS_WRITE)) {
            ++e->vblank_write;
         }
         else if (strcmp(hw.name, "VSYNC") == 0 && (access & ACCESS_WRITE)) {
            ++e->vsync_write;
         }
         else if (strncmp(hw.name, "INPT", 4) == 0 &&
                  hw.name[4] >= '0' && hw.name[4] <= '5' &&
                  (access & ACCESS_READ)) {
            ++e->inpt[(unsigned)(hw.name[4] - '0')];
         }
         else if (strcmp(hw.name, "TIM64T") == 0 && (access & ACCESS_WRITE)) {
            uint8_t value;
            int known = 0;
            if (b->state_seen[off])
               known = known_store_value(opcode, &b->states[off], &value);
            if (!known) known = immediate_before_store(a, bi, off, &value);
            if (known) add_tim64_value(e, value);
         }
      }
   }
   if (e->vsync_write && a->mapper != MAP_DPC && a->mapper != MAP_WD) {
      e->dynamic_probe_attempted = 1;
      e->dynamic_probe_available = vcsc_dynamic_video_probe(
         a->rom, a->rom_size, (int)a->mapper, a->bank_count, a->reset_bank,
         superchip_active(a), &e->dynamic_probe);
   }
}

static int filename_video_hint(const char *path, const char **kind)
{
   const char *base = strrchr(path, '/');
   const char *p;
   char lower[512];
   size_t i, n;
   if (!path) return 0;
   base = base ? base + 1 : path;
   n = strlen(base);
   if (n >= sizeof(lower)) n = sizeof(lower) - 1u;
   for (i = 0; i < n; ++i) lower[i] = (char)tolower((unsigned char)base[i]);
   lower[n] = '\0';

   /* Match format names as tokens, not arbitrary substrings ("pal" in a game
    * title is not evidence).  This mirrors Stella's useful filename-hint idea
    * while keeping it below actual timing evidence. */
   for (p = lower; *p; ++p) {
      if ((p == lower || !isalnum((unsigned char)p[-1])) &&
          strncmp(p, "secam50", 7) == 0 && !isalnum((unsigned char)p[7])) {
         *kind = "SECAM (filename hint)";
         return 1;
      }
      if ((p == lower || !isalnum((unsigned char)p[-1])) &&
          strncmp(p, "pal50", 5) == 0 && !isalnum((unsigned char)p[5])) {
         *kind = "PAL (filename hint)";
         return 1;
      }
      if ((p == lower || !isalnum((unsigned char)p[-1])) &&
          strncmp(p, "ntsc60", 6) == 0 && !isalnum((unsigned char)p[6])) {
         *kind = "NTSC (filename hint)";
         return 1;
      }
      if ((p == lower || !isalnum((unsigned char)p[-1])) &&
          strncmp(p, "secam", 5) == 0 && !isalnum((unsigned char)p[5])) {
         *kind = "SECAM (filename hint)";
         return 1;
      }
      if ((p == lower || !isalnum((unsigned char)p[-1])) &&
          strncmp(p, "ntsc", 4) == 0 && !isalnum((unsigned char)p[4])) {
         *kind = "NTSC (filename hint)";
         return 1;
      }
      if ((p == lower || !isalnum((unsigned char)p[-1])) &&
          strncmp(p, "pal", 3) == 0 && !isalnum((unsigned char)p[3])) {
         *kind = "PAL (filename hint)";
         return 1;
      }
   }
   return 0;
}

static void infer_video(const inference_evidence_t *e, const char *input,
                        const char **kind, const char **confidence)
{
   static char dynamic_kind[160];
   int dynamic_class = 0;
   const vcsc_video_probe_result_t *probe = &e->dynamic_probe;

   if (e->dynamic_probe_available && probe->stable) {
      if (probe->stable_lines >= 240u && probe->stable_lines <= 285u)
         dynamic_class = 1;
      else if (probe->stable_lines >= 290u && probe->stable_lines <= 340u)
         dynamic_class = 2;
   }

   if (dynamic_class == 1) {
      snprintf(dynamic_kind, sizeof(dynamic_kind),
               "NTSC (dynamic stable frame measurement: %u raw line intervals)",
               probe->stable_lines);
      *kind = dynamic_kind;
      *confidence = "high";
      return;
   }
   if (dynamic_class == 2) {
      const char *hint = NULL;
      if (filename_video_hint(input, &hint) &&
          (strncmp(hint, "PAL ", 4) == 0 || strncmp(hint, "SECAM ", 6) == 0)) {
         snprintf(dynamic_kind, sizeof(dynamic_kind),
                  "%.*s (filename hint; dynamic %u-interval 50 Hz confirmation)",
                  strncmp(hint, "PAL ", 4) == 0 ? 3 : 5, hint,
                  probe->stable_lines);
         *kind = dynamic_kind;
         *confidence = "medium";
      }
      else {
         snprintf(dynamic_kind, sizeof(dynamic_kind),
                  "PAL-family (PAL/SECAM ambiguous; dynamic stable frame measurement: %u raw line intervals)",
                  probe->stable_lines);
         *kind = dynamic_kind;
         *confidence = "high";
      }
      return;
   }
   unsigned ntsc_timer = (e->tim64_42 ? 1u : 0u) + (e->tim64_34 ? 1u : 0u);
   unsigned pal_timer = (e->tim64_52 ? 1u : 0u) + (e->tim64_41 ? 1u : 0u);
   unsigned ntsc_scan = (e->wsync_192 ? 2u : 0u) +
                        (e->wsync_37 ? 1u : 0u) + (e->wsync_30 ? 1u : 0u);
   unsigned pal_scan = (e->wsync_228 ? 2u : 0u) +
                       (e->wsync_45 ? 1u : 0u) + (e->wsync_36 ? 1u : 0u);
   unsigned ntsc_score = ntsc_timer * 2u + ntsc_scan;
   unsigned pal_score = pal_timer * 2u + pal_scan;
   unsigned v;
   unsigned ntsc_blank_values = 0;
   unsigned pal_blank_values = 0;

   /* Treat all statically-known timer values as timing evidence, not only the
    * handful used by VCSC's maintained schedulers.  TIM64T ticks are 64 CPU
    * clocks; a 228-tick wait is exactly 192 nominal 76-cycle scanlines and is
    * particularly strong NTSC evidence.  Short blanking timers are deliberately
    * weak because real kernels vary and their ranges overlap. */
   for (v = 1u; v < 256u; ++v) {
      if (!e->tim64_known[v]) continue;
      if (v >= 220u && v <= 240u) ntsc_score += 5u;
      if (v >= 30u && v <= 45u) ++ntsc_blank_values;
      if (v >= 48u && v <= 66u) ++pal_blank_values;
   }
   if (ntsc_blank_values >= 2u) ntsc_score += 2u;
   else if (ntsc_blank_values) ++ntsc_score;
   if (pal_blank_values >= 2u) pal_score += 2u;
   else if (pal_blank_values) ++pal_score;

   ntsc_score += e->wsync_ntsc_visible * 4u + e->wsync_ntsc_blank;
   pal_score += e->wsync_pal_visible * 4u + e->wsync_pal_blank;

   if (ntsc_timer == 2u && pal_timer == 0u) {
      *kind = "NTSC (RIOT 42/34 frame-timer signature)";
      *confidence = "high";
   }
   else if (pal_timer == 2u && ntsc_timer == 0u) {
      *kind = "PAL-family (PAL/SECAM ambiguous; RIOT 52/41 frame-timer signature)";
      *confidence = "high";
   }
   else if (ntsc_scan >= 3u && pal_scan == 0u) {
      *kind = "NTSC (counted WSYNC frame signature)";
      *confidence = "high";
   }
   else if (pal_scan >= 3u && ntsc_scan == 0u) {
      *kind = "PAL-family (PAL/SECAM ambiguous; counted WSYNC frame signature)";
      *confidence = "high";
   }
   else if (ntsc_score >= pal_score + 4u && ntsc_score >= 5u) {
      *kind = "NTSC (general frame-timing evidence)";
      *confidence = "high";
   }
   else if (pal_score >= ntsc_score + 4u && pal_score >= 5u) {
      *kind = "PAL-family (PAL/SECAM ambiguous; general frame-timing evidence)";
      *confidence = "high";
   }
   else if (ntsc_score >= pal_score + 2u && ntsc_score >= 2u) {
      *kind = "NTSC";
      *confidence = "medium";
   }
   else if (pal_score >= ntsc_score + 2u && pal_score >= 2u) {
      *kind = "PAL-family (PAL/SECAM ambiguous)";
      *confidence = "medium";
   }
   else if ((ntsc_timer != 0u || ntsc_scan != 0u) &&
            pal_timer == 0u && pal_scan == 0u) {
      *kind = "NTSC";
      *confidence = "medium";
   }
   else if ((pal_timer != 0u || pal_scan != 0u) &&
            ntsc_timer == 0u && ntsc_scan == 0u) {
      *kind = "PAL-family (PAL/SECAM ambiguous)";
      *confidence = "medium";
   }
   else {
      const char *hint;
      if (filename_video_hint(input, &hint)) {
         *kind = hint;
         *confidence = "medium";
      }
      else {
         *kind = "unknown";
         *confidence = "unknown";
      }
   }
}

static void infer_controller_port(const inference_evidence_t *e, int port,
                                  const char **kind, const char **confidence)
{
   unsigned a = port == 0 ? e->inpt[0] : e->inpt[2];
   unsigned b = port == 0 ? e->inpt[1] : e->inpt[3];
   unsigned fire = port == 0 ? e->inpt[4] : e->inpt[5];
   unsigned drive = port == 0 ? e->driving_left : e->driving_right;

   if (e->swcha_write && a && b && fire) {
      *kind = "keypad";
      *confidence = "high";
   }
   else if (a && b && e->vblank_write) {
      *kind = "paddles";
      *confidence = "high";
   }
   else if (drive && fire) {
      *kind = "driving controller";
      *confidence = "high";
   }
   else if (drive) {
      *kind = "driving controller";
      *confidence = "medium";
   }
   else if (e->swcha_port_read[port] && fire) {
      *kind = "joystick";
      *confidence = "medium";
   }
   else if (e->joystick_direction[port]) {
      *kind = "joystick";
      *confidence = "medium";
   }
   else if (e->swcha_unqualified_read && fire &&
            e->swcha_port_read[0] == 0u && e->swcha_port_read[1] == 0u) {
      *kind = "joystick";
      *confidence = "medium";
   }
   else if (e->swcha_unqualified_read && fire) {
      *kind = "joystick/driving/keypad ambiguous";
      *confidence = "low";
   }
   else if (a || b) {
      *kind = "paddles/keypad ambiguous";
      *confidence = "low";
   }
   else if (fire) {
      *kind = "joystick/driving/keypad ambiguous";
      *confidence = "low";
   }
   else if (e->swcha_port_read[port]) {
      *kind = "joystick/driving ambiguous";
      *confidence = "low";
   }
   else if (e->swcha_unqualified_read) {
      *kind = "joystick/driving ambiguous";
      *confidence = "low";
   }
   else {
      *kind = "unused or unknown";
      *confidence = "low";
   }
}


static void emit_usage_summary(FILE *fp, const analysis_t *a)
{
   size_t bi;
   size_t executed = 0, data = 0, exec_data = 0, overlap = 0;
   size_t possible = 0, unreferenced = 0, vectors = 0, sc_hidden = 0, fa_hidden = 0;
   for (bi = 0; bi < a->bank_count; ++bi) {
      const bank_t *b = &a->banks[bi];
      size_t off;
      for (off = 0; off < b->size; ++off) {
         uint8_t r = b->roles[off];
         int ex = (r & ROLE_CODE_BYTE) != 0;
         int dr = (r & ROLE_DATA_READ) != 0;
         if (ex) ++executed;
         if (dr) ++data;
         if (ex && dr) ++exec_data;
         if (r & ROLE_OVERLAP) ++overlap;
         if (r & ROLE_POSSIBLE) ++possible;
         if (r & ROLE_VECTOR) ++vectors;
         if (a->mapper == MAP_FA && off < 0x200u) ++fa_hidden;
         else if (superchip_active(a) && off < 0x100u) ++sc_hidden;
         else if (!(r & (ROLE_CODE_BYTE | ROLE_DATA_READ | ROLE_POSSIBLE | ROLE_VECTOR)))
            ++unreferenced;
      }
   }
   fprintf(fp,
      "; usage bytes: executed=%zu data-read=%zu exec+data=%zu overlap=%zu possible=%zu vectors=%zu sc-hidden=%zu fa-hidden=%zu unreferenced=%zu\n",
      executed, data, exec_data, overlap, possible, vectors, sc_hidden, fa_hidden, unreferenced);
   fprintf(fp,
      "; speculative analysis: rejected-starts=%zu barriers=%zu islands=%zu\n",
      a->speculative_rejected_starts, a->speculative_barriers,
      a->speculative_islands);
}

static const char *video_override_display(const char *s)
{
   if (strcmp(s, "ntsc") == 0) return "NTSC";
   if (strcmp(s, "pal") == 0) return "PAL";
   if (strcmp(s, "secam") == 0) return "SECAM";
   if (strcmp(s, "pal-family") == 0) return "PAL-family (PAL/SECAM ambiguous)";
   return "unknown";
}

static const char *controller_override_display(const char *s)
{
   if (strcmp(s, "driving") == 0) return "driving controller";
   if (strcmp(s, "unused") == 0) return "unused";
   return s;
}

static void emit_header(FILE *fp, const analysis_t *a, const char *input,
                        const char sha[65])
{
   size_t i;
   fprintf(fp, "; generated by vcsc-disas %s\n", VERSION);
   fprintf(fp, "; input: %s\n", input);
   fprintf(fp, "; input bytes: %zu\n", a->rom_size);
   fprintf(fp, "; input sha256: %s\n", sha);
   {
      const char *mname = mapper_name(a->mapper);
      char scname[32];
      if (superchip_active(a) && a->mapper == MAP_4K) {
         mname = "4KSC";
      }
      else if (superchip_active(a) &&
               (a->mapper == MAP_F8 || a->mapper == MAP_F6 || a->mapper == MAP_F4)) {
         snprintf(scname, sizeof(scname), "%sSC", mname);
         mname = scname;
      }
      if (a->mapper_overridden)
         fprintf(fp, "; mapper: %s (override; %d decoded hotspot access%s, "
                     "%d SC-window candidate%s, %d write%s)\n",
                 mname, a->hotspot_refs, a->hotspot_refs == 1 ? "" : "es",
                 a->superchip_refs, a->superchip_refs == 1 ? "" : "s",
                 a->superchip_write_refs, a->superchip_write_refs == 1 ? "" : "s");
      else
         fprintf(fp, "; mapper: %s (%s confidence; %d decoded hotspot access%s, "
                     "%d SC-window candidate%s, %d write%s)\n",
                 mname,
                 a->mapper == MAP_RAW ? "unknown" :
                    (a->mapper == MAP_DPC || a->mapper == MAP_FA || a->mapper == MAP_WD || a->mapper == MAP_E0 || a->mapper == MAP_CV || a->mapper == MAP_JANE || a->mapper == MAP_0840 || a->mapper == MAP_UA || a->mapper == MAP_UASW || a->mapper == MAP_0FA0 ? "high" :
                     ((a->hotspot_refs || superchip_active(a)) ? "high" : "medium")),
                 a->hotspot_refs, a->hotspot_refs == 1 ? "" : "es",
                 a->superchip_refs, a->superchip_refs == 1 ? "" : "s",
                 a->superchip_write_refs, a->superchip_write_refs == 1 ? "" : "s");
   }
   if (a->mapper != MAP_RAW) {
      if (!a->mapper_overridden && a->mapper_hypotheses_tested > 1u)
         fprintf(fp, "; mapper flow hypotheses: %zu tested, %zu survived%s\n",
                 a->mapper_hypotheses_tested, a->mapper_hypotheses_survived,
                 a->mapper_flow_refined ? "; control flow refined selection" : "");
      fprintf(fp, "; physical banks: %zu x %zu bytes\n",
              a->bank_count, a->bank_size);
      fprintf(fp, "; reset/power-on bank: %zu (%s)\n", a->reset_bank,
              a->reset_bank_overridden ? "override" :
              (a->mapper == MAP_FA ? "FA hardware default" :
               (a->mapper == MAP_JANE ? "JANE hardware default" :
               (a->mapper == MAP_0840 ? "0840 hardware default" :
               ((a->mapper == MAP_UA || a->mapper == MAP_UASW) ? "UA hardware default" :
               (a->mapper == MAP_0FA0 ? "0FA0 hardware default" :
                (a->mapper == MAP_E0 ? "E0 fixed vector bank" :
                 (a->mapper == MAP_WD ? "WD configuration-0 vector bank" : "heuristic"))))))));
      for (i = 0; i < a->bank_count; ++i) {
         const bank_t *b = &a->banks[i];
         if (b->origin_overridden)
            fprintf(fp, "; bank %zu: file $%04zX..$%04zX, origin $%04X, override\n",
                    i, b->file_offset, b->file_offset + b->size - 1u, b->origin);
         else
            fprintf(fp, "; bank %zu: file $%04zX..$%04zX, origin $%04X, score %d%s\n",
                    i, b->file_offset, b->file_offset + b->size - 1u,
                    b->origin, b->origin_score,
                    b->reset_vector_evidence ? ", RESET-vector evidence" : "");
      }
      if (a->mapper == MAP_FA)
         fprintf(fp, "; FA cartridge RAM: write $1000-$10FF, read $1100-$11FF; bank 2 powers up\n");
      if (a->mapper == MAP_CV)
         fprintf(fp, "; CV cartridge RAM: read $1000-$13FF, write $1400-$17FF (1024 bytes)\n");
      if (a->mapper == MAP_JANE)
         fprintf(fp, "; JANE selectors: $1FF0->$0, $1FF1->$1, $1FF8->$2, $1FF9->$3; bank 1 powers up\n");
      if (a->mapper == MAP_0840)
         fprintf(fp, "; 0840 selectors: below-window accesses with A11=1 use A6 ($0800->$0, $0840->$1); bank 0 powers up\n");
      if (a->mapper == MAP_UA)
         fprintf(fp, "; UA selectors: (A & $1260)==$0220->$0, ==$0240->$1; aliases include $02A0/$02C0; bank 0 powers up\n");
      if (a->mapper == MAP_UASW)
         fprintf(fp, "; UASW selectors: UA alias decoder with swapped association ($0220->$1, $0240->$0); bank 0 powers up\n");
      if (a->mapper == MAP_0FA0)
         fprintf(fp, "; 0FA0 selectors: (A & $16E0)==$06A0->$0, ==$06C0->$1; canonical aliases $0FA0/$0FC0; bank 1 powers up\n");
      if (a->mapper == MAP_E0) {
         fprintf(fp, "; E0 segments: $1000-$13FF, $1400-$17FF, $1800-$1BFF are independently banked 1K windows; $1C00-$1FFF is fixed physical bank 7\n");
         fprintf(fp, "; E0 selectors: $1FE0-$1FE7 select segment 0, $1FE8-$1FEF segment 1, $1FF0-$1FF7 segment 2; reset maps physical banks 4,5,6,7\n");
      }
      if (a->mapper == MAP_WD) {
         fprintf(fp, "; WD cartridge RAM: read $1000-$103F, write $1040-$107F (64 bytes)\n");
         fprintf(fp, "; WD selector reads: TIA $30-$3F choose one of eight four-segment 1K arrangements\n");
         fprintf(fp, "; WD power-on arrangement 0: logical 1K banks 0,0,1,3 at $1000,$1400,$1800,$1C00\n");
         if (a->wd_bad_dump)
            fprintf(fp, "; WD 8195-byte preservation form: logical 1K banks 2 and 3 are reversed in the file; final 3 bytes are non-emulated trailing dump data\n");
      }
      if (a->mapper == MAP_DPC) {
         fprintf(fp, "; DPC auxiliary data ROM: file $2000..$27FF (2048 bytes)\n");
         if (a->rom_size > 10240u)
            fprintf(fp, "; DPC RNG table: file $2800..$%04zX (%zu bytes)\n",
                    a->rom_size - 1u, a->rom_size - 10240u);
      }
   }
   else {
      fprintf(fp, "; physical layout: unsupported size; exact raw fallback\n");
   }
   {
      inference_evidence_t e;
      const char *video, *vconf, *ctl0, *c0conf, *ctl1, *c1conf;
      collect_inference_evidence(a, &e);
      infer_video(&e, a->input_name, &video, &vconf);
      infer_controller_port(&e, 0, &ctl0, &c0conf);
      infer_controller_port(&e, 1, &ctl1, &c1conf);
      if (a->video_override)
         fprintf(fp, "; video: %s (override)\n",
                 video_override_display(a->video_override));
      else
         fprintf(fp, "; video: %s (%s confidence)\n", video, vconf);
      if (a->controller_override[0])
         fprintf(fp, "; controller port 0: %s (override)\n",
                 controller_override_display(a->controller_override[0]));
      else
         fprintf(fp, "; controller port 0: %s (%s confidence)\n", ctl0, c0conf);
      if (a->controller_override[1])
         fprintf(fp, "; controller port 1: %s (override)\n",
                 controller_override_display(a->controller_override[1]));
      else
         fprintf(fp, "; controller port 1: %s (%s confidence)\n", ctl1, c1conf);
      if (a->verbose) {
         fprintf(fp, "; evidence: SWCHA read=%u unqualified=%u write=%u port0=%u port1=%u\n",
                 e.swcha_read, e.swcha_unqualified_read, e.swcha_write,
                 e.swcha_port_read[0], e.swcha_port_read[1]);
         fprintf(fp, "; evidence: INPT0..5=%u,%u,%u,%u,%u,%u VBLANK-write=%u driving=%u,%u\n",
                 e.inpt[0], e.inpt[1], e.inpt[2], e.inpt[3], e.inpt[4], e.inpt[5],
                 e.vblank_write, e.driving_left, e.driving_right);
         {
            unsigned v;
            fprintf(fp, "; evidence: TIM64T known values");
            if (e.tim64_known_total == 0u) fputs(" none", fp);
            for (v = 0; v < 256u; ++v)
               if (e.tim64_known[v]) fprintf(fp, " %u(x%u)", v, e.tim64_known[v]);
            fputc('\n', fp);
         }
         fprintf(fp, "; evidence: WSYNC loops exact 3=%u 30=%u 36=%u 37=%u 45=%u 192=%u 228=%u broad Nvis=%u Pvis=%u Nblank=%u Pblank=%u\n",
                 e.wsync_3, e.wsync_30, e.wsync_36, e.wsync_37, e.wsync_45,
                 e.wsync_192, e.wsync_228, e.wsync_ntsc_visible,
                 e.wsync_pal_visible, e.wsync_ntsc_blank, e.wsync_pal_blank);
         if (e.dynamic_probe_attempted) {
            fprintf(fp, "; evidence: dynamic frame probe frames=%u stable=%s lines=%u range=%u..%u halted=%s limit=%s\n",
                    e.dynamic_probe.frames, e.dynamic_probe.stable ? "yes" : "no",
                    e.dynamic_probe.stable_lines, e.dynamic_probe.min_lines,
                    e.dynamic_probe.max_lines, e.dynamic_probe.halted ? "yes" : "no",
                    e.dynamic_probe.instruction_limit ? "yes" : "no");
         }
         fprintf(fp, "; evidence: dynamic control exits=%d unresolved indirect JMP=%d\n",
                 a->dynamic_control_exits, a->unresolved_indirect_jumps);
      }
   }
   emit_usage_summary(fp, a);
   fprintf(fp, "; exact-byte fallback is authoritative where analysis is uncertain\n\n");
}

static void emit_hardware_equates(FILE *fp)
{
   static const char *const lines[] = {
      "VSYNC=$00","VBLANK=$01","WSYNC=$02","RSYNC=$03","NUSIZ0=$04","NUSIZ1=$05",
      "COLUP0=$06","COLUP1=$07","COLUPF=$08","COLUBK=$09","CTRLPF=$0A","REFP0=$0B",
      "REFP1=$0C","PF0=$0D","PF1=$0E","PF2=$0F","RESP0=$10","RESP1=$11","RESM0=$12",
      "RESM1=$13","RESBL=$14","AUDC0=$15","AUDC1=$16","AUDF0=$17","AUDF1=$18",
      "AUDV0=$19","AUDV1=$1A","GRP0=$1B","GRP1=$1C","ENAM0=$1D","ENAM1=$1E",
      "ENABL=$1F","HMP0=$20","HMP1=$21","HMM0=$22","HMM1=$23","HMBL=$24",
      "VDELP0=$25","VDELP1=$26","VDELBL=$27","RESMP0=$28","RESMP1=$29","HMOVE=$2A",
      "HMCLR=$2B","CXCLR=$2C","CXM0P=$30","CXM1P=$31","CXP0FB=$32","CXP1FB=$33",
      "CXM0FB=$34","CXM1FB=$35","CXBLPF=$36","CXPPMM=$37","INPT0=$38","INPT1=$39",
      "INPT2=$3A","INPT3=$3B","INPT4=$3C","INPT5=$3D","SWCHA=$0280","SWACNT=$0281",
      "SWCHB=$0282","SWBCNT=$0283","INTIM=$0284","TIMINT=$0285","TIM1T=$0294",
      "TIM8T=$0295","TIM64T=$0296","T1024T=$0297", NULL
   };
   const char *const *line;
   fputs("; canonical TIA/RIOT symbols used by this disassembly\n", fp);
   for (line = lines; *line; ++line) fprintf(fp, "%s\n", *line);
   fputc('\n', fp);
}


static int vector_slot(const bank_t *b, size_t off, unsigned *slot)
{
   size_t base;
   if (!b->vector_tail_enabled) return 0;
   if (b->size < 6u) return 0;
   base = b->size - 6u;
   if (off < base || off >= b->size || ((off - base) & 1u)) return 0;
   *slot = (unsigned)((off - base) / 2u);
   return *slot < 3u;
}

static int vector_word_can_emit(const bank_t *b, size_t off, unsigned *slot)
{
   if (!vector_slot(b, off, slot)) return 0;
   /* Executable vector bytes must remain independently addressable source.
      Merely having a label on the high byte is not enough to split the word:
      print_exact_cart_reference() can spell that case as low_label + 1. */
   if (b->roles[off] & ROLE_CODE_START) return 0;
   if (b->roles[off + 1u] & ROLE_CODE_START) return 0;
   return 1;
}

static void emit_split_vector_comment(FILE *fp, const analysis_t *a,
                                      size_t bi, size_t off, unsigned slot)
{
   static const char *const names[3] = { "NMI", "RESET", "IRQ/BRK" };
   const bank_t *b = &a->banks[bi];
   uint16_t value = read_word(a->rom + b->file_offset + off);
   fprintf(fp,
           "    ; %s vector = $%04X; vector bytes also participate in executable code\n",
           names[slot], value);
}

static void emit_vector(FILE *fp, const analysis_t *a, size_t bi, size_t off)
{
   static const char *const names[3] = { "NMI", "RESET", "IRQ/BRK" };
   const bank_t *b = &a->banks[bi];
   uint16_t value = read_word(a->rom + b->file_offset + off);
   size_t toff;
   unsigned slot = 0;
   (void)vector_slot(b, off, &slot);
   fprintf(fp, "    .word ");
   if (cart_target_offset(b, value, &toff) &&
       (uint16_t)(b->origin + (uint16_t)toff) == value &&
       (b->roles[toff] & ROLE_LABEL))
      print_exact_cart_reference(fp, a, bi, toff);
   else
      fprintf(fp, "$%04X", value);
   fprintf(fp, "    ; %s vector\n", names[slot]);
}

static void emit_physical_raw_range(FILE *fp, const analysis_t *a,
                                    size_t first, size_t last)
{
   size_t off = first;
   while (off < last) {
      size_t end = off + 8u;
      size_t i;
      if (end > last) end = last;
      fputs("    .byte ", fp);
      for (i = off; i < end; ++i) {
         if (i != off) fputs(", ", fp);
         fprintf(fp, "$%02X", a->rom[i]);
      }
      fputc('\n', fp);
      off = end;
   }
}

static int emit_source(FILE *fp, const analysis_t *a, const char *input,
                       const char sha[65])
{
   size_t bi;
   emit_header(fp, a, input, sha);
   if (analysis_uses_hardware_symbols(a))
      emit_hardware_equates(fp);
   if (a->mapper == MAP_RAW) {
      fprintf(fp, ".org $0000\n");
      emit_physical_raw_range(fp, a, 0u, a->rom_size);
      return ferror(fp) == 0;
   }

   for (bi = 0; bi < a->bank_count; ++bi) {
      const bank_t *b = &a->banks[bi];
      size_t off = 0;
      fprintf(fp, "; ---- physical bank %zu ----\n", bi);
      fprintf(fp, ".org $%04zX\n", b->file_offset);
      fprintf(fp, ".rorg $%04X\n", b->origin);
      while (off < b->size) {
         if (b->manual_table_start[off])
            fputs("    ; manual generic data-table hint\n", fp);
         if (b->manual_pointer_start[off] && !b->pointer_start[off])
            fputs("    ; manual pointer-table data role; primary code/vector/raw representation preserved\n", fp);
         if (b->font_start[off])
            fputs("    ; probable 8x8 font/graphics table\n", fp);
         if (b->spec_seed[off])
            fputs("    ; speculative instruction island validated by HLT/JAM/KIL rejection\n", fp);
         if (b->roles[off] & ROLE_LABEL) {
            emit_label_role_comment(fp, b, off);
            print_label_name(fp, a, bi, off);
            fputs(":\n", fp);
         }
         {
            unsigned vslot;
            if (vector_word_can_emit(b, off, &vslot)) {
               emit_vector(fp, a, bi, off);
               off += 2u;
               continue;
            }
            if (vector_slot(b, off, &vslot))
               emit_split_vector_comment(fp, a, bi, off, vslot);
         }
         if (b->pointer_start[off]) {
            unsigned words = b->pointer_words[off];
            emit_pointer_table(fp, a, bi, off);
            off += (size_t)words * 2u;
         }
         else if (b->color_start[off]) {
            unsigned count = b->color_len[off];
            emit_color_table(fp, a, bi, off);
            off += count;
         }
         else if (instruction_can_emit(b, off)) {
            unsigned len = b->inst_len[off];
            emit_instruction(fp, a, bi, off);
            off += len;
         }
         else if (b->graphics[off]) {
            emit_graphics_byte(fp, a->rom[b->file_offset + off]);
            ++off;
         }
         else {
            int end = raw_run_end(b, off);
            {
               size_t hidden = rom_hidden_prefix(a);
               if (off < hidden && (size_t)end > hidden) end = (int)hidden;
            }
            if ((size_t)end <= off) end = (int)(off + 1u);
            emit_raw_run(fp, a, bi, off, (size_t)end);
            off = (size_t)end;
         }
      }
      fprintf(fp, ".rend\n\n");
   }
   if (a->mapper == MAP_DPC) {
      fputs("; ---- DPC auxiliary 2K display/data ROM ----\n", fp);
      fputs(".org $2000\n", fp);
      emit_physical_raw_range(fp, a, 8192u, a->rom_size < 10240u ? a->rom_size : 10240u);
      if (a->rom_size > 10240u) {
         fputs("\n; ---- DPC random-number table ----\n", fp);
         fprintf(fp, ".org $2800\n");
         emit_physical_raw_range(fp, a, 10240u, a->rom_size);
      }
   }
   if (a->mapper == MAP_WD && a->rom_size > 8192u) {
      fputs("; ---- trailing bytes from 8195-byte WD preservation dump ----\n", fp);
      fputs("; Stella truncates these three bytes for emulation; retain them for exact reconstruction.\n", fp);
      fputs(".org $2000\n", fp);
      emit_physical_raw_range(fp, a, 8192u, a->rom_size);
   }
   return ferror(fp) == 0;
}

static size_t decoded_instruction_count(const analysis_t *a)
{
   size_t bi, off, count = 0u;
   for (bi = 0; bi < a->bank_count; ++bi)
      for (off = 0; off < a->banks[bi].size; ++off)
         if (a->banks[bi].roles[off] & ROLE_CODE_START) ++count;
   return count;
}

int main(int argc, char **argv)
{
   options_t opt;
   char *derived = NULL;
   uint8_t *rom = NULL;
   size_t rom_size = 0;
   analysis_t analysis;
   char sha[65];
   FILE *out = NULL;
   int ok = 0;

   if (!parse_args(argc, argv, &opt)) return 2;
   if (!read_file(opt.input, &rom, &rom_size)) return 1;
   if (!init_analysis(&analysis, rom, rom_size, &opt)) {
      free(rom);
      return 1;
   }
   if (!opt.mapper_override_set && analysis.mapper != MAP_RAW) {
      size_t tested = 0u, survived = 0u;
      int refined = 0;
      mapper_t legacy = analysis.mapper;
      mapper_t selected = refine_mapper_by_control_flow(
         rom, rom_size, legacy, &tested, &survived, &refined);
      if (selected != legacy) {
         options_t selected_opt = opt;
         free_analysis(&analysis);
         selected_opt.mapper_override_set = 1;
         selected_opt.mapper_override = selected;
         selected_opt.superchip_override = -1;
         if (!init_analysis(&analysis, rom, rom_size, &selected_opt)) {
            free(rom);
            return 1;
         }
         /* This was automatic inference, not a user --mapper override. */
         analysis.mapper_overridden = 0;
         analysis.superchip_override = -1;
      }
      analysis.mapper_flow_refined = refined;
      analysis.mapper_hypotheses_tested = tested;
      analysis.mapper_hypotheses_survived = survived;
   }
   if (!apply_layout_overrides(&analysis, &opt)) {
      free_analysis(&analysis);
      free(rom);
      return 1;
   }
   if (!trace_analysis(&analysis, &opt)) {
      fprintf(stderr, "analysis failed\n");
      free_analysis(&analysis);
      free(rom);
      return 1;
   }
   apply_superchip_window_semantics(&analysis);
   promote_interior_reference_labels(&analysis);
   detect_graphics_data(&analysis);
   detect_analysis_tables(&analysis);
   if (!apply_semantic_hints(&analysis, &opt)) {
      free_analysis(&analysis);
      free(rom);
      return 1;
   }
   promote_interior_reference_labels(&analysis);
   if (decoded_instruction_count(&analysis) == 0u) {
      fprintf(stderr, "%s: no instructions found; refusing 100%%-data disassembly\n",
              opt.input);
      free_analysis(&analysis);
      free(rom);
      return 1;
   }
   sha256_hex(rom, rom_size, sha);

   if (!opt.output) {
      derived = derived_output_name(opt.input);
      if (!derived) {
         fprintf(stderr, "out of memory\n");
         goto done;
      }
      opt.output = derived;
   }
   if (strcmp(opt.output, "-") == 0)
      out = stdout;
   else {
      out = fopen(opt.output, "wb");
      if (!out) {
         fprintf(stderr, "%s: %s\n", opt.output, strerror(errno));
         goto done;
      }
   }

   if (!emit_source(out, &analysis, opt.input, sha)) {
      fprintf(stderr, "%s: write failed\n", opt.output);
      goto done;
   }
   if (out != stdout && fclose(out) != 0) {
      out = NULL;
      fprintf(stderr, "%s: close failed: %s\n", opt.output, strerror(errno));
      goto done;
   }
   out = NULL;
   ok = 1;

done:
   if (out && out != stdout) fclose(out);
   free(derived);
   free_analysis(&analysis);
   free(rom);
   return ok ? 0 : 1;
}
