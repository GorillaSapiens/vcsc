//! @file vcs_two_plus_two_controls.cpp
//! @brief Exercise field selection and independent controls in a public two-plus-two cartridge.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

#include "mos6502.h"

namespace {
constexpr uint16_t kRomBase = 0xF000;
constexpr size_t kRomSize = 4096;
constexpr uint64_t kCyclesPerLine = 76;
constexpr uint16_t kVsync = 0x0000;
constexpr uint16_t kWsync = 0x0002;
constexpr uint16_t kInpt5 = 0x003D;
constexpr uint16_t kSwcha = 0x0280;
constexpr uint16_t kSwchb = 0x0282;
constexpr uint16_t kIntim = 0x0284;
constexpr uint16_t kTim1t = 0x0294;
constexpr uint16_t kTim8t = 0x0295;
constexpr uint16_t kTim64t = 0x0296;
constexpr uint16_t kT1024t = 0x0297;

constexpr uint8_t kIdle = 0xff;
constexpr uint8_t kRightUp = 0xfe;
constexpr uint8_t kRightLeft = 0xfb;
constexpr uint8_t kRightRight = 0xf7;
constexpr uint8_t kFireReleased = 0x80;
constexpr uint8_t kFirePressed = 0x00;

struct Write { uint16_t address; uint8_t value; };

[[noreturn]] void fail(const std::string &message) {
   std::fprintf(stderr, "vcs_two_plus_two_controls: %s\n", message.c_str());
   std::exit(1);
}

uint16_t parse_address(const char *text) {
   char *end = nullptr;
   const unsigned long value = std::strtoul(text, &end, 0);
   if (!end || *end != '\0' || value > 0xff) fail("bad zero-page address");
   return static_cast<uint16_t>(value);
}

class Machine {
public:
   Machine(const char *rom_path, const uint16_t *addresses)
      : left_score_(addresses[0]), right_score_(addresses[1]),
        left_color_(addresses[2]), right_color_(addresses[3]),
        left_x_(addresses[4]), right_x_(addresses[5]),
        selected_(addresses[6]), fire_ready_(addresses[7]),
        countdown_(addresses[8]), previous_(addresses[9]),
        cpu_(read_bus_thunk, write_bus_thunk, clock_thunk) {
      active_ = this;
      std::memset(memory_, 0, sizeof(memory_));
      std::ifstream rom(rom_path, std::ios::binary);
      if (!rom) fail("cannot open ROM");
      rom.read(reinterpret_cast<char *>(memory_ + kRomBase), kRomSize);
      if (rom.gcount() != static_cast<std::streamsize>(kRomSize))
         fail("ROM is not exactly 4096 bytes");
      cpu_.Reset();
   }

   void run() {
      while (vsync_cycles_.size() < 5) run_instruction();
      require(memory_[left_score_] == 0x12, "left score did not initialize to 12");
      require(memory_[right_score_] == 0x34, "right score did not initialize to 34");
      require(memory_[left_x_] == 16 && memory_[right_x_] == 104,
              "field positions did not initialize to 16 and 104");
      require(memory_[selected_] == 0 && memory_[fire_ready_] == 1,
              "left field did not initialize selected and armed");
      require(memory_[left_color_] == 0x0e && memory_[right_color_] == 0x26,
              "initial selected-field colors are wrong");

      // A press selects the right field exactly once and makes that selection visible.
      advance(kIdle, kFirePressed);
      require(memory_[selected_] == 1 && memory_[fire_ready_] == 0,
              "right fire did not select the right field");
      require(memory_[left_color_] == 0x06 && memory_[right_color_] == 0x2e,
              "right-field selection is not visibly highlighted");
      advance(kIdle, kFirePressed);
      require(memory_[selected_] == 1, "held right fire repeated");
      advance(kIdle, kFireReleased);
      require(memory_[fire_ready_] == 1, "right-fire release did not re-arm");

      // The selected right field can reach the physical right edge.  Its
      // sixteen-color-clock doubled glyph spans X=144..159, so 144 is the
      // largest origin that remains fully visible.
      memory_[right_x_] = 143;
      memory_[countdown_] = 19;
      memory_[previous_] = 0x0f;
      advance_frames(kRightRight, kFireReleased, 40);
      require(memory_[right_x_] == 144,
              "selected right field did not reach the right edge");
      memory_[countdown_] = 19;
      memory_[previous_] = 0x0f;
      advance_frames(kRightRight, kFireReleased, 40);
      require(memory_[right_x_] == 144,
              "selected right field moved beyond the right edge");
      memory_[right_x_] = 104;

      // The same two-sample/twentieth-frame filter used by the six-digit examples
      // must move only the selected right field.
      memory_[countdown_] = 19;
      memory_[previous_] = 0x0f;
      advance_frames(kRightLeft, kFireReleased, 39);
      require(memory_[right_x_] == 104, "right field moved before its second stable sample");
      advance(kRightLeft, kFireReleased);
      require(memory_[left_x_] == 16 && memory_[right_x_] == 103,
              "selected right field did not move left independently");

      // Vertical input changes the selected right packed-BCD value, not the left one.
      memory_[countdown_] = 19;
      memory_[previous_] = 0x0f;
      advance_frames(kRightUp, kFireReleased, 40);
      require(memory_[left_score_] == 0x12 && memory_[right_score_] == 0x35,
              "selected right score did not increment independently");

      // Toggle back to the left field and prove its movement is independent too.
      advance(kIdle, kFirePressed);
      require(memory_[selected_] == 0 && memory_[fire_ready_] == 0,
              "second right-fire press did not select the left field");
      require(memory_[left_color_] == 0x0e && memory_[right_color_] == 0x26,
              "left-field selection is not visibly highlighted");
      advance(kIdle, kFireReleased);
      memory_[countdown_] = 19;
      memory_[previous_] = 0x0f;
      advance_frames(kRightRight, kFireReleased, 40);
      require(memory_[left_x_] == 17 && memory_[right_x_] == 103,
              "selected left field did not move independently");
   }

   size_t frame_count() const { return vsync_cycles_.size(); }

private:
   static Machine *active_;
   uint16_t left_score_, right_score_, left_color_, right_color_;
   uint16_t left_x_, right_x_, selected_, fire_ready_, countdown_, previous_;
   uint8_t swcha_ = kIdle;
   uint8_t swchb_ = kIdle;
   uint8_t inpt5_ = kFireReleased;
   uint8_t memory_[65536]{};
   mos6502 cpu_;
   uint64_t cpu_cycles_ = 0;
   uint64_t virtual_cycles_ = 0;
   uint64_t instructions_ = 0;
   std::vector<Write> writes_;
   std::vector<uint64_t> vsync_cycles_;
   bool vsync_asserted_ = false;
   bool timer_active_ = false;
   uint64_t timer_start_ = 0;
   uint16_t timer_divisor_ = 1;
   uint8_t timer_loaded_ = 0;

   static uint8_t read_bus_thunk(uint16_t address) { return active_->read_bus(address); }
   static void write_bus_thunk(uint16_t address, uint8_t value) { active_->write_bus(address, value); }
   static void clock_thunk(mos6502 *) {}

   void require(bool condition, const char *message) const {
      if (!condition) fail(message);
   }

   uint8_t timer_value() const {
      if (!timer_active_) return memory_[kIntim];
      const uint64_t ticks = (virtual_cycles_ - timer_start_) / timer_divisor_;
      if (ticks <= timer_loaded_) return static_cast<uint8_t>(timer_loaded_ - ticks);
      return static_cast<uint8_t>(255 - ((ticks - timer_loaded_ - 1) & 255));
   }

   uint8_t read_bus(uint16_t address) {
      if (address == kSwcha) return swcha_;
      if (address == kSwchb) return swchb_;
      if (address == kInpt5) return inpt5_;
      if (address == kIntim) return timer_value();
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
      for (const Write &event : writes_) {
         if (event.address == kWsync) {
            const uint64_t phase = virtual_cycles_ % kCyclesPerLine;
            virtual_cycles_ += phase ? kCyclesPerLine - phase : kCyclesPerLine;
         } else if (event.address == kVsync) {
            const bool next = (event.value & 2) != 0;
            if (next && !vsync_asserted_) vsync_cycles_.push_back(virtual_cycles_);
            vsync_asserted_ = next;
         } else if (event.address == kTim1t || event.address == kTim8t ||
                    event.address == kTim64t || event.address == kT1024t) {
            load_timer(event.address, event.value);
         }
      }
      writes_.clear();
   }

   void run_instruction() {
      if (++instructions_ > 250000000) fail("instruction limit reached");
      writes_.clear();
      const uint64_t before = cpu_cycles_;
      cpu_.Run(1, cpu_cycles_, mos6502::INST_COUNT);
      virtual_cycles_ += cpu_cycles_ - before;
      apply_writes();
   }

   void advance(uint8_t swcha, uint8_t inpt5) {
      swcha_ = swcha;
      inpt5_ = inpt5;
      const size_t target = vsync_cycles_.size() + 1;
      while (vsync_cycles_.size() < target) run_instruction();
   }

   void advance_frames(uint8_t swcha, uint8_t inpt5, unsigned frames) {
      while (frames--) advance(swcha, inpt5);
   }
};

Machine *Machine::active_ = nullptr;
} // namespace

int main(int argc, char **argv) {
   if (argc != 12) {
      std::fprintf(stderr,
         "usage: %s ROM left_score right_score left_color right_color left_x right_x "
         "selected fire_ready countdown previous\n", argv[0]);
      return 2;
   }
   uint16_t addresses[10];
   for (int i = 0; i < 10; ++i) addresses[i] = parse_address(argv[i + 2]);
   Machine machine(argv[1], addresses);
   machine.run();
   std::printf("vcs_two_plus_two_controls ok: both fields selected, highlighted, moved, and changed independently across %zu frames\n",
               machine.frame_count());
   return 0;
}
