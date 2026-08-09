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

struct SweepCase {
   uint8_t offset;
   uint8_t value;
   const char *axis;
   int player;
};

// Exercise every supported player coordinate independently.  The historical
// multisprite raster is cycle-sensitive: a page-crossing graphics fetch or a
// late horizontal reposition can add a physical scanline even though one
// nominal scene still looks correct.  This sweep makes the public coordinate
// range part of the maintained renderer contract.
class SweepMachine {
public:
   SweepMachine(const char *path, uint16_t state_base, bool profile192)
      : cpu_(read_bus_thunk, write_bus_thunk, clock_thunk),
        state_base_(state_base), profile192_(profile192) {
      active_ = this;
      std::memset(memory_,0,sizeof(memory_));
      memory_[0x0280]=0xff;
      memory_[0x0282]=0xff;
      std::ifstream rom(path,std::ios::binary);
      if (!rom) fail("coordinate sweep could not open ROM");
      rom.read(reinterpret_cast<char *>(memory_ + kRomBase),kRomSize);
      if (rom.gcount()!=static_cast<std::streamsize>(kRomSize))
         fail("coordinate sweep ROM is not exactly 4096 bytes");
      cpu_.Reset();

      for (int player=0;player<6;++player)
         for (int x=0;x<=159;++x)
            cases_.push_back({static_cast<uint8_t>(player ? 5+(player-1) : 4),
                              static_cast<uint8_t>(x),"X",player});
      const int p0max=profile192_ ? 95 : 89;
      const int p1max=profile192_ ? 91 : 85;
      for (int y=0;y<=p0max;++y)
         cases_.push_back({13,static_cast<uint8_t>(y),"Y",0});
      for (int player=1;player<6;++player)
         for (int y=0;y<=p1max;++y)
            cases_.push_back({static_cast<uint8_t>(14+(player-1)),
                              static_cast<uint8_t>(y),"Y",player});
   }

   void run(const char *label) {
      constexpr uint64_t kInstructionLimit=300000000;
      constexpr uint64_t kExpectedFrameCycles=264*kCyclesPerScanline;
      size_t completed=0;
      for (uint64_t instructions=0;
           instructions<kInstructionLimit && completed<cases_.size();
           ++instructions) {
         writes_.clear();
         const uint64_t before=cpu_cycles_;
         cpu_.Run(1,cpu_cycles_,mos6502::INST_COUNT);
         virtual_cycles_ += cpu_cycles_-before;
         for (const Write &write:writes_) {
            if (write.address==kWsync) {
               const uint64_t within=virtual_cycles_%kCyclesPerScanline;
               virtual_cycles_ += within ? kCyclesPerScanline-within
                                         : kCyclesPerScanline;
            }
            else if (write.address==kVsync) {
               const bool next=(write.value&2)!=0;
               if (next && !vsync_asserted_) {
                  ++frame_;
                  if (frame_>=4 && active_case_>=0) {
                     const uint64_t delta=virtual_cycles_-last_assertion_;
                     if (delta!=kExpectedFrameCycles) {
                        const SweepCase &c=cases_[active_case_];
                        std::fprintf(stderr,
                           "vcs_multisprite_profiles: %s coordinate sweep %s P%d=%u "
                           "has %llu cycles (%llu raw lines), expected 264 raw lines\n",
                           label,c.axis,c.player,c.value,
                           static_cast<unsigned long long>(delta),
                           static_cast<unsigned long long>(delta/kCyclesPerScanline));
                        std::exit(1);
                     }
                     ++completed;
                  }
                  last_assertion_=virtual_cycles_;
                  if (frame_>=3 && completed<cases_.size()) {
                     active_case_=static_cast<long>(completed);
                     reset_scene();
                     const SweepCase &c=cases_[active_case_];
                     memory_[state_base_+c.offset]=c.value;
                  }
               }
               vsync_asserted_=next;
            }
            else if (write.address>=kTim1t && write.address<=kT1024t) {
               load_timer(write.address,write.value);
            }
         }
      }
      if (completed!=cases_.size()) fail("coordinate sweep instruction limit reached");
      const size_t expected=profile192_ ? 1516 : 1480;
      if (completed!=expected) fail("coordinate sweep case count changed");
   }

private:
   static SweepMachine *active_;
   uint8_t memory_[65536]{};
   mos6502 cpu_;
   uint16_t state_base_;
   bool profile192_;
   uint64_t cpu_cycles_=0;
   uint64_t virtual_cycles_=0;
   uint64_t timer_start_=0;
   uint64_t last_assertion_=0;
   uint16_t timer_divisor_=1;
   uint8_t timer_loaded_=0;
   bool timer_active_=false;
   bool vsync_asserted_=false;
   int frame_=-1;
   long active_case_=-1;
   std::vector<Write> writes_;
   std::vector<SweepCase> cases_;

   [[noreturn]] static void fail(const char *message) {
      std::fprintf(stderr,"vcs_multisprite_profiles: %s\n",message);
      std::exit(1);
   }
   static uint8_t read_bus_thunk(uint16_t address) { return active_->read_bus(address); }
   static void write_bus_thunk(uint16_t address,uint8_t value) { active_->write_bus(address,value); }
   static void clock_thunk(mos6502 *) {}
   bool timer_underflowed() const {
      if (!timer_active_) return false;
      return (virtual_cycles_-timer_start_)/timer_divisor_ > timer_loaded_;
   }
   uint8_t timer_value() const {
      if (!timer_active_) return memory_[kIntim];
      const uint64_t ticks=(virtual_cycles_-timer_start_)/timer_divisor_;
      if (ticks<=timer_loaded_) return static_cast<uint8_t>(timer_loaded_-ticks);
      return static_cast<uint8_t>(255-((ticks-timer_loaded_-1)&255));
   }
   uint8_t read_bus(uint16_t address) {
      if (address==kIntim) return timer_value();
      if (address==kTimint) return timer_underflowed()?0x80:0;
      return memory_[address];
   }
   void write_bus(uint16_t address,uint8_t value) {
      if (address<kRomBase) memory_[address]=value;
      writes_.push_back({address,value});
   }
   void load_timer(uint16_t address,uint8_t value) {
      timer_active_=true;
      timer_start_=virtual_cycles_;
      timer_loaded_=value;
      switch(address) {
         case kTim1t: timer_divisor_=1; break;
         case kTim8t: timer_divisor_=8; break;
         case kTim64t: timer_divisor_=64; break;
         case kT1024t: timer_divisor_=1024; break;
         default: std::abort();
      }
   }
   void reset_scene() {
      static const uint8_t xs[6]={18,36,62,88,114,140};
      static const uint8_t ys192[6]={70,16,30,44,58,72};
      static const uint8_t ys181[6]={70,16,30,44,58,72};
      const uint8_t *ys=profile192_?ys192:ys181;
      memory_[state_base_+4]=xs[0];
      for(int i=1;i<6;++i) memory_[state_base_+5+(i-1)]=xs[i];
      memory_[state_base_+13]=ys[0];
      for(int i=1;i<6;++i) memory_[state_base_+14+(i-1)]=ys[i];
   }
};
SweepMachine *SweepMachine::active_ = nullptr;
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
   82, {67,67,67,67,67,67,67,67}, 98, 39,
   {71,103,135,167,199},
   {
      {5,5,5,5,5,5,5,5},
      {5,5,5,5,5,5,5,5},
      {5,5,5,5,5,5,5,5},
      {5,5,5,5,5,5,5,5},
      {5,5,5,5,5,5,5,5}
   },
   {69,101,133,165,197}, 25,
   {67,99,131,163,195}, {59,49,39,34,24},
   {68,100,132,164,196,0}, {66,66,66,66,66,0}, 5
};

const ExpectedProfile k181Above = {
   "181-score-above", 51, 230,
   95, {67,67,67,67,67,67,67,67}, 111, 39,
   {88,116,144,172,200},
   {
      {5,5,5,5,5,5,5,5},
      {5,5,5,5,5,5,5,5},
      {5,5,5,5,5,5,5,5},
      {5,5,5,5,5,5,5,5},
      {5,5,5,5,5,5,5,5}
   },
   {86,114,142,170,198}, 25,
   {84,112,140,168,196}, {56,49,39,34,24},
   {52,85,113,141,169,197}, {71,66,66,66,66,66}, 6
};

const ExpectedProfile k181Below = {
   "181-score-below", 40, 219,
   84, {67,67,67,67,67,67,67,67}, 100, 39,
   {77,105,133,161,189},
   {
      {5,5,5,5,5,5,5,5},
      {5,5,5,5,5,5,5,5},
      {5,5,5,5,5,5,5,5},
      {5,5,5,5,5,5,5,5},
      {5,5,5,5,5,5,5,5}
   },
   {75,103,131,159,187}, 25,
   {73,101,129,157,185}, {56,49,39,34,24},
   {41,74,102,130,158,186}, {71,66,66,66,66,66}, 6
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
   if (argc != 4) {
      std::fprintf(stderr,"usage: %s ROM.bin 192|181-score-above|181-score-below STATE_BASE\n",argv[0]);
      return 2;
   }
   const ExpectedProfile *profile = nullptr;
   if (std::strcmp(argv[2],"192")==0) profile=&k192;
   else if (std::strcmp(argv[2],"181-score-above")==0) profile=&k181Above;
   else if (std::strcmp(argv[2],"181-score-below")==0) profile=&k181Below;
   else return 2;
   char *end=nullptr;
   const unsigned long parsed=std::strtoul(argv[3],&end,0);
   if (!end || *end || parsed>0xffff) return 2;
   TraceMachine machine(argv[1]);
   const auto events=machine.run(264,profile->name);
   validate(events,*profile);
   SweepMachine sweep(argv[1],static_cast<uint16_t>(parsed),profile==&k192);
   sweep.run(profile->name);
   return 0;
}
