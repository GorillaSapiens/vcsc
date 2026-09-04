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
constexpr size_t kF4RomSize = 32768;
constexpr size_t kMaxRomSize = 512u * 1024u;
constexpr uint64_t kCyclesPerScanline = 76;
constexpr uint64_t kExpectedDisplayedScanlines = 262;
// This deliberately minimal harness does not model Stella's full TIA frame
// boundary bookkeeping. Its raw assertion-to-assertion interval is calibrated
// per cartridge against Stella's verified 262-line NTSC display; the source-only
// blank and Ode examples use 263 raw harness lines after phase normalization.
// Do not mistake the harness raw count for displayed scanlines.
constexpr uint64_t kDefaultVsyncIntervalScanlines = 263;
constexpr uint16_t kVsync = 0x0000;
constexpr uint16_t kVblank = 0x0001;
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
constexpr uint16_t kInpt0 = 0x0038;
constexpr uint16_t kInpt3 = 0x003b;

struct WriteEvent {
   uint16_t address;
   uint8_t value;
};

uint8_t memory_image[65536];
uint8_t cartridge_image[kMaxRomSize];
uint8_t superchip_ram[128];
uint8_t threee_ram[256][1024];
size_t cartridge_size = 0;
enum class CartridgeTimingMapper { Plain, F8, F4SC, ThreeF, ThreeE };
CartridgeTimingMapper cartridge_mapper = CartridgeTimingMapper::Plain;
unsigned selected_f8_chunk = 1;
unsigned selected_f4_chunk = 7;
unsigned selected_three_chunk = 0;
unsigned three_bank_count = 4;
unsigned three_fixed_chunk = 3;
bool threee_ram_selected = false;
unsigned threee_ram_bank = 0;

void map_f8_chunk(unsigned chunk) {
   selected_f8_chunk = chunk & 1u;
}

void maybe_select_banked(uint16_t address) {
   const uint16_t bus = address & 0x1fff;
   if (cartridge_mapper == CartridgeTimingMapper::F8) {
      if (bus == 0x1ff8) map_f8_chunk(0);
      else if (bus == 0x1ff9) map_f8_chunk(1);
   }
   else if (cartridge_mapper == CartridgeTimingMapper::F4SC &&
            bus >= 0x1ff4 && bus <= 0x1ffb) {
      selected_f4_chunk = static_cast<unsigned>(bus - 0x1ff4);
   }
}

bool three_mapper() {
   return cartridge_mapper == CartridgeTimingMapper::ThreeF ||
          cartridge_mapper == CartridgeTimingMapper::ThreeE;
}

bool has_3ex_detector_markers() {
   // Match Stella 7.0 CartDetector::searchForBytes, including its extra
   // one-byte advance after each matched signature.
   unsigned count = 0;
   for (size_t i = 0; i < cartridge_size - 3u; ++i) {
      if (std::memcmp(cartridge_image + i, "3EX", 3) == 0) {
         if (++count >= 2u)
            return true;
         i += 3u;
      }
   }
   return false;
}

uint8_t read_three_cartridge(uint16_t address) {
   const uint16_t bus = address & 0x1fff;
   if (bus >= 0x1800) {
      return cartridge_image[three_fixed_chunk * 0x0800u + (bus - 0x1800u)];
   }
   if (cartridge_mapper == CartridgeTimingMapper::ThreeE && threee_ram_selected) {
      if (bus < 0x1400)
         return threee_ram[threee_ram_bank][bus - 0x1000u];
      return 0xff;
   }
   return cartridge_image[selected_three_chunk * 0x0800u + (bus - 0x1000u)];
}
uint64_t virtual_cycles = 0;
std::vector<WriteEvent> writes;
std::vector<uint64_t> vsync_assertions;
std::vector<uint64_t> vsync_deassertions;
bool vsync_asserted = false;

struct RandomizeZpRange {
   uint16_t address;
   unsigned count;
   unsigned modulus;
   uint32_t state;
   unsigned hold_frames;
   unsigned frames_until_refresh;
};

struct FixedZpWrite {
   uint16_t address;
   uint8_t value;
};

// Test-only external/input mutation applied exactly at synchronized frame
// boundaries.  Unlike the older ZP helpers, this accepts the full 16-bit bus
// address so controller registers such as SWCHA/SWCHB can be exercised.
struct FrameMemorySequence {
   uint16_t address;
   std::vector<uint8_t> values;
   size_t index = 0;
};

struct ReadMemorySequence {
   uint16_t address;
   std::vector<uint8_t> values;
   size_t index = 0;
};

struct ExpectedMemory {
   uint16_t address;
   uint8_t value;
};

struct ExpectedMemoryEqualRange {
   uint16_t address;
   unsigned count;
};

struct RawLineMemoryRule {
   uint8_t value;
   uint64_t lines;
};

struct RawLineMemoryOracle {
   bool enabled = false;
   uint16_t address = 0;
   std::vector<RawLineMemoryRule> rules;
};

// Verify that a TIA register is written at the same CPU-cycle phases on one
// selected frame-relative scanline. This catches horizontal renderer jitter
// that a frame-length-only oracle cannot see.
struct StableTiaWritePhase {
   uint16_t address = 0;
   uint64_t line = 0;
   bool reference[kCyclesPerScanline] = {};
   bool current[kCyclesPerScanline] = {};
   bool have_reference = false;
   size_t checked_frames = 0;
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

struct DumpZpRange {
   uint16_t address;
   unsigned count;
};
std::vector<DumpZpRange> dump_zp_ranges;
uint64_t live_expected_raw_cycles = 0;

std::vector<FixedZpWrite> fixed_zp_writes;
std::vector<SweepZpWrite> sweep_zp_writes;
std::vector<FrameMemorySequence> frame_memory_sequences;
std::vector<ReadMemorySequence> read_memory_sequences;
std::vector<ExpectedMemory> expected_memory;
std::vector<ExpectedMemoryEqualRange> expected_memory_equal_ranges;
RawLineMemoryOracle raw_line_memory_oracle;
std::vector<StableTiaWritePhase> stable_tia_write_phases;
std::vector<uint64_t> frame_expected_raw_cycles;
bool released_inputs = false;
bool paddle_inputs = false;
bool paddle_dumped = true;
uint64_t paddle_release_cycle = 0;
uint64_t paddle_threshold_cycles[4] = {0,0,0,0};

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
   uint8_t stable_first_line_mask = 0;
   int first_visible_line[6] = {-1, -1, -1, -1, -1, -1};
   int reference_first_line[6] = {-1, -1, -1, -1, -1, -1};
   uint16_t graphics_address = 0;
   uint8_t exact_glyph_mask = 0;
   uint8_t exact_glyph_rows[6] = {0, 0, 0, 0, 0, 0};
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

uint8_t peek_memory(uint16_t address) {
   const uint16_t bus = address & 0x1fff;
   if ((cartridge_mapper == CartridgeTimingMapper::F8 ||
        cartridge_mapper == CartridgeTimingMapper::F4SC) &&
       (bus & 0x1000)) {
      const uint16_t offset = bus & 0x0fff;
      if (offset >= 0x0080 && offset <= 0x00ff) {
         return superchip_ram[offset - 0x0080];
      }
   }
   if (cartridge_mapper == CartridgeTimingMapper::ThreeE &&
       threee_ram_selected && bus >= 0x1000 && bus < 0x1400) {
      return threee_ram[threee_ram_bank][bus - 0x1000];
   }
   return memory_image[address];
}

uint64_t raw_lines_for_memory_value(uint8_t value) {
   for (const RawLineMemoryRule &rule : raw_line_memory_oracle.rules) {
      if (rule.value == value) return rule.lines;
   }
   std::fprintf(stderr,
      "vcs_frame_timing: no raw-line mapping for memory $%04x value $%02x\n",
      raw_line_memory_oracle.address, value);
   std::exit(1);
}

uint8_t read_bus(uint16_t address) {
   if (paddle_inputs && address >= kInpt0 && address <= kInpt3) {
      if (paddle_dumped) return 0;
      const unsigned channel = static_cast<unsigned>(address - kInpt0);
      return virtual_cycles - paddle_release_cycle >= paddle_threshold_cycles[channel]
         ? 0x80 : 0x00;
   }
   for (ReadMemorySequence &sequence : read_memory_sequences) {
      if (sequence.address == address) {
         const uint8_t value = sequence.values[sequence.index];
         sequence.index = (sequence.index + 1) % sequence.values.size();
         return value;
      }
   }
   maybe_select_banked(address);
   if (three_mapper() && (address & 0x1000))
      return read_three_cartridge(address);
   if (cartridge_mapper == CartridgeTimingMapper::F8 && (address & 0x1000)) {
      const uint16_t offset = address & 0x0fff;
      if (offset >= 0x0080 && offset <= 0x00ff) {
         return superchip_ram[offset - 0x0080];
      }
      return cartridge_image[selected_f8_chunk * kBankSize + offset];
   }
   if (cartridge_mapper == CartridgeTimingMapper::F4SC && (address & 0x1000)) {
      const uint16_t offset = address & 0x0fff;
      if (offset >= 0x0080 && offset <= 0x00ff) {
         return superchip_ram[offset - 0x0080];
      }
      return cartridge_image[selected_f4_chunk * kBankSize + offset];
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
   maybe_select_banked(address);
   const uint16_t bus = address & 0x1fff;
   if (cartridge_mapper == CartridgeTimingMapper::ThreeF && bus <= 0x003f) {
      selected_three_chunk = static_cast<unsigned>(value) % three_bank_count;
      threee_ram_selected = false;
   }
   else if (cartridge_mapper == CartridgeTimingMapper::ThreeE && bus == 0x003f) {
      selected_three_chunk = static_cast<unsigned>(value) % three_bank_count;
      threee_ram_selected = false;
   }
   else if (cartridge_mapper == CartridgeTimingMapper::ThreeE && bus == 0x003e) {
      threee_ram_bank = value;
      threee_ram_selected = true;
   }
   if (cartridge_mapper == CartridgeTimingMapper::ThreeE && threee_ram_selected &&
       bus >= 0x1400 && bus < 0x1800) {
      threee_ram[threee_ram_bank][bus - 0x1400u] = value;
   }
   else if ((cartridge_mapper == CartridgeTimingMapper::F8 ||
             cartridge_mapper == CartridgeTimingMapper::F4SC) &&
            bus >= 0x1000 && bus <= 0x107f) {
      superchip_ram[address & 0x7f] = value;
   }
   else if (!(three_mapper() && (address & 0x1000)) &&
            !(cartridge_mapper == CartridgeTimingMapper::F8 && (address & 0x1000)) &&
            !(cartridge_mapper == CartridgeTimingMapper::F4SC && (address & 0x1000)) &&
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

   if (asymmetric_visibility.exact_glyph_mask) {
      const uint8_t required = accepted_mask & asymmetric_visibility.exact_glyph_mask;
      for (unsigned id = 0; id < 6; ++id) {
         if (!(required & static_cast<uint8_t>(1u << id))) continue;
         if (asymmetric_visibility.exact_glyph_rows[id] != 8) {
            std::fprintf(stderr,
               "vcs_frame_timing: asymmetric frame %zu sprite %u emitted %u exact glyph rows; expected 8\n",
               vsync_assertions.size(), id, asymmetric_visibility.exact_glyph_rows[id]);
            std::exit(1);
         }
      }
   }

   const uint8_t visible = accepted_mask & asymmetric_visibility.seen_mask;
   for (unsigned id = 0; id < 6; ++id) {
      if (visible & static_cast<uint8_t>(1u << id)) {
         ++asymmetric_visibility.visible_frames[id];
         if (asymmetric_visibility.stable_first_line_mask & static_cast<uint8_t>(1u << id)) {
            const int line = asymmetric_visibility.first_visible_line[id];
            if (line < 0) {
               std::fprintf(stderr,
                  "vcs_frame_timing: sprite %u was visible but has no first-line sample\n", id);
               std::exit(1);
            }
            int &reference = asymmetric_visibility.reference_first_line[id];
            if (reference < 0) reference = line;
            else if (line != reference) {
               std::fprintf(stderr,
                  "vcs_frame_timing: sprite %u first visible line jittered from %d to %d\n",
                  id, reference, line);
               std::exit(1);
            }
         }
      }
   }
}

void verify_stable_tia_write_phase_previous_frame() {
   for (StableTiaWritePhase &rule : stable_tia_write_phases) {
      if (vsync_assertions.size() >= 3) {
         if (!rule.have_reference) {
            for (unsigned phase = 0; phase < kCyclesPerScanline; ++phase)
               rule.reference[phase] = rule.current[phase];
            rule.have_reference = true;
         }
         else {
            for (unsigned phase = 0; phase < kCyclesPerScanline; ++phase) {
               if (rule.reference[phase] == rule.current[phase]) continue;
               std::fprintf(stderr,
                  "vcs_frame_timing: TIA $%02x write phases jittered on line %llu at frame %zu (phase %u)\n",
                  static_cast<unsigned>(rule.address),
                  static_cast<unsigned long long>(rule.line),
                  vsync_assertions.size(), phase);
               std::exit(1);
            }
         }
         ++rule.checked_frames;
      }
      for (unsigned phase = 0; phase < kCyclesPerScanline; ++phase)
         rule.current[phase] = false;
   }
}

void apply_writes() {
   for (const WriteEvent &event : writes) {
      // 3F owns writes in $00-$3F.  Treat classic 3E the same way here so
      // mapper-profile timing remains valid even on implementations that do
      // not forward the cartridge-owned low page to TIA.  Both families can
      // always reach TIA through its $40-$7F mirror.
      const bool tia_write = event.address < 0x0080u &&
         (!three_mapper() || event.address >= 0x0040u);
      const uint16_t tia_address = tia_write
         ? static_cast<uint16_t>(event.address & 0x003fu) : event.address;
      if (tia_write && !vsync_assertions.empty()) {
         const uint64_t frame_line =
            (virtual_cycles - vsync_assertions.back()) / kCyclesPerScanline;
         const unsigned phase = static_cast<unsigned>(virtual_cycles % kCyclesPerScanline);
         for (StableTiaWritePhase &rule : stable_tia_write_phases) {
            if (rule.address == tia_address && rule.line == frame_line)
               rule.current[phase] = true;
         }
      }
      if (asymmetric_visibility.enabled && tia_write) {
         if (tia_address == kColup0 || tia_address == kColup1) {
            const unsigned lane = tia_address == kColup1 ? 1u : 0u;
            asymmetric_visibility.lane_color[lane] = event.value;
         }
         else if ((tia_address == kGrp0 || tia_address == kGrp1) &&
                  event.value != 0) {
            const unsigned lane = tia_address == kGrp1 ? 1u : 0u;
            const uint8_t color = asymmetric_visibility.lane_color[lane];
            for (unsigned id = 0; id < 6; ++id) {
               if (memory_image[asymmetric_visibility.color_address + id] == color) {
                  if (asymmetric_visibility.exact_glyph_mask & static_cast<uint8_t>(1u << id)) {
                     const unsigned row = asymmetric_visibility.exact_glyph_rows[id];
                     if (row >= 8) {
                        std::fprintf(stderr,
                           "vcs_frame_timing: asymmetric frame %zu sprite %u emitted extra nonzero glyph byte $%02x\n",
                           vsync_assertions.size(), id, event.value);
                        std::exit(1);
                     }
                     const uint16_t expected_address = static_cast<uint16_t>(
                        asymmetric_visibility.graphics_address + 104u + 8u * id - row);
                     const uint8_t expected = memory_image[expected_address];
                     if (event.value != expected) {
                        std::fprintf(stderr,
                           "vcs_frame_timing: asymmetric frame %zu sprite %u glyph row %u was $%02x; expected $%02x\n",
                           vsync_assertions.size(), id, row, event.value, expected);
                        std::exit(1);
                     }
                     ++asymmetric_visibility.exact_glyph_rows[id];
                  }
                  asymmetric_visibility.seen_mask |= static_cast<uint8_t>(1u << id);
                  asymmetric_visibility.ever_seen_mask |= static_cast<uint8_t>(1u << id);
                  if (asymmetric_visibility.first_visible_line[id] < 0 &&
                      !vsync_assertions.empty()) {
                     asymmetric_visibility.first_visible_line[id] = static_cast<int>(
                        (virtual_cycles - vsync_assertions.back()) / kCyclesPerScanline);
                  }
               }
            }
         }
      }
      if (tia_write && (tia_address == kResp0 || tia_address == kResp1)) {
         const unsigned lane = tia_address == kResp1 ? 1u : 0u;
         const uint64_t line = virtual_cycles / kCyclesPerScanline;
         resp_phase_seen[lane][virtual_cycles % kCyclesPerScanline] = true;
         const uint64_t other_line = last_resp_line[lane ^ 1u];
         last_resp_line[lane] = line;
         if (other_line == line) saw_dual_resp_line = true;
         if (other_line != UINT64_MAX && other_line + 1 == line) {
            saw_adjacent_resp_lines = true;
         }
      }
      if (tia_write && tia_address == kWsync) {
         const uint64_t within_line = virtual_cycles % kCyclesPerScanline;
         virtual_cycles += within_line ? kCyclesPerScanline - within_line
                                       : kCyclesPerScanline;
      }
      else if (tia_write && tia_address == kVblank) {
         if (paddle_inputs) {
            const bool next_dumped = (event.value & 0x80) != 0;
            if (paddle_dumped && !next_dumped) paddle_release_cycle = virtual_cycles;
            paddle_dumped = next_dumped;
         }
      }
      else if (tia_write && tia_address == kVsync) {
         const bool next = (event.value & 2) != 0;
         if (!next && vsync_asserted) {
            vsync_deassertions.push_back(virtual_cycles);
         }
         if (next && !vsync_asserted) {
            verify_stable_tia_write_phase_previous_frame();
            verify_asymmetric_previous_frame();
            asymmetric_visibility.seen_mask = 0;
            for (unsigned id = 0; id < 6; ++id) {
               asymmetric_visibility.first_visible_line[id] = -1;
               asymmetric_visibility.exact_glyph_rows[id] = 0;
            }
            vsync_assertions.push_back(virtual_cycles);
            // Check the frame that just ended before mutating RAM for the next
            // one, so a failure dump identifies the exact held layout that
            // produced the bad interval rather than its successor.
            if (vsync_assertions.size() > 3) {
               const size_t n = vsync_assertions.size();
               const uint64_t delta = vsync_assertions[n - 1] - vsync_assertions[n - 2];
               const uint64_t live_expected = raw_line_memory_oracle.enabled
                  ? frame_expected_raw_cycles[n - 2]
                  : live_expected_raw_cycles;
               if (live_expected && delta != live_expected) {
                  std::fprintf(stderr,
                     "vcs_frame_timing: live frame %zu has %llu cycles (%llu raw lines); expected %llu\n",
                     n - 1,
                     static_cast<unsigned long long>(delta),
                     static_cast<unsigned long long>(delta / kCyclesPerScanline),
                     static_cast<unsigned long long>(live_expected));
                  for (const DumpZpRange &range : dump_zp_ranges) {
                     std::fprintf(stderr, "  zp[$%02x..$%02x]=", range.address,
                        static_cast<unsigned>(range.address + range.count - 1));
                     for (unsigned j = 0; j < range.count; ++j)
                        std::fprintf(stderr, "%s%u", j ? "," : "", memory_image[range.address + j]);
                     std::fprintf(stderr, "\n");
                  }
                  std::exit(1);
               }
            }
            if (raw_line_memory_oracle.enabled) {
               const uint8_t mode = peek_memory(raw_line_memory_oracle.address);
               const uint64_t lines = raw_lines_for_memory_value(mode);
               frame_expected_raw_cycles.push_back(lines * kCyclesPerScanline);
            }
            // Test-only RAM mutation happens exactly at the synchronized frame
            // boundary, before VBLANK work begins.  This lets renderer tests
            // hammer state-dependent schedulers without spending cartridge
            // overscan cycles generating pseudo-random inputs themselves.
            if (vsync_assertions.size() > 1) {
               for (RandomizeZpRange &range : randomize_zp_ranges) {
                  if (range.frames_until_refresh == 0) {
                     for (unsigned i = 0; i < range.count; ++i) {
                        memory_image[range.address + i] = next_randomized_zp_value(range);
                     }
                     range.frames_until_refresh = range.hold_frames - 1;
                  }
                  else {
                     --range.frames_until_refresh;
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
               for (FrameMemorySequence &sequence : frame_memory_sequences) {
                  memory_image[sequence.address] = sequence.values[sequence.index];
                  sequence.index = (sequence.index + 1) % sequence.values.size();
               }
            }
         }
         vsync_asserted = next;
      }
      else if (event.address == kTim1t || event.address == kTim8t ||
               event.address == kTim64t || event.address == kT1024t) {
         load_timer(event.address, event.value);
      }
      else if (tia_write && (tia_address == kAudc0 || tia_address == kAudf0 ||
               tia_address == kAudv0)) {
         channel0_write_order.push_back(tia_address);
         if ((tia_address == kAudc0 || tia_address == kAudf0) &&
             channel0_volume != 0) {
            channel0_retuned_while_audible = true;
         }
         if (tia_address == kAudv0) {
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
         "usage: %s ROM.bin VSYNC_ASSERTIONS [--no-audio] [--stop-pc ADDR] [--minimum-checked-frames N] [--audio-start-synced] [--audio-retune-muted] [--raw-lines N] [--raw-lines-by-memory ADDR VALUE:LINES[,VALUE:LINES...]] [--randomize-zp ADDR COUNT MODULUS SEED]... [--randomize-zp-held ADDR COUNT MODULUS SEED FRAMES]... [--dump-zp ADDR COUNT]... [--sweep-zp ADDR MIN MAX]... [--set-zp ADDR VALUE]... [--frame-sequence ADDR VALUE[,VALUE...]]... [--read-sequence ADDR VALUE[,VALUE...]]... [--released-inputs] [--paddle-lines L0,L1,L2,L3] [--require-stable-tia-write-phase ADDR LINE]... [--expect-memory ADDR VALUE]... [--expect-memory-equal ADDR COUNT]... [--verify-asymmetric-visibility Y_ADDR COLOR_ADDR DRAW_ADDR COUNT_ADDR] [--verify-asymmetric-glyphs GRAPHICS_ADDR MASK] [--require-visible-mask MASK] [--require-visible-spread MASK MAX] [--require-stable-first-visible-line MASK] [--expect-resp-phases CSV] [--require-resp-phases CSV] [--require-dual-resp] [--require-adjacent-resp]\n",
         argv[0]);
      return 2;
   }

   bool require_audio = true;
   bool require_audio_start_sync = false;
   size_t minimum_checked_frames_override = 0;
   bool require_audio_retune_muted = false;
   bool require_dual_resp = false;
   bool require_adjacent_resp = false;
   bool stop_pc_enabled = false;
   uint16_t stop_pc = 0;
   uint64_t expected_raw_lines = kDefaultVsyncIntervalScanlines;
   for (int i = 3; i < argc; ++i) {
      if (std::strcmp(argv[i], "--no-audio") == 0) {
         require_audio = false;
      }
      else if (std::strcmp(argv[i], "--stop-pc") == 0) {
         if (++i >= argc) fail("--stop-pc requires an address");
         char *parse_end = nullptr;
         const unsigned long address = std::strtoul(argv[i], &parse_end, 0);
         if (!parse_end || *parse_end != '\0' || address > 0xffff)
            fail("bad --stop-pc address");
         stop_pc_enabled = true;
         stop_pc = static_cast<uint16_t>(address);
      }
      else if (std::strcmp(argv[i], "--minimum-checked-frames") == 0) {
         if (++i >= argc) {
            fail("--minimum-checked-frames requires a value");
         }
         char *parse_end = nullptr;
         const unsigned long minimum = std::strtoul(argv[i], &parse_end, 10);
         if (!parse_end || *parse_end != '\0' || minimum < 1) {
            fail("bad --minimum-checked-frames value");
         }
         minimum_checked_frames_override = static_cast<size_t>(minimum);
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
      else if (std::strcmp(argv[i], "--raw-lines-by-memory") == 0) {
         if (i + 2 >= argc) {
            fail("--raw-lines-by-memory requires ADDR VALUE:LINES[,VALUE:LINES...]");
         }
         char *parse_end = nullptr;
         const unsigned long address = std::strtoul(argv[++i], &parse_end, 0);
         if (!parse_end || *parse_end != '\0' || address > 0xffff) {
            fail("bad --raw-lines-by-memory address");
         }
         raw_line_memory_oracle.enabled = true;
         raw_line_memory_oracle.address = static_cast<uint16_t>(address);
         const char *cursor = argv[++i];
         while (*cursor) {
            char *value_end = nullptr;
            const unsigned long value = std::strtoul(cursor, &value_end, 0);
            if (!value_end || value_end == cursor || value > 0xff || *value_end != ':') {
               fail("bad --raw-lines-by-memory value");
            }
            cursor = value_end + 1;
            char *lines_end = nullptr;
            const unsigned long lines = std::strtoul(cursor, &lines_end, 10);
            if (!lines_end || lines_end == cursor || lines < 1) {
               fail("bad --raw-lines-by-memory lines");
            }
            raw_line_memory_oracle.rules.push_back({
               static_cast<uint8_t>(value), static_cast<uint64_t>(lines)
            });
            if (*lines_end == '\0') break;
            if (*lines_end != ',') fail("bad --raw-lines-by-memory mapping");
            cursor = lines_end + 1;
            if (!*cursor) fail("bad --raw-lines-by-memory mapping");
         }
         if (raw_line_memory_oracle.rules.empty()) {
            fail("bad --raw-lines-by-memory mapping");
         }
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
            static_cast<unsigned>(modulus), static_cast<uint32_t>(seed), 1, 0
         });
      }
      else if (std::strcmp(argv[i], "--randomize-zp-held") == 0) {
         if (i + 5 >= argc) {
            fail("--randomize-zp-held requires ADDR COUNT MODULUS SEED FRAMES");
         }
         char *parse_end = nullptr;
         const unsigned long address = std::strtoul(argv[++i], &parse_end, 0);
         if (!parse_end || *parse_end != '\0' || address > 0xff) fail("bad --randomize-zp-held address");
         const unsigned long count = std::strtoul(argv[++i], &parse_end, 0);
         if (!parse_end || *parse_end != '\0' || count < 1 || count > 64 || address + count > 0x100) fail("bad --randomize-zp-held count");
         const unsigned long modulus = std::strtoul(argv[++i], &parse_end, 0);
         if (!parse_end || *parse_end != '\0' || modulus < 1 || modulus > 256) fail("bad --randomize-zp-held modulus");
         const unsigned long seed = std::strtoul(argv[++i], &parse_end, 0);
         if (!parse_end || *parse_end != '\0' || seed > 0xffffffffUL || seed == 0) fail("bad --randomize-zp-held seed");
         const unsigned long hold = std::strtoul(argv[++i], &parse_end, 0);
         if (!parse_end || *parse_end != '\0' || hold < 1 || hold > 1000000UL) fail("bad --randomize-zp-held frames");
         randomize_zp_ranges.push_back({
            static_cast<uint16_t>(address), static_cast<unsigned>(count),
            static_cast<unsigned>(modulus), static_cast<uint32_t>(seed),
            static_cast<unsigned>(hold), 0
         });
      }
      else if (std::strcmp(argv[i], "--dump-zp") == 0) {
         if (i + 2 >= argc) fail("--dump-zp requires ADDR COUNT");
         char *parse_end = nullptr;
         const unsigned long address = std::strtoul(argv[++i], &parse_end, 0);
         if (!parse_end || *parse_end != '\0' || address > 0xff) fail("bad --dump-zp address");
         const unsigned long count = std::strtoul(argv[++i], &parse_end, 0);
         if (!parse_end || *parse_end != '\0' || count < 1 || count > 64 || address + count > 0x100) fail("bad --dump-zp count");
         dump_zp_ranges.push_back({static_cast<uint16_t>(address), static_cast<unsigned>(count)});
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
      else if (std::strcmp(argv[i], "--frame-sequence") == 0) {
         if (i + 2 >= argc) {
            fail("--frame-sequence requires ADDR VALUE[,VALUE...]");
         }
         char *parse_end = nullptr;
         const unsigned long address = std::strtoul(argv[++i], &parse_end, 0);
         if (!parse_end || *parse_end != '\0' || address > 0xffff) {
            fail("bad --frame-sequence address");
         }

         FrameMemorySequence sequence;
         sequence.address = static_cast<uint16_t>(address);
         const char *cursor = argv[++i];
         while (*cursor) {
            char *value_end = nullptr;
            const unsigned long value = std::strtoul(cursor, &value_end, 0);
            if (!value_end || value_end == cursor || value > 0xff) {
               fail("bad --frame-sequence value");
            }
            sequence.values.push_back(static_cast<uint8_t>(value));
            if (*value_end == '\0') break;
            if (*value_end != ',') fail("bad --frame-sequence value");
            cursor = value_end + 1;
            if (!*cursor) fail("bad --frame-sequence value");
         }
         if (sequence.values.empty()) fail("bad --frame-sequence value");
         frame_memory_sequences.push_back(sequence);
      }
      else if (std::strcmp(argv[i], "--read-sequence") == 0) {
         if (i + 2 >= argc) {
            fail("--read-sequence requires ADDR VALUE[,VALUE...]");
         }
         char *parse_end = nullptr;
         const unsigned long address = std::strtoul(argv[++i], &parse_end, 0);
         if (!parse_end || *parse_end != '\0' || address > 0xffff) {
            fail("bad --read-sequence address");
         }

         ReadMemorySequence sequence;
         sequence.address = static_cast<uint16_t>(address);
         const char *cursor = argv[++i];
         while (*cursor) {
            char *value_end = nullptr;
            const unsigned long value = std::strtoul(cursor, &value_end, 0);
            if (!value_end || value_end == cursor || value > 0xff) {
               fail("bad --read-sequence value");
            }
            sequence.values.push_back(static_cast<uint8_t>(value));
            if (*value_end == '\0') break;
            if (*value_end != ',') fail("bad --read-sequence value");
            cursor = value_end + 1;
            if (!*cursor) fail("bad --read-sequence value");
         }
         if (sequence.values.empty()) fail("bad --read-sequence value");
         read_memory_sequences.push_back(sequence);
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
      else if (std::strcmp(argv[i], "--paddle-lines") == 0) {
         if (++i >= argc) fail("--paddle-lines requires L0,L1,L2,L3");
         const char *cursor = argv[i];
         for (unsigned channel = 0; channel < 4; ++channel) {
            char *end = nullptr;
            const unsigned long lines = std::strtoul(cursor, &end, 0);
            if (!end || end == cursor || lines > 10000) fail("bad --paddle-lines value");
            paddle_threshold_cycles[channel] = static_cast<uint64_t>(lines) * kCyclesPerScanline;
            if (channel == 3) {
               if (*end != '\0') fail("bad --paddle-lines value");
            }
            else {
               if (*end != ',') fail("bad --paddle-lines value");
               cursor = end + 1;
               if (!*cursor) fail("bad --paddle-lines value");
            }
         }
         paddle_inputs = true;
      }
      else if (std::strcmp(argv[i], "--require-stable-tia-write-phase") == 0) {
         if (i + 2 >= argc) fail("--require-stable-tia-write-phase requires ADDR LINE");
         char *address_end = nullptr;
         const unsigned long address = std::strtoul(argv[++i], &address_end, 0);
         if (!address_end || *address_end != '\0' || address > 0x3f)
            fail("bad --require-stable-tia-write-phase address");
         char *line_end = nullptr;
         const unsigned long line = std::strtoul(argv[++i], &line_end, 0);
         if (!line_end || *line_end != '\0' || line > 10000)
            fail("bad --require-stable-tia-write-phase line");
         StableTiaWritePhase rule;
         rule.address = static_cast<uint16_t>(address);
         rule.line = static_cast<uint64_t>(line);
         stable_tia_write_phases.push_back(rule);
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
      else if (std::strcmp(argv[i], "--expect-memory-equal") == 0) {
         if (i + 2 >= argc) fail("--expect-memory-equal requires ADDR COUNT");
         char *address_end = nullptr;
         const unsigned long address = std::strtoul(argv[++i], &address_end, 0);
         if (!address_end || *address_end != '\0' || address > 0xffff)
            fail("bad --expect-memory-equal address");
         char *count_end = nullptr;
         const unsigned long count = std::strtoul(argv[++i], &count_end, 0);
         if (!count_end || *count_end != '\0' || count < 2 || count > 64 || address + count > 0x10000)
            fail("bad --expect-memory-equal count");
         expected_memory_equal_ranges.push_back({static_cast<uint16_t>(address), static_cast<unsigned>(count)});
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
      else if (std::strcmp(argv[i], "--verify-asymmetric-glyphs") == 0) {
         if (i + 2 >= argc) fail("--verify-asymmetric-glyphs requires GRAPHICS_ADDR MASK");
         char *address_end = nullptr;
         const unsigned long address = std::strtoul(argv[++i], &address_end, 0);
         if (!address_end || *address_end != '\0' || address > 0xffff)
            fail("bad --verify-asymmetric-glyphs graphics address");
         char *mask_end = nullptr;
         const unsigned long mask = std::strtoul(argv[++i], &mask_end, 0);
         if (!mask_end || *mask_end != '\0' || mask == 0 || mask > 0x3f)
            fail("bad --verify-asymmetric-glyphs mask");
         asymmetric_visibility.graphics_address = static_cast<uint16_t>(address);
         asymmetric_visibility.exact_glyph_mask = static_cast<uint8_t>(mask);
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
      else if (std::strcmp(argv[i], "--require-stable-first-visible-line") == 0) {
         if (++i >= argc) fail("--require-stable-first-visible-line requires MASK");
         char *parse_end = nullptr;
         const unsigned long mask = std::strtoul(argv[i], &parse_end, 0);
         if (!parse_end || *parse_end != '\0' || mask == 0 || mask > 0x3f)
            fail("bad --require-stable-first-visible-line mask");
         asymmetric_visibility.stable_first_line_mask = static_cast<uint8_t>(mask);
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
   live_expected_raw_cycles = raw_line_memory_oracle.enabled ? 0 : expected_raw_cycles;

   char *end = nullptr;
   const long requested = std::strtol(argv[2], &end, 10);
   if (!end || *end != '\0' || requested < 10) {
      fail("bad VSYNC assertion count");
   }

   std::memset(memory_image, 0, sizeof(memory_image));
   std::memset(cartridge_image, 0, sizeof(cartridge_image));
   std::memset(superchip_ram, 0, sizeof(superchip_ram));
   std::memset(threee_ram, 0, sizeof(threee_ram));
   std::ifstream rom(argv[1], std::ios::binary | std::ios::ate);
   if (!rom) {
      fail("could not open ROM");
   }
   const std::streamoff rom_size = rom.tellg();
   if (rom_size <= 0 || rom_size > static_cast<std::streamoff>(kMaxRomSize) ||
       (rom_size != static_cast<std::streamoff>(kBankSize) &&
        rom_size != static_cast<std::streamoff>(kF8RomSize) &&
        rom_size != static_cast<std::streamoff>(kF4RomSize) &&
        (rom_size < static_cast<std::streamoff>(kF8RomSize) ||
         (rom_size % 0x0800) != 0))) {
      fail("unsupported ROM size (expected 4K/8K/32K or signed 3F/3E/3EX 2K-bank image up to 512K)");
   }
   cartridge_size = static_cast<size_t>(rom_size);
   rom.seekg(0, std::ios::beg);
   rom.read(reinterpret_cast<char *>(cartridge_image), rom_size);
   if (rom.gcount() != rom_size) {
      fail("could not read complete ROM");
   }
   const uint8_t *signature = cartridge_image + cartridge_size - 8u;
   if ((cartridge_size % 0x0800u) == 0u && has_3ex_detector_markers()) {
      cartridge_mapper = CartridgeTimingMapper::ThreeE;
      three_bank_count = static_cast<unsigned>(cartridge_size / 0x0800u);
      three_fixed_chunk = three_bank_count - 1u;
      selected_three_chunk = 0;
      threee_ram_selected = false;
   }
   else if ((cartridge_size % 0x0800u) == 0u &&
            std::memcmp(signature, "3F\0\0", 4) == 0) {
      cartridge_mapper = CartridgeTimingMapper::ThreeF;
      three_bank_count = static_cast<unsigned>(cartridge_size / 0x0800u);
      three_fixed_chunk = three_bank_count - 1u;
      selected_three_chunk = 0;
   }
   else if ((cartridge_size % 0x0800u) == 0u &&
            std::memcmp(signature, "3E\0\0", 4) == 0) {
      cartridge_mapper = CartridgeTimingMapper::ThreeE;
      three_bank_count = static_cast<unsigned>(cartridge_size / 0x0800u);
      three_fixed_chunk = three_bank_count - 1u;
      selected_three_chunk = 0;
      threee_ram_selected = false;
   }
   else if (cartridge_size == kF4RomSize) {
      cartridge_mapper = CartridgeTimingMapper::F4SC;
      selected_f4_chunk = 7;
   }
   else if (cartridge_size == kF8RomSize) {
      // F8/F8SC file chunk 1 is the startup bank ($1FF9).  The 6507 only
      // exposes 13 address bits, so banked code linked at $Dxxx and $Fxxx
      // reaches the same cartridge window; read_bus() applies that mirror.
      cartridge_mapper = CartridgeTimingMapper::F8;
      map_f8_chunk(1);
   }
   else if (cartridge_size == kBankSize) {
      cartridge_mapper = CartridgeTimingMapper::Plain;
      std::memcpy(memory_image + kRomBase, cartridge_image, kBankSize);
   }
   else {
      fail("nonstandard 2K-bank ROM lacks a 3F/3E/3EX signature");
   }

   if (released_inputs) {
      memory_image[kSwcha] = 0xff;
      memory_image[kSwchb] = 0xff;
   }

   mos6502 cpu(read_bus, write_bus, clock_cycle);
   cpu.Reset();
   uint64_t cpu_cycles = 0;
   constexpr uint64_t kInstructionLimit = 100000000;

   bool stopped_at_pc = stop_pc_enabled && cpu.GetPC() == stop_pc;
   uint64_t instructions = 0;
   for (;
        instructions < kInstructionLimit &&
        !stopped_at_pc &&
        (stop_pc_enabled || vsync_assertions.size() < static_cast<size_t>(requested));
        ++instructions) {
      writes.clear();
      const uint64_t before = cpu_cycles;
      cpu.Run(1, cpu_cycles, mos6502::INST_COUNT);
      virtual_cycles += cpu_cycles - before;
      apply_writes();
      stopped_at_pc = stop_pc_enabled && cpu.GetPC() == stop_pc;
   }

   if (stop_pc_enabled) {
      if (!stopped_at_pc) fail("instruction limit reached before stop PC");
      for (const ExpectedMemory &expect : expected_memory) {
         const uint8_t actual = peek_memory(expect.address);
         if (actual != expect.value) {
            std::fprintf(stderr,
               "vcs_frame_timing: memory $%04x expected $%02x, got $%02x\n",
               expect.address, expect.value, actual);
            return 1;
         }
      }
      std::printf("vcs_frame_timing stop ok: pc=$%04x after %llu instructions\n",
         stop_pc, static_cast<unsigned long long>(instructions));
      return 0;
   }

   if (vsync_assertions.size() < static_cast<size_t>(requested)) {
      fail("instruction limit reached before enough frames");
   }
   if (timer_overrun_read) {
      fail("overscan timer underflowed before the player finished");
   }
   if (vsync_deassertions.size() + 1 < vsync_assertions.size()) {
      fail("missing VSYNC deassertion");
   }
   for (size_t i = 0; i < vsync_deassertions.size(); ++i) {
      const uint64_t pulse = vsync_deassertions[i] - vsync_assertions[i];
      if (pulse != 3 * kCyclesPerScanline) {
         std::fprintf(stderr,
            "vcs_frame_timing: VSYNC pulse %zu is %llu cycles; expected 228\n",
            i, static_cast<unsigned long long>(pulse));
         return 1;
      }
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
      const uint64_t frame_expected_cycles = raw_line_memory_oracle.enabled
         ? frame_expected_raw_cycles[i - 1]
         : expected_raw_cycles;
      const uint64_t frame_expected_lines = frame_expected_cycles / kCyclesPerScanline;
      if (!whole_lines || delta != frame_expected_cycles) {
         std::fprintf(stderr,
            "vcs_frame_timing: frame %zu has %llu-cycle VSYNC spacing "
            "(%llu raw harness lines); expected %llu cycles (%llu raw lines), "
            "calibrated against Stella's %llu-line display\n",
            i,
            static_cast<unsigned long long>(delta),
            static_cast<unsigned long long>(interval_lines),
            static_cast<unsigned long long>(frame_expected_cycles),
            static_cast<unsigned long long>(frame_expected_lines),
            static_cast<unsigned long long>(kExpectedDisplayedScanlines));
         return 1;
      }
      ++checked;
   }

   const size_t minimum_checked_frames = minimum_checked_frames_override != 0
      ? minimum_checked_frames_override
      : (require_audio ? 1000 : 40);
   if (checked < minimum_checked_frames) {
      fail("not enough complete frames were checked");
   }
   for (const StableTiaWritePhase &rule : stable_tia_write_phases) {
      if (rule.checked_frames < 2)
         fail("stable TIA write-phase rule did not observe enough complete frames");
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
      const uint8_t actual = peek_memory(expect.address);
      if (actual != expect.value) {
         std::fprintf(stderr,
            "vcs_frame_timing: memory $%04x expected $%02x, got $%02x\n",
            expect.address, expect.value, actual);
         return 1;
      }
   }
   for (const ExpectedMemoryEqualRange &expect : expected_memory_equal_ranges) {
      const uint8_t reference = peek_memory(expect.address);
      for (unsigned j = 1; j < expect.count; ++j) {
         const uint16_t address = static_cast<uint16_t>(expect.address + j);
         const uint8_t actual = peek_memory(address);
         if (actual != reference) {
            std::fprintf(stderr,
               "vcs_frame_timing: memory range $%04x..$%04x not equal:",
               expect.address, static_cast<unsigned>(expect.address + expect.count - 1));
            for (unsigned k = 0; k < expect.count; ++k)
               std::fprintf(stderr, "%s$%02x", k ? "," : " ", peek_memory(static_cast<uint16_t>(expect.address + k)));
            std::fprintf(stderr, "\n");
            return 1;
         }
      }
   }

   if (asymmetric_visibility.exact_glyph_mask && !asymmetric_visibility.enabled)
      fail("--verify-asymmetric-glyphs needs --verify-asymmetric-visibility");

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

   if (asymmetric_visibility.stable_first_line_mask && !asymmetric_visibility.enabled)
      fail("--require-stable-first-visible-line needs --verify-asymmetric-visibility");

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
