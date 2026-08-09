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
               "vcs_multisprite_profiles: %s frame %zu has %llu cycles "
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
      std::fprintf(stderr, "vcs_multisprite_profiles: %s\n", message);
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
struct ExpectedProfile {
   const char *name;
   uint64_t game_min;
   uint64_t game_max;
   uint64_t p0_first;
   uint64_t p0_cycle[8];
   uint64_t p0_clear_line;
   uint64_t p0_clear_cycle;
   uint64_t p1_first[5];
   uint64_t p1_cycle[5][8];
   uint64_t color_line[5];
   uint64_t color_cycle;
   uint64_t repo_line[5];
   uint64_t repo_cycle[5];
   uint64_t hmove_line[6];
   uint64_t hmove_cycle[6];
   size_t hmove_count;
};

[[noreturn]] void fail_profile(const char *profile, const char *message) {
   std::fprintf(stderr, "vcs_multisprite_profiles: %s: %s\n", profile, message);
   std::exit(1);
}

const ExpectedProfile k192 = {
   "192", 40, 230,
   78, {8,10,12,15,18,21,24,27}, 94, 0,
   {66,99,132,165,198},
   {
      {7,10,13,16,19,21,23,25},
      {7,10,13,16,19,22,25,28},
      {7,10,13,16,19,22,25,28},
      {7,10,13,16,19,22,25,28},
      {7,10,13,16,19,22,25,28}
   },
   {64,97,130,163,196}, 25,
   {62,95,128,161,193}, {22,10,9,4,70},
   {63,96,129,162,195,0}, {66,66,66,66,66,0}, 5
};

const ExpectedProfile k181Above = {
   "181-score-above", 51, 230,
   92, {2,4,6,8,10,13,16,19}, 107, 68,
   {84,113,142,171,199},
   {
      {7,10,13,15,17,19,21,23},
      {7,10,13,16,19,22,25,28},
      {7,10,13,16,19,22,25,28},
      {7,10,13,16,19,22,25,28},
      {7,10,13,16,19,22,25,28}
   },
   {82,111,140,169,197}, 25,
   {80,109,138,166,195}, {34,2,1,72,62},
   {51,81,110,139,168,196}, {71,66,66,66,66,66}, 6
};

const ExpectedProfile k181Below = {
   "181-score-below", 40, 219,
   81, {1,3,5,7,9,12,15,18}, 96, 68,
   {73,102,131,160,188},
   {
      {6,9,12,14,16,18,20,22},
      {6,9,12,15,18,21,24,27},
      {6,9,12,15,18,21,24,27},
      {6,9,12,15,18,21,24,27},
      {6,9,12,15,18,21,24,27}
   },
   {71,100,129,158,186}, 24,
   {69,98,127,155,184}, {35,2,1,72,62},
   {40,70,99,128,157,185}, {71,65,65,65,65,65}, 6
};

void validate(const std::vector<Event> &events, const ExpectedProfile &p) {
   struct Row { uint64_t line, cycle; uint8_t value; };
   std::vector<Row> p0, p1, colors, repos, hmoves;
   bool saw_p0_clear = false;
   bool pf1[256]{};
   bool pf2[256]{};

   for (const Event &e : events) {
      if (e.line < p.game_min || e.line > p.game_max) continue;
      if (e.address == 0x001b) {
         if (e.value) p0.push_back({e.line,e.cycle,e.value});
         if (e.line == p.p0_clear_line && e.cycle == p.p0_clear_cycle && e.value == 0)
            saw_p0_clear = true;
      }
      if (e.address == 0x001c && e.value) p1.push_back({e.line,e.cycle,e.value});
      if (e.address == 0x0007) colors.push_back({e.line,e.cycle,e.value});
      if (e.address == 0x0011) repos.push_back({e.line,e.cycle,e.value});
      if (e.address == 0x002a) hmoves.push_back({e.line,e.cycle,e.value});
      if (e.address == 0x000e) pf1[e.value] = true;
      if (e.address == 0x000f) pf2[e.value] = true;
   }

   static const uint8_t expected_p0[8] = {0x3c,0x66,0xc3,0xdb,0xdb,0xc3,0x66,0x3c};
   static const uint8_t expected_p1[5][8] = {
      {0x7e,0x60,0x60,0x7c,0x06,0x06,0x66,0x3c},
      {0x0c,0x1c,0x3c,0x6c,0xcc,0xfe,0x0c,0x0c},
      {0x7c,0x06,0x06,0x3c,0x06,0x06,0x66,0x3c},
      {0x3c,0x66,0x06,0x0c,0x18,0x30,0x60,0x7e},
      {0x18,0x38,0x78,0x18,0x18,0x18,0x18,0x7e}
   };
   static const uint8_t expected_colors[5] = {0xbe,0x5e,0xae,0xce,0x4e};
   static const uint8_t expected_pf1[6] = {0xc3,0xa5,0x18,0x24,0x42,0x81};
   static const uint8_t expected_pf2[6] = {0xe7,0x66,0xa5,0x5a,0x3c,0x81};

   if (p0.size() != 8) fail_profile(p.name,"P0 row count changed");
   for (size_t i=0;i<8;++i) {
      if (p0[i].line != p.p0_first + 2*i || p0[i].cycle != p.p0_cycle[i] ||
          p0[i].value != expected_p0[i])
         fail_profile(p.name,"P0 glyph/timing changed");
   }
   if (!saw_p0_clear) fail_profile(p.name,"P0 trailing clear is missing");

   if (p1.size() != 40) fail_profile(p.name,"P1 multiplexed row count changed");
   for (size_t s=0;s<5;++s) for (size_t r=0;r<8;++r) {
      const Row &a=p1[s*8+r];
      if (a.line != p.p1_first[s] + 2*r || a.cycle != p.p1_cycle[s][r] ||
          a.value != expected_p1[s][r])
         fail_profile(p.name,"P1 multiplexed glyph/timing changed");
   }

   // Ignore any score-owned COLUP1/RESP1/HMOVE events by filtering to the
   // gameplay interval above. Exactly five logical P1 setup transitions remain.
   if (colors.size() != 5) fail_profile(p.name,"P1 color count changed");
   if (repos.size() != 5) fail_profile(p.name,"P1 reposition count changed");
   for (size_t i=0;i<5;++i) {
      if (colors[i].line != p.color_line[i] || colors[i].cycle != p.color_cycle ||
          colors[i].value != expected_colors[i])
         fail_profile(p.name,"P1 color schedule changed");
      if (repos[i].line != p.repo_line[i] || repos[i].cycle != p.repo_cycle[i])
         fail_profile(p.name,"P1 reposition schedule changed");
   }

   if (hmoves.size() != p.hmove_count) fail_profile(p.name,"visible HMOVE count changed");
   for (size_t i=0;i<p.hmove_count;++i) {
      if (hmoves[i].line != p.hmove_line[i] || hmoves[i].cycle != p.hmove_cycle[i])
         fail_profile(p.name,"visible HMOVE schedule changed");
   }

   for (uint8_t v : expected_pf1) if (!pf1[v]) fail_profile(p.name,"PF1 row set changed");
   for (uint8_t v : expected_pf2) if (!pf2[v]) fail_profile(p.name,"PF2 row set changed");

   // The 181 public proofs use the standard centered score. Lock its physical
   // placement in this composition without depending on ignored strobe-bus data.
   if (std::strstr(p.name,"181-score-")) {
      const uint64_t entry = std::strstr(p.name,"above") ? 40 : 221;
      size_t score_rows=0;
      bool score_color=false;
      bool score_reposition=false;
      for (const Event &e : events) {
         if (e.line >= entry+1 && e.line <= entry+9 &&
             (e.address==0x001b || e.address==0x001c) && e.value) ++score_rows;
         if (e.line==entry && e.address==0x0007 && e.value==0x0e) score_color=true;
         if (e.line==entry && e.address==0x0011) score_reposition=true;
      }
      if (score_rows < 40 || !score_color || !score_reposition)
         fail_profile(p.name,"score placement/pixel activity changed");
   }

   std::printf("vcs_multisprite_profiles %s ok: 8 P0 rows, 40 P1 rows, five multiplexed colors/repositions, six playfield rows\n", p.name);
}
}

int main(int argc, char **argv) {
   if (argc != 3) {
      std::fprintf(stderr,"usage: %s ROM.bin 192|181-score-above|181-score-below\n",argv[0]);
      return 2;
   }
   const ExpectedProfile *profile = nullptr;
   if (std::strcmp(argv[2],"192")==0) profile=&k192;
   else if (std::strcmp(argv[2],"181-score-above")==0) profile=&k181Above;
   else if (std::strcmp(argv[2],"181-score-below")==0) profile=&k181Below;
   else return 2;
   TraceMachine machine(argv[1]);
   const auto events=machine.run(264,profile->name);
   validate(events,*profile);
   return 0;
}
