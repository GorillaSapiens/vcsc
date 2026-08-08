//! @file vcs_visible_trace_compare.cpp
//! @brief Compare visible TIA writes and stable frame spacing from two 4K VCS cartridges.

#include <cstdint>
#include <cstdarg>
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


namespace {
constexpr uint16_t kGrp0 = 0x001B;
constexpr uint16_t kGrp1 = 0x001C;
constexpr uint16_t kRefp0 = 0x000B;
constexpr uint16_t kRefp1 = 0x000C;
constexpr uint16_t kVdelp0 = 0x0025;
constexpr uint16_t kVdelp1 = 0x0026;
constexpr uint16_t kNusiz0 = 0x0004;
constexpr uint16_t kNusiz1 = 0x0005;
constexpr uint16_t kResp0 = 0x0010;
constexpr uint16_t kResp1 = 0x0011;
constexpr uint16_t kHmp0 = 0x0020;
constexpr uint16_t kHmp1 = 0x0021;
constexpr uint16_t kHmove = 0x002A;
constexpr uint16_t kHmclr = 0x002B;
constexpr uint16_t kColup0 = 0x0006;
constexpr uint16_t kColup1 = 0x0007;

constexpr uint8_t kFont[10][8] = {
   {0x3c,0x66,0x66,0x66,0x66,0x66,0x66,0x3c},
   {0x08,0x18,0x38,0x18,0x18,0x18,0x18,0x7e},
   {0x3c,0x46,0x06,0x06,0x3c,0x60,0x60,0x7e},
   {0x3c,0x46,0x06,0x1c,0x06,0x06,0x46,0x3c},
   {0x0c,0x1c,0x2c,0x4c,0x4c,0x7e,0x0c,0x0c},
   {0x7e,0x60,0x60,0x3c,0x06,0x06,0x46,0x3c},
   {0x3c,0x62,0x60,0x7c,0x66,0x66,0x66,0x3c},
   {0x3e,0x42,0x06,0x0c,0x18,0x30,0x30,0x30},
   {0x3c,0x66,0x66,0x3c,0x66,0x66,0x66,0x3c},
   {0x3c,0x66,0x66,0x66,0x3e,0x06,0x46,0x3c}
};

[[noreturn]] void fail_detail(const char *fmt, ...) {
   std::fprintf(stderr, "vcs_six_glyph_raster: ");
   va_list ap;
   va_start(ap, fmt);
   std::vfprintf(stderr, fmt, ap);
   va_end(ap);
   std::fputc('\n', stderr);
   std::exit(1);
}

const Event &find_event(const std::vector<Event> &events, uint64_t line,
                        uint64_t cycle, uint16_t address, const char *name) {
   for (const Event &event : events) {
      if (event.line == line && event.cycle == cycle && event.address == address) {
         return event;
      }
   }
   fail_detail("missing %s at %llu:%02llu address %02x", name,
      static_cast<unsigned long long>(line),
      static_cast<unsigned long long>(cycle), address);
}

void require_value(const std::vector<Event> &events, uint64_t line,
                   uint64_t cycle, uint16_t address, uint8_t expected,
                   const char *name) {
   const Event &event = find_event(events, line, cycle, address, name);
   if (event.value != expected) {
      fail_detail("%s at %llu:%02llu is %02x, expected %02x", name,
         static_cast<unsigned long long>(line),
         static_cast<unsigned long long>(cycle), event.value, expected);
   }
}

void require_entry(const std::vector<Event> &events, uint64_t line) {
   bool shifted = false;
   for (const Event &event : events) {
      if (event.line == line - 1 && event.cycle == 57 &&
          event.address == kNusiz0 && event.value == 0x03) {
         shifted = true;
         break;
      }
   }

   const uint64_t first_line = shifted ? line - 1 : line;
   const uint64_t first_cycle = shifted ? 57 : 0;
   require_value(events,first_line,first_cycle,kNusiz0,0x03,"NUSIZ0");
   require_value(events,first_line,first_cycle+3,kNusiz1,0x03,"NUSIZ1");

   bool fixed_color = false;
   const uint64_t fixed_line = shifted ? line - 1 : line;
   const uint64_t fixed_cycle = shifted ? 65 : 8;
   for (const Event &event : events) {
      if (event.line == fixed_line && event.cycle == fixed_cycle &&
          event.address == kColup0) {
         fixed_color = true;
         break;
      }
   }
   if (fixed_color) {
      require_value(events,fixed_line,fixed_cycle,kColup0,0x0e,"COLUP0");
      require_value(events,fixed_line,fixed_cycle+3,kColup1,0x0e,"COLUP1");
   }
   else if (shifted) {
      require_value(events,line,19,kColup0,0x0e,"mutable COLUP0");
      require_value(events,line,22,kColup1,0x0e,"mutable COLUP1");
   }
   else {
      require_value(events,line,38,kColup0,0x0e,"mutable COLUP0");
      require_value(events,line,41,kColup1,0x0e,"mutable COLUP1");
   }

   if (shifted) {
      (void)find_event(events,line-1,71,kHmclr,"HMCLR");
      require_value(events,line,0,kHmp0,0x80,"HMP0");
      require_value(events,line,5,kHmp1,0x90,"HMP1");
      require_value(events,line,10,kResp0,0x90,"RESP0");
      require_value(events,line,13,kResp1,0x90,"RESP1");
   }
   else {
      (void)find_event(events,line,14,kHmclr,"HMCLR");
      require_value(events,line,19,kHmp0,0x80,"HMP0");
      require_value(events,line,24,kHmp1,0x90,"HMP1");
      require_value(events,line,29,kResp0,0x90,"RESP0");
      require_value(events,line,32,kResp1,0x90,"RESP1");
   }
   (void)find_event(events,line,71,kHmove,"HMOVE");
   require_value(events,line+1,9,kRefp0,0,"REFP0 reset");
   require_value(events,line+1,12,kRefp1,0,"REFP1 reset");
   require_value(events,line+1,19,kVdelp0,1,"VDELP0 enable");
   require_value(events,line+1,22,kVdelp1,1,"VDELP1 enable");
}

uint8_t glyph_event(const std::vector<Event> &events, uint64_t line,
                    uint64_t cycle, uint16_t address, const char *name) {
   return find_event(events,line,cycle,address,name).value;
}

void require_score(const std::vector<Event> &events, uint64_t entry,
                   const char *digits) {
   require_entry(events, entry);
   for (unsigned row = 0; row < 8; ++row) {
      uint8_t actual[6];
      const uint64_t first_line = entry + 1 + row;
      const uint64_t raster_line = entry + 2 + row;
      actual[0] = glyph_event(events, first_line, row == 0 ? 39 : 64,
                              kGrp0, "digit 1");
      actual[1] = glyph_event(events, raster_line, 0, kGrp1, "digit 2");
      actual[2] = glyph_event(events, raster_line, 8, kGrp0, "digit 3");
      actual[3] = glyph_event(events, raster_line, 36, kGrp1, "digit 4");
      actual[4] = glyph_event(events, raster_line, 39, kGrp0, "digit 5");
      actual[5] = glyph_event(events, raster_line, 42, kGrp1, "digit 6");
      require_value(events, raster_line, 45, kGrp0, actual[3],
                    "digit 4 delayed flush");

      for (unsigned digit = 0; digit < 6; ++digit) {
         const uint8_t expected = kFont[digits[digit]-'0'][row];
         if (actual[digit] != expected) {
            fail_detail("entry %llu row %u digit %u byte is %02x, expected %02x",
               static_cast<unsigned long long>(entry), row, digit + 1,
               actual[digit], expected);
         }
         for (unsigned bit = 0; bit < 8; ++bit) {
            const bool observed = (actual[digit] & (0x80u >> bit)) != 0;
            const bool wanted = (expected & (0x80u >> bit)) != 0;
            if (observed != wanted) {
               fail_detail("entry %llu row %u pixel %u differs",
                  static_cast<unsigned long long>(entry), row, digit*8+bit);
            }
         }
      }
   }
   require_value(events,entry+9,57,kGrp0,0,"GRP0 cleanup 1");
   require_value(events,entry+9,60,kGrp1,0,"GRP1 cleanup");
   require_value(events,entry+9,63,kGrp0,0,"GRP0 cleanup 2");
   require_value(events,entry+9,66,kVdelp0,0,"VDELP0 cleanup");
   require_value(events,entry+9,69,kVdelp1,0,"VDELP1 cleanup");
}

uint64_t parse_line(const char *text) {
   char *end = nullptr;
   const unsigned long value = std::strtoul(text,&end,0);
   if (!end || *end != '\0') fail_detail("bad entry line '%s'",text);
   return value;
}

void validate_digits(const char *text) {
   if (std::strlen(text) != 6) fail_detail("score '%s' is not six digits",text);
   for (const char *p=text; *p; ++p) if (*p<'0' || *p>'9')
      fail_detail("score '%s' is not decimal",text);
}
} // namespace

int main(int argc, char **argv) {
   if (argc < 4 || ((argc - 2) % 2) != 0) {
      std::fprintf(stderr,"usage: %s ROM.bin ENTRY_LINE SIX_DIGITS [ENTRY_LINE SIX_DIGITS ...]\n",argv[0]);
      return 2;
   }
   TraceMachine machine(argv[1]);
   const std::vector<Event> events = machine.run(264,"ROM");
   for (int i=2; i<argc; i+=2) {
      validate_digits(argv[i+1]);
      require_score(events,parse_line(argv[i]),argv[i+1]);
   }
   std::printf("vcs_six_glyph_raster ok: %d exact 48x8 score rasters, hostile reflection reset, and 262-line frames\n",(argc-2)/2);
   return 0;
}
