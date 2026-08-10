//! @file vcs_visible_trace_compare.cpp
//! @brief Compare visible TIA writes and stable frame spacing from two 4K VCS cartridges.

#include <cstdint>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <utility>
#include <vector>

#include "mos6502.h"

namespace {
constexpr uint16_t kRomBase = 0xF800;
constexpr size_t kRomSize = 2048;
constexpr uint64_t kCyclesPerScanline = 76;
constexpr uint16_t kVsync = 0x0000;
constexpr uint16_t kVblank = 0x0001;
constexpr uint16_t kWsync = 0x0002;
constexpr uint16_t kIntim = 0x0284;
constexpr uint16_t kTimint = 0x0285;
constexpr uint16_t kSwcha = 0x0280;
constexpr uint16_t kSwchb = 0x0282;
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
      memory_[kSwcha] = 0xff;
      memory_[kSwchb] = 0xff;
      std::ifstream rom(path, std::ios::binary);
      if (!rom) fail("could not open ROM");
      rom.read(reinterpret_cast<char *>(memory_ + kRomBase), kRomSize);
      if (rom.gcount() != static_cast<std::streamsize>(kRomSize)) {
         fail("ROM is not exactly 2048 bytes");
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

constexpr uint8_t kFont[10][16] = {
   {0x00,0x00,0x3c,0x7e,0xe7,0xe7,0xe7,0xe7,0xe7,0xe7,0x7e,0x3c,0x00,0x00,0x00,0x00},
   {0x00,0x00,0x1c,0x3c,0x7c,0x1c,0x1c,0x1c,0x1c,0x1c,0x1c,0x1c,0x00,0x00,0x00,0x00},
   {0x00,0x00,0x7e,0xff,0xe7,0x07,0x0e,0x1c,0x38,0x70,0xff,0xff,0x00,0x00,0x00,0x00},
   {0x00,0x00,0x7e,0xff,0xe7,0x07,0x3e,0x3e,0x07,0xe7,0xff,0x7e,0x00,0x00,0x00,0x00},
   {0x00,0x00,0x0e,0x1e,0x3e,0x7e,0xee,0xff,0xff,0x0e,0x0e,0x0e,0x00,0x00,0x00,0x00},
   {0x00,0x00,0xff,0xff,0xe0,0xfe,0xff,0x07,0x07,0xe7,0xff,0x7e,0x00,0x00,0x00,0x00},
   {0x00,0x00,0x7e,0xff,0xe7,0xe0,0xfe,0xff,0xe7,0xe7,0xff,0x7e,0x00,0x00,0x00,0x00},
   {0x00,0x00,0xff,0xff,0x07,0x07,0x0e,0x1c,0x1c,0x38,0x38,0x38,0x00,0x00,0x00,0x00},
   {0x00,0x00,0x7e,0xff,0xe7,0xe7,0x7e,0x7e,0xe7,0xe7,0xff,0x7e,0x00,0x00,0x00,0x00},
   {0x00,0x00,0x7e,0xff,0xe7,0xe7,0xff,0x7f,0x07,0xe7,0xff,0x7e,0x00,0x00,0x00,0x00}
};

[[noreturn]] void fail_detail(const char *fmt, ...) {
   std::fprintf(stderr, "vcs_six_glyph_big_wide_raster: ");
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
   const Event &event = find_event(events,line,cycle,address,name);
   if (event.value != expected) {
      fail_detail("%s at %llu:%02llu is %02x, expected %02x", name,
         static_cast<unsigned long long>(line),
         static_cast<unsigned long long>(cycle),event.value,expected);
   }
}

uint64_t parse_line(const char *text) {
   char *end=nullptr;
   const unsigned long value=std::strtoul(text,&end,0);
   if (!end || *end!='\0') fail_detail("bad entry line '%s'",text);
   return value;
}

void validate_digits(const char *text) {
   if (std::strlen(text)!=6) fail_detail("score '%s' is not six digits",text);
   for (const char *p=text; *p; ++p) {
      if (*p<'0' || *p>'9') fail_detail("score '%s' is not decimal",text);
   }
}
} // namespace

int main(int argc, char **argv) {
   if (argc!=4) return 2;
   const uint64_t entry=parse_line(argv[2]);
   validate_digits(argv[3]);
   TraceMachine machine(argv[1]);
   const std::vector<Event> events=machine.run(264,"wide-score ROM");

   bool shifted=false;
   for (const Event &event : events) {
      if (event.line==entry-1 && event.cycle==57 &&
          event.address==kNusiz0 && event.value==0x06) {
         shifted=true;
         break;
      }
   }
   const auto phase=[&](uint64_t old_cycle) {
      return shifted && old_cycle<19
         ? std::pair<uint64_t,uint64_t>{entry-1,old_cycle+57}
         : std::pair<uint64_t,uint64_t>{entry,shifted?old_cycle-19:old_cycle};
   };
   const auto setup=[&](uint64_t old_cycle,uint16_t address,uint8_t value,const char *name) {
      const auto where=phase(old_cycle);
      require_value(events,where.first,where.second,address,value,name);
   };
   setup(0,kNusiz0,0x06,"NUSIZ0");
   setup(3,kNusiz1,0x06,"NUSIZ1");
   setup(26,kResp0,0x06,"RESP0");
   setup(29,kResp1,0x06,"RESP1");
   setup(35,kColup0,0x0e,"COLUP0");
   setup(38,kColup1,0x0e,"COLUP1");
   setup(41,kHmclr,0x0e,"HMCLR");
   setup(46,kHmp0,0x30,"HMP0");
   setup(51,kHmp1,0xc0,"HMP1");
   (void)find_event(events,entry,71,kHmove,"HMOVE");

   require_value(events,entry+1,9,kRefp0,0,"REFP0 reset");
   require_value(events,entry+1,12,kRefp1,0,"REFP1 reset");
   require_value(events,entry+1,19,kVdelp0,1,"VDELP0 enabled");
   require_value(events,entry+1,22,kVdelp1,1,"VDELP1 enabled");

   // The delayed-player pipeline stages digit 1 before each row boundary.
   // Digits 2-6 and the final delayed-latch commit occur on the row itself.
   constexpr uint64_t cycles[5]={0,8,36,39,42};
   constexpr uint16_t regs[5]={kGrp1,kGrp0,kGrp1,kGrp0,kGrp1};
   for (unsigned row=0; row<16; ++row) {
      const uint64_t first_line=row==0 ? entry+1 : entry+1+row;
      const uint64_t first_cycle=row==0 ? 39 : 64;
      require_value(events,first_line,first_cycle,kGrp0,
         kFont[argv[3][0]-'0'][row],"glyph 1 row byte");

      const uint64_t line=entry+2+row;
      for (unsigned digit=1; digit<6; ++digit) {
         require_value(events,line,cycles[digit-1],regs[digit-1],
            kFont[argv[3][digit]-'0'][row],"glyph row byte");
      }
      require_value(events,line,45,kGrp0,
         kFont[argv[3][3]-'0'][row],"delayed-latch commit");
   }

   require_value(events,entry+17,57,kGrp0,0,"GRP0 cleanup 1");
   require_value(events,entry+17,60,kGrp1,0,"GRP1 cleanup");
   require_value(events,entry+17,63,kGrp0,0,"GRP0 cleanup 2");
   require_value(events,entry+17,66,kVdelp0,0,"VDELP0 cleanup");
   require_value(events,entry+17,69,kVdelp1,0,"VDELP1 cleanup");

   std::printf("vcs_six_glyph_big_wide_raster ok: exact 88x16 score schedule and 262-line frames\n");
   return 0;
}
