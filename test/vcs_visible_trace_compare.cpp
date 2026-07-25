//! @file vcs_visible_trace_compare.cpp
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
      return line == other.line && cycle == other.cycle &&
             address == other.address && value == other.value;
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
               "vcs_visible_trace_compare: %s frame %zu has %llu cycles "
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
      std::fprintf(stderr, "vcs_visible_trace_compare: %s\n", message);
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

uint64_t parse_raw_lines(const char *text) {
   char *end = nullptr;
   const unsigned long value = std::strtoul(text, &end, 10);
   if (!end || *end != '\0' || value == 0) {
      std::fprintf(stderr, "vcs_visible_trace_compare: bad raw-line count '%s'\n", text);
      std::exit(2);
   }
   return static_cast<uint64_t>(value);
}

int main(int argc, char **argv) {
   if (argc != 5) {
      std::fprintf(stderr,
         "usage: %s OLD.bin NEW.bin OLD_RAW_LINES NEW_RAW_LINES\n", argv[0]);
      return 2;
   }
   TraceMachine old_machine(argv[1]);
   const std::vector<Event> old_events =
      old_machine.run(parse_raw_lines(argv[3]), "old");
   TraceMachine new_machine(argv[2]);
   const std::vector<Event> new_events =
      new_machine.run(parse_raw_lines(argv[4]), "new");
   if (old_events.empty() || new_events.empty()) {
      std::fprintf(stderr, "vcs_visible_trace_compare: empty visible trace\n");
      return 1;
   }
   if (old_events.size() != new_events.size()) {
      std::fprintf(stderr, "vcs_visible_trace_compare: event counts differ: %zu vs %zu\n",
                   old_events.size(), new_events.size());
      return 1;
   }
   for (size_t i = 0; i < old_events.size(); ++i) {
      if (!(old_events[i] == new_events[i])) {
         const Event &a = old_events[i];
         const Event &b = new_events[i];
         std::fprintf(stderr,
            "vcs_visible_trace_compare: event %zu differs: "
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
      "vcs_visible_trace_compare ok: %zu events and 42 stable frames per ROM\n",
      old_events.size());
   return 0;
}
