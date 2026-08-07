//! @file vcs_six_glyph_standalone_entry.cpp
//! @brief Verify the standalone six-glyph component's calibrated visible entry.

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
constexpr uint16_t kNusiz0 = 0x0004;
constexpr uint16_t kNusiz1 = 0x0005;
constexpr uint16_t kColup0 = 0x0006;
constexpr uint16_t kColup1 = 0x0007;
constexpr uint16_t kResp0 = 0x0010;
constexpr uint16_t kResp1 = 0x0011;
constexpr uint16_t kHmp0 = 0x0020;
constexpr uint16_t kHmp1 = 0x0021;
constexpr uint16_t kHmove = 0x002A;
constexpr uint16_t kHmclr = 0x002B;
constexpr uint16_t kIntim = 0x0284;
constexpr uint16_t kTimint = 0x0285;
constexpr uint16_t kTim1t = 0x0294;
constexpr uint16_t kTim8t = 0x0295;
constexpr uint16_t kTim64t = 0x0296;
constexpr uint16_t kT1024t = 0x0297;

struct Write { uint16_t address; uint8_t value; };
struct Event { uint64_t line; uint64_t cycle; uint16_t address; uint8_t value; };

class Machine {
public:
   explicit Machine(const char *path) : cpu_(read_bus_thunk, write_bus_thunk, clock_thunk) {
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

   void run() {
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
      const uint64_t expected = 262 * kCyclesPerScanline;
      for (size_t i = 3; i < vsync_assertions_.size(); ++i) {
         if (vsync_assertions_[i] - vsync_assertions_[i - 1] != expected) {
            fail("frame is not exactly 262 raw scanlines");
         }
      }
   }

   const std::vector<Event> &events() const { return events_; }

private:
   static Machine *active_;
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
      std::fprintf(stderr, "vcs_six_glyph_standalone_entry: %s\n", message);
      std::exit(1);
   }
   static uint8_t read_bus_thunk(uint16_t address) { return active_->read_bus(address); }
   static void write_bus_thunk(uint16_t address, uint8_t value) { active_->write_bus(address, value); }
   static void clock_thunk(mos6502 *) {}

   bool timer_underflowed() const {
      return timer_active_ &&
         (virtual_cycles_ - timer_start_) / timer_divisor_ > timer_loaded_;
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

         if (frame_ == 4 && !vblank_asserted_ && write.address <= 0x002c) {
            const uint64_t relative = virtual_cycles_ - frame_start_;
            events_.push_back({relative / kCyclesPerScanline,
                               relative % kCyclesPerScanline,
                               write.address, write.value});
         }
      }
   }
};
Machine *Machine::active_ = nullptr;

void require_event(const std::vector<Event> &events, uint64_t line, uint64_t cycle,
                   uint16_t address, uint8_t value, const char *name) {
   for (const Event &event : events) {
      if (event.line == line && event.cycle == cycle &&
          event.address == address && event.value == value) {
         return;
      }
   }
   std::fprintf(stderr,
      "vcs_six_glyph_standalone_entry: missing %s at %llu:%02llu %02x=%02x\n",
      name, static_cast<unsigned long long>(line),
      static_cast<unsigned long long>(cycle), address, value);
   std::exit(1);
}

void require_address_event(const std::vector<Event> &events, uint64_t line,
                           uint64_t cycle, uint16_t address, const char *name) {
   for (const Event &event : events) {
      if (event.line == line && event.cycle == cycle && event.address == address) {
         return;
      }
   }
   std::fprintf(stderr,
      "vcs_six_glyph_standalone_entry: missing %s at %llu:%02llu address %02x\n",
      name, static_cast<unsigned long long>(line),
      static_cast<unsigned long long>(cycle), address);
   std::exit(1);
}
} // namespace

void require_component_entry(const std::vector<Event> &events, uint64_t line) {
   require_event(events, line - 1, 57, kNusiz0, 0x03, "NUSIZ0");
   require_event(events, line - 1, 60, kNusiz1, 0x03, "NUSIZ1");
   require_event(events, line - 1, 65, kColup0, 0x0E, "COLUP0");
   require_event(events, line - 1, 68, kColup1, 0x0E, "COLUP1");
   require_event(events, line - 1, 71, kHmclr, 0x0E, "HMCLR");
   require_event(events, line, 0, kHmp0, 0x80, "HMP0");
   require_event(events, line, 5, kHmp1, 0x90, "HMP1");
   require_event(events, line, 10, kResp0, 0x90, "RESP0");
   require_event(events, line, 13, kResp1, 0x90, "RESP1");
   require_event(events, line, 71, kHmove, 0x90, "HMOVE");
}

void require_component_entry_at_cycle_zero(const std::vector<Event> &events,
                                           uint64_t line) {
   require_event(events, line, 0, kNusiz0, 0x03, "NUSIZ0");
   require_event(events, line, 3, kNusiz1, 0x03, "NUSIZ1");
   require_event(events, line, 8, kColup0, 0x0E, "COLUP0");
   require_event(events, line, 11, kColup1, 0x0E, "COLUP1");
   require_event(events, line, 14, kHmclr, 0x0E, "HMCLR");
   require_event(events, line, 19, kHmp0, 0x80, "HMP0");
   require_event(events, line, 24, kHmp1, 0x90, "HMP1");
   require_event(events, line, 29, kResp0, 0x90, "RESP0");
   require_event(events, line, 32, kResp1, 0x90, "RESP1");
   require_event(events, line, 71, kHmove, 0x90, "HMOVE");
}

void require_fingerprint_center_component_entry(const std::vector<Event> &events) {
   require_event(events, 130, 57, kNusiz0, 0x03, "center NUSIZ0");
   require_event(events, 130, 60, kNusiz1, 0x03, "center NUSIZ1");
   require_event(events, 130, 65, kColup0, 0x0E, "center COLUP0");
   require_event(events, 130, 68, kColup1, 0x0E, "center COLUP1");
   require_event(events, 130, 71, kHmclr, 0x0E, "center HMCLR");
   require_event(events, 131, 0, kHmp0, 0x80, "center HMP0");
   require_event(events, 131, 5, kHmp1, 0x90, "center HMP1");
   require_event(events, 131, 10, kResp0, 0x90, "center RESP0");
   require_event(events, 131, 13, kResp1, 0x90, "center RESP1");
   require_event(events, 131, 71, kHmove, 0x90, "center HMOVE");
}

void require_fingerprint_left_component_entry(const std::vector<Event> &events) {
   require_event(events, 220, 57, kNusiz0, 0x03, "left NUSIZ0");
   require_event(events, 220, 60, kNusiz1, 0x03, "left NUSIZ1");
   require_event(events, 220, 67, kResp0, 0x03, "left RESP0");
   require_event(events, 220, 70, kResp1, 0x03, "left RESP1");
   require_event(events, 221, 0, kColup0, 0x0E, "left COLUP0");
   require_event(events, 221, 3, kColup1, 0x0E, "left COLUP1");
   require_event(events, 221, 6, kHmclr, 0x0E, "left HMCLR");
   require_event(events, 221, 11, kHmp0, 0x30, "left HMP0");
   require_event(events, 221, 16, kHmp1, 0xB0, "left HMP1");
   require_event(events, 221, 71, kHmove, 0xB0, "left HMOVE");
   require_address_event(events, 223, 18, 0x001C, "left glyph 4");
   require_address_event(events, 223, 21, 0x001B, "left glyph 5");
   require_address_event(events, 223, 24, 0x001C, "left glyph 6");
   require_address_event(events, 223, 27, 0x001B, "left delayed flush");
}

void require_right_component_entry(const std::vector<Event> &events, uint64_t line) {
   require_event(events, line, 0, kNusiz0, 0x03, "right NUSIZ0");
   require_event(events, line, 3, kNusiz1, 0x03, "right NUSIZ1");
   require_event(events, line, 6, kHmclr, 0x03, "right HMCLR");
   require_event(events, line, 19, kHmp0, 0xC0, "right HMP0");
   require_event(events, line, 24, kHmp1, 0xD0, "right HMP1");
   require_event(events, line, 49, kResp0, 0xD0, "right RESP0");
   require_event(events, line, 52, kResp1, 0xD0, "right RESP1");
   require_event(events, line, 58, kColup0, 0x0E, "right COLUP0");
   require_event(events, line, 61, kColup1, 0x0E, "right COLUP1");
   require_event(events, line, 71, kHmove, 0x0E, "right HMOVE");
   require_address_event(events, line + 2, 55, 0x001C, "right glyph 4");
   require_address_event(events, line + 2, 58, 0x001B, "right glyph 5");
   require_address_event(events, line + 2, 61, 0x001C, "right glyph 6");
   require_address_event(events, line + 2, 64, 0x001B, "right delayed flush");
}


int main(int argc, char **argv) {
   if (argc != 2 && argc != 3 && argc != 4) {
      std::fprintf(stderr, "usage: %s ROM.bin [fingerprint|SECOND_ENTRY_LINE|FIRST_ENTRY_LINE SECOND_ENTRY_LINE]\n", argv[0]);
      return 2;
   }
   Machine machine(argv[1]);
   machine.run();
   const std::vector<Event> &events = machine.events();
   if (argc == 3 && std::strcmp(argv[2], "fingerprint") == 0) {
      require_right_component_entry(events, 40);
      require_fingerprint_center_component_entry(events);
      require_fingerprint_left_component_entry(events);
      std::printf("vcs_six_glyph_standalone_entry ok: right 40:00, centered 130:57, left 220:57 entries and 262-line frames\n");
      return 0;
   }

   unsigned long first = 131;
   unsigned long second = 0;
   if (argc == 4) {
      char *end = nullptr;
      first = std::strtoul(argv[2], &end, 0);
      if (!end || *end != '\0') {
         std::fprintf(stderr, "bad first entry line: %s\n", argv[2]);
         return 2;
      }
      end = nullptr;
      second = std::strtoul(argv[3], &end, 0);
      if (!end || *end != '\0') {
         std::fprintf(stderr, "bad second entry line: %s\n", argv[3]);
         return 2;
      }
   }
   else if (argc == 3) {
      char *end = nullptr;
      second = std::strtoul(argv[2], &end, 0);
      if (!end || *end != '\0') {
         std::fprintf(stderr, "bad second entry line: %s\n", argv[2]);
         return 2;
      }
   }

   require_component_entry(events, first);
   if (second) {
      require_component_entry_at_cycle_zero(events, second);
      std::printf("vcs_six_glyph_standalone_entry ok: calibrated lines %lu and %lu entries and 262-line frames\n", first, second);
   }
   else {
      std::printf("vcs_six_glyph_standalone_entry ok: calibrated line %lu entry and 262-line frames\n", first);
   }
   return 0;
}
