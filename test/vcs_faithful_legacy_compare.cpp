//! @file vcs_faithful_legacy_compare.cpp
//! @brief Compare visible TIA writes and stable frame spacing from two 4K VCS cartridges.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <vector>

#include "mos6502.h"

namespace {
constexpr uint16_t kRomBase = 0xF000;
constexpr size_t kRomSize = 4096;
constexpr uint64_t kCyclesPerScanline = 76;
constexpr uint16_t kVsync = 0x0000;
constexpr uint16_t kVblank = 0x0001;
constexpr uint16_t kWsync = 0x0002;
constexpr uint16_t kIntim = 0x0284;
constexpr uint16_t kTimint = 0x0285;
constexpr uint16_t kTim1t = 0x0294;
constexpr uint16_t kTim8t = 0x0295;
constexpr uint16_t kTim64t = 0x0296;
constexpr uint16_t kT1024t = 0x0297;

struct Write { uint16_t address; uint8_t value; };
struct Event {
   uint64_t line;
   uint64_t cycle;
   uint16_t address;
   uint8_t value;
   bool operator==(const Event &other) const {
      if (line != other.line || cycle != other.cycle || address != other.address) {
         return false;
      }
      // RESP0/1, RESM0/1, RESBL, HMOVE, HMCLR, and CXCLR are strobes; the
      // data bus value is electrically ignored and can differ when otherwise
      // equivalent code/data pages move.
      if ((address >= 0x0010 && address <= 0x0014) ||
          address == 0x002a || address == 0x002b || address == 0x002c) {
         return true;
      }
      return value == other.value;
   }
};

// One execution supplies both contracts. Keeping timing and raster comparison
// in one harness avoids compiling two MOS 6502 test programs inside the generic
// runner's normal two-second per-test deadline.
class TraceMachine {
public:
   explicit TraceMachine(const char *path) : cpu_(read_bus_thunk, write_bus_thunk, clock_thunk) {
      active_ = this;
      std::memset(memory_, 0, sizeof(memory_));
      memory_[0x0280] = 0xff;
      memory_[0x0282] = 0xff;
      std::ifstream rom(path, std::ios::binary);
      if (!rom) fail("could not open ROM");
      rom.read(reinterpret_cast<char *>(memory_ + kRomBase), kRomSize);
      if (rom.gcount() != static_cast<std::streamsize>(kRomSize)) {
         fail("ROM is not exactly 4096 bytes");
      }
      cpu_.Reset();
   }

   std::vector<Event> run(uint64_t expected_raw_lines, const char *label) {
      constexpr uint64_t kInstructionLimit = 100000000;
      constexpr size_t kRequestedAssertions = 45;
      for (uint64_t instructions = 0;
           instructions < kInstructionLimit &&
           vsync_assertions_.size() < kRequestedAssertions;
           ++instructions) {
         writes_.clear();
         const uint64_t before = cpu_cycles_;
         cpu_.Run(1, cpu_cycles_, mos6502::INST_COUNT);
         virtual_cycles_ += cpu_cycles_ - before;
         apply_writes();
      }
      if (vsync_assertions_.size() < kRequestedAssertions) {
         fail("instruction limit reached before enough complete frames");
      }
      const uint64_t expected_cycles = expected_raw_lines * kCyclesPerScanline;
      for (size_t i = 3; i < vsync_assertions_.size(); ++i) {
         const uint64_t delta = vsync_assertions_[i] - vsync_assertions_[i - 1];
         if (delta != expected_cycles) {
            std::fprintf(stderr,
               "vcs_faithful_legacy_compare: %s frame %zu has %llu cycles "
               "(%llu raw lines), expected %llu cycles (%llu raw lines)\n",
               label, i,
               static_cast<unsigned long long>(delta),
               static_cast<unsigned long long>(delta / kCyclesPerScanline),
               static_cast<unsigned long long>(expected_cycles),
               static_cast<unsigned long long>(expected_raw_lines));
            std::exit(1);
         }
      }
      return events_;
   }

private:
   static TraceMachine *active_;
   uint8_t memory_[65536]{};
   mos6502 cpu_;
   uint64_t cpu_cycles_ = 0;
   uint64_t virtual_cycles_ = 0;
   std::vector<Write> writes_;
   std::vector<Event> events_;
   std::vector<uint64_t> vsync_assertions_;
   bool vsync_asserted_ = false;
   bool vblank_asserted_ = true;
   int frame_ = -1;
   uint64_t frame_start_ = 0;
   bool timer_active_ = false;
   uint64_t timer_start_ = 0;
   uint16_t timer_divisor_ = 1;
   uint8_t timer_loaded_ = 0;

   [[noreturn]] static void fail(const char *message) {
      std::fprintf(stderr, "vcs_faithful_legacy_compare: %s\n", message);
      std::exit(1);
   }
   static uint8_t read_bus_thunk(uint16_t address) { return active_->read_bus(address); }
   static void write_bus_thunk(uint16_t address, uint8_t value) { active_->write_bus(address, value); }
   static void clock_thunk(mos6502 *) {}

   bool timer_underflowed() const {
      if (!timer_active_) return false;
      return (virtual_cycles_ - timer_start_) / timer_divisor_ > timer_loaded_;
   }
   uint8_t timer_value() const {
      if (!timer_active_) return memory_[kIntim];
      const uint64_t ticks = (virtual_cycles_ - timer_start_) / timer_divisor_;
      if (ticks <= timer_loaded_) return static_cast<uint8_t>(timer_loaded_ - ticks);
      return static_cast<uint8_t>(255 - ((ticks - timer_loaded_ - 1) & 255));
   }
   uint8_t read_bus(uint16_t address) {
      if (address == kIntim) return timer_value();
      if (address == kTimint) return timer_underflowed() ? 0x80 : 0;
      return memory_[address];
   }
   void write_bus(uint16_t address, uint8_t value) {
      if (address < kRomBase) memory_[address] = value;
      writes_.push_back({address, value});
   }
   void load_timer(uint16_t address, uint8_t value) {
      timer_active_ = true;
      timer_start_ = virtual_cycles_;
      timer_loaded_ = value;
      switch (address) {
         case kTim1t: timer_divisor_ = 1; break;
         case kTim8t: timer_divisor_ = 8; break;
         case kTim64t: timer_divisor_ = 64; break;
         case kT1024t: timer_divisor_ = 1024; break;
         default: std::abort();
      }
   }
   void apply_writes() {
      for (const Write &write : writes_) {
         if (write.address == kWsync) {
            const uint64_t within = virtual_cycles_ % kCyclesPerScanline;
            virtual_cycles_ += within ? kCyclesPerScanline - within
                                      : kCyclesPerScanline;
         }
         else if (write.address == kVsync) {
            const bool next = (write.value & 2) != 0;
            if (next && !vsync_asserted_) {
               ++frame_;
               frame_start_ = virtual_cycles_;
               vsync_assertions_.push_back(virtual_cycles_);
            }
            vsync_asserted_ = next;
         }
         else if (write.address == kVblank) {
            vblank_asserted_ = (write.value & 2) != 0;
         }
         else if (write.address >= kTim1t && write.address <= kT1024t) {
            load_timer(write.address, write.value);
         }

         if (frame_ == 4 && !vblank_asserted_ && write.address <= 0x002c &&
             write.address != kVsync && write.address != kVblank &&
             write.address != kWsync) {
            const uint64_t relative = virtual_cycles_ - frame_start_;
            events_.push_back({relative / kCyclesPerScanline,
                               relative % kCyclesPerScanline,
                               write.address, write.value});
         }
      }
   }
};
TraceMachine *TraceMachine::active_ = nullptr;
} // namespace


void validate_sprite_oracle(const std::vector<Event> &events, int alien_p0_frame, int alien_p1_frame) {
   struct RowWrite { uint64_t line; uint8_t value; };
   std::vector<RowWrite> p0_rows;
   std::vector<RowWrite> p1_rows;
   for (const Event &event : events) {
      if (event.line >= 210 || event.value == 0) continue;
      if (event.address == 0x001b) p0_rows.push_back({event.line, event.value});
      if (event.address == 0x001c) p1_rows.push_back({event.line, event.value});
   }
   const uint8_t legacy_p0[] = {0x3c,0x66,0x66,0x66,0x7e,0x66,0x66,0x3c};
   const uint8_t legacy_p1[] = {0x7c,0x66,0x66,0x66,0x7c,0x66,0x66,0x7c};
   const uint8_t alien_p0[4][8] = {
      {0x42,0xa5,0xbd,0xff,0xdb,0x7e,0x3c,0x66},
      {0x24,0x5a,0xbd,0xff,0xdb,0x7e,0x5a,0x99},
      {0x42,0xa5,0xbd,0xff,0xdb,0x7e,0x5a,0x81},
      {0x81,0x5a,0xbd,0xff,0xdb,0x7e,0x3c,0x24}
   };
   const uint8_t alien_p1[4][8] = {
      {0xa5,0x5a,0x24,0xff,0xdb,0xff,0x66,0x3c},
      {0x54,0x3c,0x42,0xff,0xdb,0xff,0x66,0x3c},
      {0x24,0x5a,0x81,0xff,0xdb,0xff,0x66,0x3c},
      {0x2a,0x3c,0x42,0xff,0xdb,0xff,0x66,0x3c}
   };
   const bool alien_sprites = alien_p0_frame >= 0 && alien_p1_frame >= 0;
   if (alien_sprites && (alien_p0_frame > 3 || alien_p1_frame > 3)) {
      std::fprintf(stderr, "vcs_faithful_legacy_compare: alien sprite frame is outside 0..3\n");
      std::exit(1);
   }
   const uint8_t *expected_p0 = alien_sprites ? alien_p0[alien_p0_frame] : legacy_p0;
   const uint8_t *expected_p1 = alien_sprites ? alien_p1[alien_p1_frame] : legacy_p1;
   if (p0_rows.size() != 8 || p1_rows.size() != 8) {
      std::fprintf(stderr,
         "vcs_faithful_legacy_compare: sprite row counts are P0=%zu P1=%zu; expected 8 each\n",
         p0_rows.size(), p1_rows.size());
      std::exit(1);
   }
   for (size_t i = 0; i < 8; ++i) {
      if (p0_rows[i].value != expected_p0[i] || p1_rows[i].value != expected_p1[i]) {
         std::fprintf(stderr,
            "vcs_faithful_legacy_compare: sprite row %zu is P0=%02x P1=%02x; expected %02x/%02x\n",
            i, p0_rows[i].value, p1_rows[i].value, expected_p0[i], expected_p1[i]);
         std::exit(1);
      }
      if (i && (p0_rows[i].line != p0_rows[i-1].line + 2 ||
                p1_rows[i].line != p1_rows[i-1].line + 2)) {
         std::fprintf(stderr,
            "vcs_faithful_legacy_compare: sprite row spacing changed at row %zu\n", i);
         std::exit(1);
      }
   }

   std::vector<uint8_t> p0_colors;
   std::vector<uint8_t> p1_colors;
   for (const Event &event : events) {
      if (event.address == 0x0006 && event.line >= p0_rows.front().line &&
          event.line <= p0_rows.back().line) p0_colors.push_back(event.value);
      if (event.address == 0x0007 && event.line >= p1_rows.front().line &&
          event.line <= p1_rows.back().line) p1_colors.push_back(event.value);
   }
   const uint8_t expected_p0_colors[] = {0x3e,0xae,0x9e,0x8e,0x7e,0x6e,0x5e,0x4e};
   const uint8_t expected_p1_colors[] = {0x5e,0x6e,0x7e,0x8e,0x9e,0xae,0xbe,0xce};
   if (p0_colors.size() != 8 || p1_colors.size() != 8) {
      std::fprintf(stderr,
         "vcs_faithful_legacy_compare: sprite color row counts are P0=%zu P1=%zu; expected 8 each\n",
         p0_colors.size(), p1_colors.size());
      std::exit(1);
   }
   for (size_t i = 0; i < 8; ++i) {
      if (p0_colors[i] != expected_p0_colors[i] || p1_colors[i] != expected_p1_colors[i]) {
         std::fprintf(stderr,
            "vcs_faithful_legacy_compare: sprite color row %zu is P0=%02x P1=%02x; expected %02x/%02x\n",
            i, p0_colors[i], p1_colors[i], expected_p0_colors[i], expected_p1_colors[i]);
         std::exit(1);
      }
   }
   std::printf(
      "vcs_faithful_legacy_compare sprite oracle ok: 8 P0 rows, 8 P1 rows, exact row colors\n");
}

void validate_multisprite_oracle(const std::vector<Event> &events) {
   auto fail = [](const char *message) {
      std::fprintf(stderr, "vcs_faithful_legacy_compare: multisprite %s\n", message);
      std::exit(1);
   };

   // Lock the complete stable visible TIA-write schedule, not merely register
   // values.  Strobe data-bus values are intentionally normalized because TIA
   // ignores them and harmless ROM relocation can change the accumulator there.
   auto is_strobe = [](uint16_t address) {
      return (address >= 0x0010 && address <= 0x0014) ||
             address == 0x002a || address == 0x002b || address == 0x002c;
   };
   uint64_t hash = 1469598103934665603ULL;
   auto hash_byte = [&hash](uint8_t byte) {
      hash ^= byte;
      hash *= 1099511628211ULL;
   };
   for (const Event &event : events) {
      const uint8_t value = is_strobe(event.address) ? 0 : event.value;
      for (unsigned shift = 0; shift != 64; shift += 8)
         hash_byte(static_cast<uint8_t>(event.line >> shift));
      for (unsigned shift = 0; shift != 64; shift += 8)
         hash_byte(static_cast<uint8_t>(event.cycle >> shift));
      hash_byte(static_cast<uint8_t>(event.address));
      hash_byte(static_cast<uint8_t>(event.address >> 8));
      hash_byte(value);
   }
   if (events.size() != 391 || hash != 0x0c40f1fcd683374dULL) {
      std::fprintf(stderr,
         "vcs_faithful_legacy_compare: multisprite visible trace changed: "
         "events=%zu hash=%016llx, expected 391/0c40f1fcd683374d\n",
         events.size(), static_cast<unsigned long long>(hash));
      std::exit(1);
   }

   struct Row { uint64_t line; uint64_t cycle; uint8_t value; };
   std::vector<Row> p0;
   std::vector<Row> p1;
   std::vector<Row> p1_colors;
   std::vector<Row> p1_repositions;
   for (const Event &event : events) {
      if (event.line >= 210) continue; // score field starts later
      if (event.address == 0x001b && event.value)
         p0.push_back({event.line, event.cycle, event.value});
      if (event.address == 0x001c && event.value)
         p1.push_back({event.line, event.cycle, event.value});
      if (event.address == 0x0007)
         p1_colors.push_back({event.line, event.cycle, event.value});
      if (event.address == 0x0011)
         p1_repositions.push_back({event.line, event.cycle, event.value});
   }

   const uint8_t expected_p0[] = {0x3c,0x66,0xc3,0xdb,0xdb,0xc3,0x66,0x3c};
   if (p0.size() != 8) fail("P0 row count is not eight");
   for (size_t i = 0; i < 8; ++i) {
      if (p0[i].line != 68 + i * 2 || p0[i].cycle != 73 ||
          p0[i].value != expected_p0[i])
         fail("P0 glyph/timing changed");
   }

   bool p0_cleared = false;
   for (const Event &event : events) {
      if (event.line == 84 && event.cycle == 45 &&
          event.address == 0x001b && event.value == 0) {
         p0_cleared = true;
         break;
      }
   }
   if (!p0_cleared)
      fail("P0 trailing clear row is missing; stale GRP0 would stripe under later HMOVEs");

   const uint8_t expected_p1[5][8] = {
      {0x7e,0x60,0x60,0x7c,0x06,0x06,0x66,0x3c},
      {0x0c,0x1c,0x3c,0x6c,0xcc,0xfe,0x0c,0x0c},
      {0x7c,0x06,0x06,0x3c,0x06,0x06,0x66,0x3c},
      {0x3c,0x66,0x06,0x0c,0x18,0x30,0x60,0x7e},
      {0x18,0x38,0x78,0x18,0x18,0x18,0x18,0x7e}
   };
   const uint64_t p1_first_line[] = {57,89,121,153,185};
   if (p1.size() != 40) fail("multiplexed P1 row count is not forty");
   for (size_t sprite = 0; sprite < 5; ++sprite) {
      for (size_t row = 0; row < 8; ++row) {
         const Row &actual = p1[sprite * 8 + row];
         if (actual.line != p1_first_line[sprite] + row * 2 ||
             actual.cycle != 11 || actual.value != expected_p1[sprite][row])
            fail("multiplexed P1 glyph/timing changed");
      }
   }

   const uint64_t color_lines[] = {55,87,119,151,183};
   const uint8_t colors[] = {0xbe,0x5e,0xae,0xce,0x4e};
   if (p1_colors.size() != 5) fail("multiplexed P1 color count changed");
   for (size_t i = 0; i < 5; ++i) {
      if (p1_colors[i].line != color_lines[i] || p1_colors[i].cycle != 31 ||
          p1_colors[i].value != colors[i])
         fail("multiplexed P1 color schedule changed");
   }

   const uint64_t reposition_lines[] = {53,85,117,149,181};
   const uint64_t reposition_cycles[] = {63,54,44,39,29};
   if (p1_repositions.size() != 5) fail("multiplexed P1 reposition count changed");
   for (size_t i = 0; i < 5; ++i) {
      if (p1_repositions[i].line != reposition_lines[i] ||
          p1_repositions[i].cycle != reposition_cycles[i])
         fail("multiplexed P1 reposition timing changed");
   }

   std::printf(
      "vcs_faithful_legacy_compare multisprite oracle ok: "
      "391 visible events, 264-line frames, six exact players\n");
}

uint64_t parse_raw_lines(const char *text) {
   char *end = nullptr;
   const unsigned long value = std::strtoul(text, &end, 10);
   if (!end || *end != '\0' || value == 0) {
      std::fprintf(stderr, "vcs_faithful_legacy_compare: bad raw-line count '%s'\n", text);
      std::exit(2);
   }
   return static_cast<uint64_t>(value);
}

int main(int argc, char **argv) {
   if (argc == 4 &&
       (std::strcmp(argv[3], "--sprites") == 0 ||
        std::strncmp(argv[3], "--alien-sprites=", 16) == 0 ||
        std::strcmp(argv[3], "--multisprite") == 0)) {
      TraceMachine machine(argv[1]);
      const std::vector<Event> events =
         machine.run(parse_raw_lines(argv[2]), "oracle");
      if (std::strcmp(argv[3], "--multisprite") == 0) {
         validate_multisprite_oracle(events);
      }
      else if (std::strncmp(argv[3], "--alien-sprites=", 16) == 0) {
         unsigned p0_frame = 0, p1_frame = 0;
         char tail = 0;
         if (std::sscanf(argv[3] + 16, "%u,%u%c", &p0_frame, &p1_frame, &tail) != 2 ||
             p0_frame > 3 || p1_frame > 3) {
            std::fprintf(stderr,
               "vcs_faithful_legacy_compare: bad alien sprite frames '%s'\n", argv[3] + 16);
            return 2;
         }
         validate_sprite_oracle(events, static_cast<int>(p0_frame), static_cast<int>(p1_frame));
      }
      else {
         validate_sprite_oracle(events, -1, -1);
      }
      return 0;
   }
   if (argc != 5) {
      std::fprintf(stderr,
         "usage: %s OLD.bin NEW.bin OLD_RAW_LINES NEW_RAW_LINES\n"
         "       %s ROM.bin RAW_LINES --sprites|--alien-sprites=P0,P1|--multisprite\n", argv[0], argv[0]);
      return 2;
   }
   TraceMachine old_machine(argv[1]);
   const std::vector<Event> old_events =
      old_machine.run(parse_raw_lines(argv[3]), "old");
   TraceMachine new_machine(argv[2]);
   const std::vector<Event> new_events =
      new_machine.run(parse_raw_lines(argv[4]), "new");
   if (old_events.empty() || new_events.empty()) {
      std::fprintf(stderr, "vcs_faithful_legacy_compare: empty visible trace\n");
      return 1;
   }
   if (old_events.size() != new_events.size()) {
      std::fprintf(stderr, "vcs_faithful_legacy_compare: event counts differ: %zu vs %zu\n",
                   old_events.size(), new_events.size());
      return 1;
   }
   for (size_t i = 0; i < old_events.size(); ++i) {
      if (!(old_events[i] == new_events[i])) {
         const Event &a = old_events[i];
         const Event &b = new_events[i];
         std::fprintf(stderr,
            "vcs_faithful_legacy_compare: event %zu differs: "
            "old %llu:%02llu %02x=%02x, new %llu:%02llu %02x=%02x\n",
            i,
            static_cast<unsigned long long>(a.line),
            static_cast<unsigned long long>(a.cycle), a.address, a.value,
            static_cast<unsigned long long>(b.line),
            static_cast<unsigned long long>(b.cycle), b.address, b.value);
         return 1;
      }
   }
   std::printf(
      "vcs_faithful_legacy_compare ok: %zu events and 42 stable frames per ROM\n",
      old_events.size());
   return 0;
}
