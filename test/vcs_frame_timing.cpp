//! @file vcs_frame_timing.cpp
//! @brief Minimal VCS timing harness used by cartridge regression tests.
//!
//! This is deliberately not a general Atari emulator. It wraps the repository's
//! 6502 core with only the TIA WSYNC/VSYNC behavior and RIOT interval-timer
//! behavior needed to verify stable frame length in the example cartridges.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <vector>

#include "mos6502.h"

namespace {

constexpr uint16_t kRomBase = 0xF000;
constexpr size_t kBankSize = 4096;
constexpr size_t kF8RomSize = 8192;
constexpr uint64_t kCyclesPerScanline = 76;
constexpr uint64_t kExpectedDisplayedScanlines = 262;
// This deliberately minimal harness does not model Stella's full TIA frame
// boundary bookkeeping. Its raw assertion-to-assertion interval is calibrated
// per cartridge against Stella's verified 262-line NTSC display; the source-only
// blank and Ode examples use 263 raw harness lines after phase normalization.
// Do not mistake the harness raw count for displayed scanlines.
constexpr uint64_t kDefaultVsyncIntervalScanlines = 263;
constexpr uint16_t kVsync = 0x0000;
constexpr uint16_t kWsync = 0x0002;
constexpr uint16_t kResp0 = 0x0010;
constexpr uint16_t kResp1 = 0x0011;
constexpr uint16_t kColup0 = 0x0006;
constexpr uint16_t kColup1 = 0x0007;
constexpr uint16_t kGrp0 = 0x001b;
constexpr uint16_t kGrp1 = 0x001c;
constexpr uint16_t kAudc0 = 0x0015;
constexpr uint16_t kAudf0 = 0x0017;
constexpr uint16_t kAudv0 = 0x0019;
constexpr uint16_t kIntim = 0x0284;
constexpr uint16_t kTimint = 0x0285;
constexpr uint16_t kTim1t = 0x0294;
constexpr uint16_t kTim8t = 0x0295;
constexpr uint16_t kTim64t = 0x0296;
constexpr uint16_t kT1024t = 0x0297;
constexpr uint16_t kSwcha = 0x0280;
constexpr uint16_t kSwchb = 0x0282;

struct WriteEvent {
   uint16_t address;
   uint8_t value;
};

uint8_t memory_image[65536];
uint8_t cartridge_image[kF8RomSize];
uint8_t superchip_ram[128];
size_t cartridge_size = 0;
unsigned selected_f8_chunk = 1;

void map_f8_chunk(unsigned chunk) {
   selected_f8_chunk = chunk & 1u;
}

void maybe_select_f8(uint16_t address) {
   if (cartridge_size != kF8RomSize) return;
   const uint16_t bus = address & 0x1fff;
   if (bus == 0x1ff8) map_f8_chunk(0);
   else if (bus == 0x1ff9) map_f8_chunk(1);
}
uint64_t virtual_cycles = 0;
std::vector<WriteEvent> writes;
std::vector<uint64_t> vsync_assertions;
bool vsync_asserted = false;

struct RandomizeZpRange {
   uint16_t address;
   unsigned count;
   unsigned modulus;
   uint32_t state;
};

struct FixedZpWrite {
   uint16_t address;
   uint8_t value;
};

struct ExpectedMemory {
   uint16_t address;
   uint8_t value;
};

struct SweepZpWrite {
   uint16_t address;
   uint8_t minimum;
   uint8_t maximum;
   uint8_t value;
   int direction;
   bool initialized;
};

std::vector<RandomizeZpRange> randomize_zp_ranges;
std::vector<FixedZpWrite> fixed_zp_writes;
std::vector<SweepZpWrite> sweep_zp_writes;
std::vector<ExpectedMemory> expected_memory;
bool released_inputs = false;

struct AsymmetricVisibilityCheck {
   bool enabled = false;
   uint16_t y_address = 0;
   uint16_t color_address = 0;
   uint16_t draw_code_address = 0;
   uint16_t setup_count_address = 0;
   uint8_t lane_color[2] = {0, 0};
   uint8_t seen_mask = 0;
   uint8_t ever_seen_mask = 0;
   uint8_t required_seen_mask = 0;
   uint8_t spread_mask = 0;
   unsigned maximum_spread = 0;
   uint64_t visible_frames[6] = {0, 0, 0, 0, 0, 0};
};

AsymmetricVisibilityCheck asymmetric_visibility;
bool resp_phase_seen[2][kCyclesPerScanline] = {};
uint64_t last_resp_line[2] = {UINT64_MAX, UINT64_MAX};
bool saw_dual_resp_line = false;
bool saw_adjacent_resp_lines = false;
std::vector<unsigned> expected_resp_phases;
std::vector<unsigned> required_resp_phases;

uint8_t next_randomized_zp_value(RandomizeZpRange &range) {
   range.state ^= range.state << 13;
   range.state ^= range.state >> 17;
   range.state ^= range.state << 5;
   return static_cast<uint8_t>(range.state % range.modulus);
}

bool timer_active = false;
uint64_t timer_start = 0;
uint16_t timer_divisor = 1;
uint8_t timer_loaded = 0;
bool timer_overrun_read = false;

uint64_t audv0_writes = 0;
bool saw_audv0_zero = false;
bool saw_audv0_nonzero = false;
bool saw_initial_audv0_zero = false;
bool saw_first_nonzero_audv0 = false;
bool channel0_retuned_while_audible = false;
uint8_t channel0_volume = 0;
uint64_t first_nonzero_audv0_cycle = 0;
std::vector<uint16_t> channel0_write_order;
size_t first_nonzero_audv0_order = 0;

uint8_t timer_value(uint64_t cycle) {
   if (!timer_active) {
      return memory_image[kIntim];
   }

   const uint64_t elapsed = cycle - timer_start;
   const uint64_t ticks = elapsed / timer_divisor;
   if (ticks <= timer_loaded) {
      return static_cast<uint8_t>(timer_loaded - ticks);
   }

   const uint64_t after_underflow = ticks - timer_loaded - 1;
   return static_cast<uint8_t>(255 - (after_underflow & 255));
}

uint8_t read_bus(uint16_t address) {
   maybe_select_f8(address);
   if (cartridge_size == kF8RomSize && (address & 0x1000)) {
      const uint16_t offset = address & 0x0fff;
      if (offset >= 0x0080 && offset <= 0x00ff) {
         return superchip_ram[offset - 0x0080];
      }
      return cartridge_image[selected_f8_chunk * kBankSize + offset];
   }
   if (address == kTimint) {
      if (!timer_active) {
         return memory_image[kTimint];
      }
      const uint64_t ticks = (virtual_cycles - timer_start) / timer_divisor;
      return ticks > timer_loaded ? 0x80 : 0x00;
   }
   if (address == kIntim) {
      if (timer_active) {
         const uint64_t ticks = (virtual_cycles - timer_start) / timer_divisor;
         if (ticks > timer_loaded) {
            timer_overrun_read = true;
         }
      }
      return timer_value(virtual_cycles);
   }
   return memory_image[address];
}

void write_bus(uint16_t address, uint8_t value) {
   maybe_select_f8(address);
   if (cartridge_size == kF8RomSize && (address & 0x1fff) >= 0x1000 &&
       (address & 0x1fff) <= 0x107f) {
      superchip_ram[address & 0x7f] = value;
   }
   else if (!(cartridge_size == kF8RomSize && (address & 0x1000)) &&
            address < kRomBase) {
      memory_image[address] = value;
   }
   writes.push_back({address, value});
}

void clock_cycle(mos6502 *) {
}

void load_timer(uint16_t address, uint8_t value) {
   timer_active = true;
   timer_start = virtual_cycles;
   timer_loaded = value;
   switch (address) {
      case kTim1t: timer_divisor = 1; break;
      case kTim8t: timer_divisor = 8; break;
      case kTim64t: timer_divisor = 64; break;
      case kT1024t: timer_divisor = 1024; break;
      default: std::abort();
   }
}

void verify_asymmetric_previous_frame() {
   if (!asymmetric_visibility.enabled || vsync_assertions.size() <= 2) return;

   unsigned count = memory_image[asymmetric_visibility.setup_count_address];
   if (count > 6) { std::fprintf(stderr, "vcs_frame_timing: asymmetric visibility setup count exceeds six\n"); std::exit(1); }

   uint8_t accepted_mask = 0;
   for (unsigned i = 0; i < count; ++i) {
      const uint8_t code = memory_image[asymmetric_visibility.draw_code_address + i] & 0x0f;
      int id = -1;
      if (code >= 1 && code <= 6) id = code - 1;
      else if (code >= 7 && code <= 12) id = code - 7;
      else { std::fprintf(stderr, "vcs_frame_timing: asymmetric visibility saw invalid draw code\n"); std::exit(1); }
      accepted_mask |= static_cast<uint8_t>(1u << id);
   }

   // Y=0 is the maintained multisprite convention for a completely clipped
   // bottom position.  Such a scheduled sprite is intentionally not required
   // to produce a nonzero GRP write in the visible raster.
   for (unsigned id = 0; id < 6; ++id) {
      if (memory_image[asymmetric_visibility.y_address + id] == 0)
         accepted_mask &= static_cast<uint8_t>(~(1u << id));
   }

   const uint8_t missing = accepted_mask &
      static_cast<uint8_t>(~asymmetric_visibility.seen_mask);
   if (missing) {
      std::fprintf(stderr,
         "vcs_frame_timing: asymmetric frame %zu scheduled mask $%02x "
         "but visible mask was $%02x (missing $%02x)\n",
         vsync_assertions.size(), accepted_mask,
         asymmetric_visibility.seen_mask, missing);
      std::exit(1);
   }

   const uint8_t visible = accepted_mask & asymmetric_visibility.seen_mask;
   for (unsigned id = 0; id < 6; ++id) {
      if (visible & static_cast<uint8_t>(1u << id))
         ++asymmetric_visibility.visible_frames[id];
   }
}

void apply_writes() {
   for (const WriteEvent &event : writes) {
      if (asymmetric_visibility.enabled) {
         if (event.address == kColup0 || event.address == kColup1) {
            const unsigned lane = event.address == kColup1 ? 1u : 0u;
            asymmetric_visibility.lane_color[lane] = event.value;
         }
         else if ((event.address == kGrp0 || event.address == kGrp1) &&
                  event.value != 0) {
            const unsigned lane = event.address == kGrp1 ? 1u : 0u;
            const uint8_t color = asymmetric_visibility.lane_color[lane];
            for (unsigned id = 0; id < 6; ++id) {
               if (memory_image[asymmetric_visibility.color_address + id] == color) {
                  asymmetric_visibility.seen_mask |= static_cast<uint8_t>(1u << id);
                  asymmetric_visibility.ever_seen_mask |= static_cast<uint8_t>(1u << id);
               }
            }
         }
      }
      if (event.address == kResp0 || event.address == kResp1) {
         const unsigned lane = event.address == kResp1 ? 1u : 0u;
         const uint64_t line = virtual_cycles / kCyclesPerScanline;
         resp_phase_seen[lane][virtual_cycles % kCyclesPerScanline] = true;
         const uint64_t other_line = last_resp_line[lane ^ 1u];
         last_resp_line[lane] = line;
         if (other_line == line) saw_dual_resp_line = true;
         if (other_line != UINT64_MAX && other_line + 1 == line) {
            saw_adjacent_resp_lines = true;
         }
      }
      if (event.address == kWsync) {
         const uint64_t within_line = virtual_cycles % kCyclesPerScanline;
         virtual_cycles += within_line ? kCyclesPerScanline - within_line
                                       : kCyclesPerScanline;
      }
      else if (event.address == kVsync) {
         const bool next = (event.value & 2) != 0;
         if (next && !vsync_asserted) {
            verify_asymmetric_previous_frame();
            asymmetric_visibility.seen_mask = 0;
            vsync_assertions.push_back(virtual_cycles);
            // Test-only RAM mutation happens exactly at the synchronized frame
            // boundary, before VBLANK work begins.  This lets renderer tests
            // hammer state-dependent schedulers without spending cartridge
            // overscan cycles generating pseudo-random inputs themselves.
            if (vsync_assertions.size() > 1) {
               for (RandomizeZpRange &range : randomize_zp_ranges) {
                  for (unsigned i = 0; i < range.count; ++i) {
                     memory_image[range.address + i] = next_randomized_zp_value(range);
                  }
               }
               for (SweepZpWrite &write : sweep_zp_writes) {
                  if (!write.initialized) {
                     write.value = write.minimum;
                     write.direction = 1;
                     write.initialized = true;
                  }
                  else if (write.minimum != write.maximum) {
                     if (write.direction > 0 && write.value == write.maximum) {
                        write.direction = -1;
                     }
                     else if (write.direction < 0 && write.value == write.minimum) {
                        write.direction = 1;
                     }
                     write.value = static_cast<uint8_t>(
                        static_cast<int>(write.value) + write.direction);
                  }
                  memory_image[write.address] = write.value;
               }
               for (const FixedZpWrite &write : fixed_zp_writes) {
                  memory_image[write.address] = write.value;
               }
            }
         }
         vsync_asserted = next;
      }
      else if (event.address == kTim1t || event.address == kTim8t ||
               event.address == kTim64t || event.address == kT1024t) {
         load_timer(event.address, event.value);
      }
      else if (event.address == kAudc0 || event.address == kAudf0 ||
               event.address == kAudv0) {
         channel0_write_order.push_back(event.address);
         if ((event.address == kAudc0 || event.address == kAudf0) &&
             channel0_volume != 0) {
            channel0_retuned_while_audible = true;
         }
         if (event.address == kAudv0) {
            channel0_volume = event.value & 0x0f;
            ++audv0_writes;
            saw_audv0_zero |= event.value == 0;
            saw_audv0_nonzero |= event.value != 0;
            if (!saw_first_nonzero_audv0 && event.value == 0) {
               saw_initial_audv0_zero = true;
            }
            if (!saw_first_nonzero_audv0 && event.value != 0) {
               saw_first_nonzero_audv0 = true;
               first_nonzero_audv0_cycle = virtual_cycles;
               first_nonzero_audv0_order = channel0_write_order.size() - 1;
            }
         }
      }
   }
   writes.clear();
}

[[noreturn]] void fail(const char *message) {
   std::fprintf(stderr, "vcs_frame_timing: %s\n", message);
   std::exit(1);
}

} // namespace

int main(int argc, char **argv) {
   if (argc < 3) {
      std::fprintf(stderr,
         "usage: %s ROM.bin VSYNC_ASSERTIONS [--no-audio] [--audio-start-synced] [--audio-retune-muted] [--raw-lines N] [--randomize-zp ADDR COUNT MODULUS SEED]... [--sweep-zp ADDR MIN MAX]... [--set-zp ADDR VALUE]... [--released-inputs] [--expect-memory ADDR VALUE]... [--verify-asymmetric-visibility Y_ADDR COLOR_ADDR DRAW_ADDR COUNT_ADDR] [--require-visible-mask MASK] [--require-visible-spread MASK MAX] [--expect-resp-phases CSV] [--require-resp-phases CSV] [--require-dual-resp] [--require-adjacent-resp]\n",
         argv[0]);
      return 2;
   }

   bool require_audio = true;
   bool require_audio_start_sync = false;
   bool require_audio_retune_muted = false;
   bool require_dual_resp = false;
   bool require_adjacent_resp = false;
   uint64_t expected_raw_lines = kDefaultVsyncIntervalScanlines;
   for (int i = 3; i < argc; ++i) {
      if (std::strcmp(argv[i], "--no-audio") == 0) {
         require_audio = false;
      }
      else if (std::strcmp(argv[i], "--audio-start-synced") == 0) {
         require_audio_start_sync = true;
      }
      else if (std::strcmp(argv[i], "--audio-retune-muted") == 0) {
         require_audio_retune_muted = true;
      }
      else if (std::strcmp(argv[i], "--raw-lines") == 0) {
         if (++i >= argc) {
            fail("--raw-lines requires a value");
         }
         char *raw_end = nullptr;
         const unsigned long raw = std::strtoul(argv[i], &raw_end, 10);
         if (!raw_end || *raw_end != '\0' || raw < 1) {
            fail("bad --raw-lines value");
         }
         expected_raw_lines = static_cast<uint64_t>(raw);
      }
      else if (std::strcmp(argv[i], "--randomize-zp") == 0) {
         if (i + 4 >= argc) {
            fail("--randomize-zp requires ADDR COUNT MODULUS SEED");
         }
         char *parse_end = nullptr;
         const unsigned long address = std::strtoul(argv[++i], &parse_end, 0);
         if (!parse_end || *parse_end != '\0' || address > 0xff) {
            fail("bad --randomize-zp address");
         }
         const unsigned long count = std::strtoul(argv[++i], &parse_end, 0);
         if (!parse_end || *parse_end != '\0' || count < 1 || count > 64 || address + count > 0x100) {
            fail("bad --randomize-zp count");
         }
         const unsigned long modulus = std::strtoul(argv[++i], &parse_end, 0);
         if (!parse_end || *parse_end != '\0' || modulus < 1 || modulus > 256) {
            fail("bad --randomize-zp modulus");
         }
         const unsigned long seed = std::strtoul(argv[++i], &parse_end, 0);
         if (!parse_end || *parse_end != '\0' || seed > 0xffffffffUL || seed == 0) {
            fail("bad --randomize-zp seed");
         }
         randomize_zp_ranges.push_back({
            static_cast<uint16_t>(address), static_cast<unsigned>(count),
            static_cast<unsigned>(modulus), static_cast<uint32_t>(seed)
         });
      }
      else if (std::strcmp(argv[i], "--sweep-zp") == 0) {
         if (i + 3 >= argc) {
            fail("--sweep-zp requires ADDR MIN MAX");
         }
         char *parse_end = nullptr;
         const unsigned long address = std::strtoul(argv[++i], &parse_end, 0);
         if (!parse_end || *parse_end != '\0' || address > 0xff) {
            fail("bad --sweep-zp address");
         }
         const unsigned long minimum = std::strtoul(argv[++i], &parse_end, 0);
         if (!parse_end || *parse_end != '\0' || minimum > 0xff) {
            fail("bad --sweep-zp minimum");
         }
         const unsigned long maximum = std::strtoul(argv[++i], &parse_end, 0);
         if (!parse_end || *parse_end != '\0' || maximum > 0xff || maximum < minimum) {
            fail("bad --sweep-zp maximum");
         }
         sweep_zp_writes.push_back({
            static_cast<uint16_t>(address), static_cast<uint8_t>(minimum),
            static_cast<uint8_t>(maximum), static_cast<uint8_t>(minimum), 1, false
         });
      }
      else if (std::strcmp(argv[i], "--set-zp") == 0) {
         if (i + 2 >= argc) {
            fail("--set-zp requires ADDR VALUE");
         }
         char *parse_end = nullptr;
         const unsigned long address = std::strtoul(argv[++i], &parse_end, 0);
         if (!parse_end || *parse_end != '\0' || address > 0xff) {
            fail("bad --set-zp address");
         }
         const unsigned long value = std::strtoul(argv[++i], &parse_end, 0);
         if (!parse_end || *parse_end != '\0' || value > 0xff) {
            fail("bad --set-zp value");
         }
         fixed_zp_writes.push_back({static_cast<uint16_t>(address), static_cast<uint8_t>(value)});
      }
      else if (std::strcmp(argv[i], "--require-dual-resp") == 0) {
         require_dual_resp = true;
      }
      else if (std::strcmp(argv[i], "--require-adjacent-resp") == 0) {
         require_adjacent_resp = true;
      }
      else if (std::strcmp(argv[i], "--require-resp-phases") == 0) {
         if (++i >= argc) {
            fail("--require-resp-phases requires a comma-separated list");
         }
         const char *cursor = argv[i];
         while (*cursor) {
            char *phase_end = nullptr;
            const unsigned long phase = std::strtoul(cursor, &phase_end, 10);
            if (!phase_end || phase_end == cursor || phase >= kCyclesPerScanline) {
               fail("bad --require-resp-phases value");
            }
            required_resp_phases.push_back(static_cast<unsigned>(phase));
            if (*phase_end == '\0') break;
            if (*phase_end != ',') fail("bad --require-resp-phases value");
            cursor = phase_end + 1;
            if (!*cursor) fail("bad --require-resp-phases value");
         }
         if (required_resp_phases.empty()) fail("bad --require-resp-phases value");
      }
      else if (std::strcmp(argv[i], "--released-inputs") == 0) {
         released_inputs = true;
      }
      else if (std::strcmp(argv[i], "--expect-memory") == 0) {
         if (i + 2 >= argc) {
            fail("--expect-memory requires ADDR VALUE");
         }
         char *address_end = nullptr;
         const unsigned long address = std::strtoul(argv[++i], &address_end, 0);
         if (!address_end || *address_end != '\0' || address > 0xffff) {
            fail("bad --expect-memory address");
         }
         char *value_end = nullptr;
         const unsigned long value = std::strtoul(argv[++i], &value_end, 0);
         if (!value_end || *value_end != '\0' || value > 0xff) {
            fail("bad --expect-memory value");
         }
         expected_memory.push_back({static_cast<uint16_t>(address),
                                    static_cast<uint8_t>(value)});
      }
      else if (std::strcmp(argv[i], "--verify-asymmetric-visibility") == 0) {
         if (i + 4 >= argc) {
            fail("--verify-asymmetric-visibility requires Y_ADDR COLOR_ADDR DRAW_ADDR COUNT_ADDR");
         }
         uint16_t *fields[4] = {
            &asymmetric_visibility.y_address,
            &asymmetric_visibility.color_address,
            &asymmetric_visibility.draw_code_address,
            &asymmetric_visibility.setup_count_address
         };
         for (unsigned field = 0; field < 4; ++field) {
            char *parse_end = nullptr;
            const unsigned long value = std::strtoul(argv[++i], &parse_end, 0);
            if (!parse_end || *parse_end != '\0' || value > 0xffff)
               fail("bad --verify-asymmetric-visibility address");
            *fields[field] = static_cast<uint16_t>(value);
         }
         asymmetric_visibility.enabled = true;
      }
      else if (std::strcmp(argv[i], "--require-visible-mask") == 0) {
         if (++i >= argc) fail("--require-visible-mask requires MASK");
         char *parse_end = nullptr;
         const unsigned long mask = std::strtoul(argv[i], &parse_end, 0);
         if (!parse_end || *parse_end != '\0' || mask > 0x3f)
            fail("bad --require-visible-mask value");
         asymmetric_visibility.required_seen_mask = static_cast<uint8_t>(mask);
      }
      else if (std::strcmp(argv[i], "--require-visible-spread") == 0) {
         if (i + 2 >= argc) fail("--require-visible-spread requires MASK MAX");
         char *mask_end = nullptr;
         const unsigned long mask = std::strtoul(argv[++i], &mask_end, 0);
         if (!mask_end || *mask_end != '\0' || mask == 0 || mask > 0x3f)
            fail("bad --require-visible-spread mask");
         char *spread_end = nullptr;
         const unsigned long spread = std::strtoul(argv[++i], &spread_end, 0);
         if (!spread_end || *spread_end != '\0' || spread > 1000000UL)
            fail("bad --require-visible-spread maximum");
         asymmetric_visibility.spread_mask = static_cast<uint8_t>(mask);
         asymmetric_visibility.maximum_spread = static_cast<unsigned>(spread);
      }
      else if (std::strcmp(argv[i], "--expect-resp-phases") == 0) {
         if (++i >= argc) {
            fail("--expect-resp-phases requires a comma-separated list");
         }
         const char *cursor = argv[i];
         while (*cursor) {
            char *phase_end = nullptr;
            const unsigned long phase = std::strtoul(cursor, &phase_end, 10);
            if (!phase_end || phase_end == cursor || phase >= kCyclesPerScanline) {
               fail("bad --expect-resp-phases value");
            }
            expected_resp_phases.push_back(static_cast<unsigned>(phase));
            if (*phase_end == '\0') break;
            if (*phase_end != ',') fail("bad --expect-resp-phases value");
            cursor = phase_end + 1;
            if (!*cursor) fail("bad --expect-resp-phases value");
         }
         if (expected_resp_phases.empty()) fail("bad --expect-resp-phases value");
      }
      else {
         fail("unknown option");
      }
   }
   const uint64_t expected_raw_cycles = expected_raw_lines * kCyclesPerScanline;

   char *end = nullptr;
   const long requested = std::strtol(argv[2], &end, 10);
   if (!end || *end != '\0' || requested < 10) {
      fail("bad VSYNC assertion count");
   }

   std::memset(memory_image, 0, sizeof(memory_image));
   std::memset(cartridge_image, 0, sizeof(cartridge_image));
   std::memset(superchip_ram, 0, sizeof(superchip_ram));
   std::ifstream rom(argv[1], std::ios::binary | std::ios::ate);
   if (!rom) {
      fail("could not open ROM");
   }
   const std::streamoff rom_size = rom.tellg();
   if (rom_size != static_cast<std::streamoff>(kBankSize) &&
       rom_size != static_cast<std::streamoff>(kF8RomSize)) {
      fail("ROM is not exactly 4096 or 8192 bytes");
   }
   cartridge_size = static_cast<size_t>(rom_size);
   rom.seekg(0, std::ios::beg);
   rom.read(reinterpret_cast<char *>(cartridge_image), rom_size);
   if (rom.gcount() != rom_size) {
      fail("could not read complete ROM");
   }
   if (cartridge_size == kF8RomSize) {
      // F8/F8SC file chunk 1 is the startup bank ($1FF9).  The 6507 only
      // exposes 13 address bits, so banked code linked at $Dxxx and $Fxxx
      // reaches the same cartridge window; read_bus() applies that mirror.
      map_f8_chunk(1);
   }
   else {
      std::memcpy(memory_image + kRomBase, cartridge_image, kBankSize);
   }

   if (released_inputs) {
      memory_image[kSwcha] = 0xff;
      memory_image[kSwchb] = 0xff;
   }

   mos6502 cpu(read_bus, write_bus, clock_cycle);
   cpu.Reset();
   uint64_t cpu_cycles = 0;
   constexpr uint64_t kInstructionLimit = 100000000;

   for (uint64_t instructions = 0;
        instructions < kInstructionLimit &&
        vsync_assertions.size() < static_cast<size_t>(requested);
        ++instructions) {
      writes.clear();
      const uint64_t before = cpu_cycles;
      cpu.Run(1, cpu_cycles, mos6502::INST_COUNT);
      virtual_cycles += cpu_cycles - before;
      apply_writes();
   }

   if (vsync_assertions.size() < static_cast<size_t>(requested)) {
      fail("instruction limit reached before enough frames");
   }
   if (timer_overrun_read) {
      fail("overscan timer underflowed before the player finished");
   }

   // Startup occurs before the first complete measured frame, and the first
   // interval includes reset alignment. From the third interval onward this
   // harness must reproduce its selected Stella-calibrated raw interval; Stella
   // itself reports these cartridges as stable 262-line NTSC frames.
   size_t checked = 0;
   for (size_t i = 3; i < vsync_assertions.size(); ++i) {
      const uint64_t delta = vsync_assertions[i] - vsync_assertions[i - 1];
      const uint64_t interval_lines = delta / kCyclesPerScanline;
      const bool whole_lines = (delta % kCyclesPerScanline) == 0;
      if (!whole_lines || delta != expected_raw_cycles) {
         std::fprintf(stderr,
            "vcs_frame_timing: frame %zu has %llu-cycle VSYNC spacing "
            "(%llu raw harness lines); expected %llu cycles (%llu raw lines), "
            "calibrated against Stella's %llu-line display\n",
            i,
            static_cast<unsigned long long>(delta),
            static_cast<unsigned long long>(interval_lines),
            static_cast<unsigned long long>(expected_raw_cycles),
            static_cast<unsigned long long>(expected_raw_lines),
            static_cast<unsigned long long>(kExpectedDisplayedScanlines));
         return 1;
      }
      ++checked;
   }

   const size_t minimum_checked_frames = require_audio ? 1000 : 40;
   if (checked < minimum_checked_frames) {
      fail("not enough complete frames were checked");
   }
   if (require_audio &&
       (audv0_writes < 64 || !saw_audv0_zero || !saw_audv0_nonzero)) {
      fail("test run did not exercise repeated sounding and silent score steps");
   }
   if (require_audio_retune_muted && channel0_retuned_while_audible) {
      fail("AUDC0/AUDF0 was changed while channel 0 volume was nonzero");
   }
   if (require_audio_start_sync) {
      if (!saw_initial_audv0_zero || !saw_first_nonzero_audv0) {
         fail("audio did not begin from an explicit silent state");
      }
      if (vsync_assertions.empty() ||
          first_nonzero_audv0_cycle <= vsync_assertions.front()) {
         fail("first sounding note began before the first synchronized frame");
      }
      if (first_nonzero_audv0_order < 2 ||
          channel0_write_order[first_nonzero_audv0_order - 2] != kAudc0 ||
          channel0_write_order[first_nonzero_audv0_order - 1] != kAudf0) {
         fail("first note did not program AUDC0/AUDF0 before enabling AUDV0");
      }
   }

   if (require_dual_resp && !saw_dual_resp_line) {
      fail("test run did not exercise a same-scanline RESP0/RESP1 pair");
   }

   if (require_adjacent_resp && !saw_adjacent_resp_lines) {
      fail("test run did not exercise adjacent-line RESP0/RESP1 positioning");
   }

   if (!required_resp_phases.empty()) {
      for (unsigned lane = 0; lane < 2; ++lane) {
         for (unsigned phase : required_resp_phases) {
            if (!resp_phase_seen[lane][phase]) {
               std::fprintf(stderr,
                  "vcs_frame_timing: RESP%u required phase %u was not seen\n",
                  lane, phase);
               return 1;
            }
         }
      }
   }

   for (const ExpectedMemory &expect : expected_memory) {
      if (memory_image[expect.address] != expect.value) {
         std::fprintf(stderr,
            "vcs_frame_timing: memory $%04x expected $%02x, got $%02x\n",
            expect.address, expect.value, memory_image[expect.address]);
         return 1;
      }
   }

   if (asymmetric_visibility.required_seen_mask) {
      if (!asymmetric_visibility.enabled)
         fail("--require-visible-mask needs --verify-asymmetric-visibility");
      const uint8_t missing = asymmetric_visibility.required_seen_mask &
         static_cast<uint8_t>(~asymmetric_visibility.ever_seen_mask);
      if (missing) {
         std::fprintf(stderr,
            "vcs_frame_timing: required visible mask $%02x, saw $%02x "
            "(never saw $%02x)\n",
            asymmetric_visibility.required_seen_mask,
            asymmetric_visibility.ever_seen_mask, missing);
         return 1;
      }
   }

   if (asymmetric_visibility.spread_mask) {
      if (!asymmetric_visibility.enabled)
         fail("--require-visible-spread needs --verify-asymmetric-visibility");
      uint64_t minimum = UINT64_MAX;
      uint64_t maximum = 0;
      for (unsigned id = 0; id < 6; ++id) {
         if (!(asymmetric_visibility.spread_mask & static_cast<uint8_t>(1u << id)))
            continue;
         const uint64_t count = asymmetric_visibility.visible_frames[id];
         if (count < minimum) minimum = count;
         if (count > maximum) maximum = count;
      }
      if (maximum - minimum > asymmetric_visibility.maximum_spread) {
         std::fprintf(stderr,
            "vcs_frame_timing: visible-frame spread %llu exceeds %u for mask $%02x "
            "(counts=%llu,%llu,%llu,%llu,%llu,%llu)\n",
            static_cast<unsigned long long>(maximum - minimum),
            asymmetric_visibility.maximum_spread,
            asymmetric_visibility.spread_mask,
            static_cast<unsigned long long>(asymmetric_visibility.visible_frames[0]),
            static_cast<unsigned long long>(asymmetric_visibility.visible_frames[1]),
            static_cast<unsigned long long>(asymmetric_visibility.visible_frames[2]),
            static_cast<unsigned long long>(asymmetric_visibility.visible_frames[3]),
            static_cast<unsigned long long>(asymmetric_visibility.visible_frames[4]),
            static_cast<unsigned long long>(asymmetric_visibility.visible_frames[5]));
         return 1;
      }
   }

   if (!expected_resp_phases.empty()) {
      bool expected[kCyclesPerScanline] = {};
      for (unsigned phase : expected_resp_phases) expected[phase] = true;
      for (unsigned lane = 0; lane < 2; ++lane) {
         for (unsigned phase = 0; phase < kCyclesPerScanline; ++phase) {
            if (resp_phase_seen[lane][phase] != expected[phase]) {
               std::fprintf(stderr,
                  "vcs_frame_timing: RESP%u phase set mismatch at cycle %u (seen=%u expected=%u)\n",
                  lane, phase, resp_phase_seen[lane][phase] ? 1u : 0u, expected[phase] ? 1u : 0u);
               return 1;
            }
         }
      }
   }

   std::printf("vcs_frame_timing ok: %zu frames at %llu lines, %llu AUDV0 writes\n",
      checked,
      static_cast<unsigned long long>(kExpectedDisplayedScanlines),
      static_cast<unsigned long long>(audv0_writes));
   return 0;
}
