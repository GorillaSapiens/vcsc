//! @file vcs_all_five_interactive_example_matrix.cpp
//! @brief Exercise the public all-five interactive renderer examples.

#include <array>
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
constexpr uint16_t kSwcha = 0x0280;
constexpr uint16_t kSwchb = 0x0282;
constexpr uint16_t kIntim = 0x0284;
constexpr uint16_t kTim1t = 0x0294;
constexpr uint16_t kTim8t = 0x0295;
constexpr uint16_t kTim64t = 0x0296;
constexpr uint16_t kT1024t = 0x0297;

constexpr uint8_t kIdle = 0xff;
constexpr uint8_t kLeftUp = 0xef;
constexpr uint8_t kLeftDown = 0xdf;
constexpr uint8_t kLeftLeft = 0xbf;
constexpr uint8_t kLeftRight = 0x7f;
constexpr uint8_t kRightUp = 0xfe;
constexpr uint8_t kRightDown = 0xfd;
constexpr uint8_t kRightLeft = 0xfb;
constexpr uint8_t kRightRight = 0xf7;
constexpr uint8_t kSelect = 0xfd;
constexpr uint8_t kReset = 0xfe;

struct Write { uint16_t address; uint8_t value; };

[[noreturn]] void fail(const std::string &message) {
   std::fprintf(stderr, "vcs_all_five_interactive_example_matrix: %s\n", message.c_str());
   std::exit(1);
}

uint16_t parse_address(const char *text) {
   char *end = nullptr;
   const unsigned long value = std::strtoul(text, &end, 0);
   if (!end || *end != '\0' || value > 0xff) fail("bad zero-page address");
   return static_cast<uint16_t>(value);
}

struct Profile {
   const char *name;
   uint8_t max_y;
   bool has_score;
};

Profile parse_profile(const std::string &name) {
   if (name == "all5_192") return {"all5_192", 95, false};
   if (name == "all5_above") return {"all5_above", 87, true};
   if (name == "all5_below") return {"all5_below", 87, true};
   if (name == "all5_dual") return {"all5_dual", 79, true};
   fail("bad profile");
}

class Machine {
public:
   Machine(const char *rom_path, const Profile &profile,
           uint16_t object_x, std::array<uint16_t,5> y,
           uint16_t selected_object, uint16_t select_ready,
           uint16_t score_digit, uint16_t score_countdown, uint16_t score_previous,
           uint16_t score, uint16_t score_color)
      : profile_(profile), object_x_(object_x), y_(y),
        selected_object_(selected_object), select_ready_(select_ready),
        score_digit_(score_digit), score_countdown_(score_countdown), score_previous_(score_previous),
        score_(score), score_color_(score_color),
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
      validate_frame_spacing();
      require_initial("initial state");

      advance(kLeftLeft, kIdle);
      require(memory_[object_x_] == 19, "P0 did not move left by one pixel");
      advance(kLeftRight, kIdle);
      require(memory_[object_x_] == 20, "P0 did not move right by one pixel");
      advance(kLeftUp, kIdle);
      require(memory_[y_[0]] == 17, "P0 did not move up by one scanline");
      advance(kLeftDown, kIdle);
      require(memory_[y_[0]] == 18, "P0 did not move down by one scanline");

      for (uint8_t object = 1; object < 5; ++object) {
         advance(kIdle, kSelect);
         require(selected_object() == object, "SELECT did not advance to the next object");
         advance(kIdle, kSelect);
         require(selected_object() == object, "held SELECT repeated");
         advance(kIdle, kIdle);
         require(select_ready(), "SELECT release did not re-arm");

         const uint8_t old_x = memory_[object_x_ + object];
         const uint8_t old_y = memory_[y_[object]];
         advance(kLeftRight, kIdle);
         require(memory_[object_x_ + object] == old_x + 1,
                 "selected object did not move right");
         advance(kLeftDown, kIdle);
         require(memory_[y_[object]] == old_y + 1,
                 "selected object did not move down");
      }

      require(selected_object() == 4, "object cycle did not finish on Ball");
      memory_[object_x_ + 4] = 0;
      advance(kLeftLeft, kIdle);
      require(memory_[object_x_ + 4] == 0, "X underflow escaped 0");
      memory_[object_x_ + 4] = 159;
      advance(kLeftRight, kIdle);
      require(memory_[object_x_ + 4] == 159, "X overflow escaped 159");
      memory_[y_[4]] = 0;
      advance(kLeftUp, kIdle);
      require(memory_[y_[4]] == 0, "Y underflow escaped 0");
      memory_[y_[4]] = profile_.max_y;
      advance(kLeftDown, kIdle);
      require(memory_[y_[4]] == profile_.max_y, "Y overflow escaped renderer range");

      if (profile_.has_score) exercise_score();

      memory_[object_x_] = 12;
      set_selected_object(3);
      if (profile_.has_score) {
         set_score(999999);
         set_score_digit(4);
         set_score_countdown(7);
         set_score_previous(2);
         memory_[score_color_] = 0xae;
      }
      advance(kIdle, kReset);
      advance(kIdle, kIdle);
      require_initial("RESET state");
   }

   size_t frame_count() const { return vsync_cycles_.size(); }

private:
   static Machine *active_;
   Profile profile_;
   uint16_t object_x_;
   std::array<uint16_t,5> y_;
   uint16_t selected_object_;
   uint16_t select_ready_;
   uint16_t score_digit_;
   uint16_t score_countdown_;
   uint16_t score_previous_;
   uint16_t score_;
   uint16_t score_color_;
   uint8_t swcha_ = kIdle;
   uint8_t swchb_ = kIdle;
   uint8_t memory_[65536]{};
   mos6502 cpu_;
   uint64_t cpu_cycles_ = 0;
   uint64_t virtual_cycles_ = 0;
   std::vector<Write> writes_;
   std::vector<uint64_t> vsync_cycles_;
   bool vsync_asserted_ = false;
   bool timer_active_ = false;
   uint64_t timer_start_ = 0;
   uint16_t timer_divisor_ = 1;
   uint8_t timer_loaded_ = 0;
   bool timer_overrun_ = false;
   uint64_t instructions_ = 0;

   static uint8_t read_bus_thunk(uint16_t address) { return active_->read_bus(address); }
   static void write_bus_thunk(uint16_t address, uint8_t value) { active_->write_bus(address, value); }
   static void clock_thunk(mos6502 *) {}

   void require(bool condition, const char *message) const {
      if (!condition) fail(std::string(profile_.name) + ": " + message);
   }

   uint8_t selected_object() const { return memory_[selected_object_]; }
   void set_selected_object(uint8_t value) { memory_[selected_object_] = value; }
   bool select_ready() const { return memory_[select_ready_] != 0; }
   uint8_t score_digit() const { return memory_[score_digit_]; }
   uint8_t score_countdown() const { return memory_[score_countdown_]; }
   uint8_t score_previous() const { return memory_[score_previous_]; }
   void set_score_digit(uint8_t value) { memory_[score_digit_] = value; }
   void set_score_countdown(uint8_t value) { memory_[score_countdown_] = value; }
   void set_score_previous(uint8_t value) { memory_[score_previous_] = value; }

   uint8_t timer_value() const {
      if (!timer_active_) return memory_[kIntim];
      const uint64_t ticks = (virtual_cycles_ - timer_start_) / timer_divisor_;
      if (ticks <= timer_loaded_) return static_cast<uint8_t>(timer_loaded_ - ticks);
      return static_cast<uint8_t>(255 - ((ticks - timer_loaded_ - 1) & 255));
   }

   uint8_t read_bus(uint16_t address) {
      if (address == kSwcha) return swcha_;
      if (address == kSwchb) return swchb_;
      if (address == kIntim) {
         if (timer_active_ && (virtual_cycles_ - timer_start_) / timer_divisor_ > timer_loaded_)
            timer_overrun_ = true;
         return timer_value();
      }
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

   void advance(uint8_t swcha, uint8_t swchb) {
      swcha_ = swcha;
      swchb_ = swchb;
      const size_t target = vsync_cycles_.size() + 1;
      while (vsync_cycles_.size() < target) run_instruction();
   }
   void advance_frames(uint8_t swcha, uint8_t swchb, unsigned frames) {
      while (frames--) advance(swcha, swchb);
   }

   void set_score(unsigned value) {
      auto pair = [](unsigned pair_value) -> uint8_t {
         return static_cast<uint8_t>(((pair_value / 10) << 4) | (pair_value % 10));
      };
      memory_[score_] = pair(value % 100);
      memory_[score_ + 1] = pair((value / 100) % 100);
      memory_[score_ + 2] = pair((value / 10000) % 100);
   }
   unsigned score_value() const {
      auto pair = [](uint8_t byte) -> unsigned {
         const unsigned lo = byte & 0x0f;
         const unsigned hi = byte >> 4;
         if (lo > 9 || hi > 9) fail("invalid packed BCD score");
         return hi * 10 + lo;
      };
      return pair(memory_[score_]) + 100 * pair(memory_[score_ + 1]) +
             10000 * pair(memory_[score_ + 2]);
   }

   void exercise_score() {
      require(score_digit() == 0, "score did not start on ones digit");
      require(score_value() == 123456, "score initial value changed");
      require(memory_[score_color_] == 0x0e, "score did not start at color $0e");

      set_score_countdown(19);
      set_score_previous(15);
      advance_frames(kRightUp, kIdle, 39);
      require(score_value() == 123456, "right joystick acted before two samples");
      advance(kRightUp, kIdle);
      require(score_value() == 123457, "stable up did not add one");
      advance_frames(kRightUp, kIdle, 20);
      require(score_value() == 123458, "held up did not repeat after twenty frames");
      advance_frames(kRightDown, kIdle, 20);
      require(score_value() == 123458, "changed direction acted on first sample");
      advance_frames(kRightDown, kIdle, 20);
      require(score_value() == 123457, "stable down did not subtract one");

      set_score(123456);
      set_score_digit(0);
      set_score_countdown(19);
      set_score_previous(15);
      memory_[score_color_] = 0x0e;
      advance_frames(kRightLeft, kIdle, 39);
      require(score_digit() == 0, "horizontal selection acted too early");
      advance(kRightLeft, kIdle);
      require(score_digit() == 1, "stable left did not select tens");
      require(memory_[score_color_] == 0x1e, "digit change did not advance color");
      advance_frames(kRightLeft, kIdle, 20);
      require(score_digit() == 2, "held left did not repeat");
      require(memory_[score_color_] == 0x2e, "repeated selection did not advance color");
      advance_frames(kRightRight, kIdle, 20);
      require(score_digit() == 2, "changed horizontal direction acted too early");
      advance_frames(kRightRight, kIdle, 20);
      require(score_digit() == 1, "stable right did not return to tens");
      require(memory_[score_color_] == 0x3e, "right selection did not advance color");

      set_score(123456);
      set_score_countdown(19);
      set_score_previous(15);
      advance_frames(kRightUp, kIdle, 40);
      require(score_value() == 123466, "selected tens digit did not add ten");
   }

   void require_initial(const char *which) const {
      const std::string prefix = std::string(which) + " ";
      const std::array<uint8_t,5> x{{20,130,50,110,80}};
      const std::array<uint8_t,5> y{{18,78,34,62,48}};
      for (size_t i = 0; i < 5; ++i) {
         require(memory_[object_x_ + i] == x[i], (prefix + "object X changed").c_str());
         require(memory_[y_[i]] == y[i], (prefix + "object Y changed").c_str());
      }
      require(selected_object() == 0, (prefix + "selected object is not P0").c_str());
      require(select_ready(), (prefix + "SELECT latch is not armed").c_str());
      if (profile_.has_score) {
         require(score_value() == 123456, (prefix + "score changed").c_str());
         require(score_digit() == 0, (prefix + "selected score digit is not ones").c_str());
         require(score_countdown() <= 19, (prefix + "score countdown is out of range").c_str());
         require(score_previous() == 15, (prefix + "right joystick history is not neutral").c_str());
         require(memory_[score_color_] == 0x0e, (prefix + "score color is not $0e").c_str());
      }
   }

   void validate_frame_spacing() const {
      require(!timer_overrun_, "frame timer overran");
      const uint64_t expected = 264 * kCyclesPerLine;
      for (size_t i = 4; i < vsync_cycles_.size(); ++i) {
         const uint64_t actual = vsync_cycles_[i] - vsync_cycles_[i - 1];
         if (actual != expected) fail(std::string(profile_.name) + ": frame is not 262 lines");
      }
   }
};
Machine *Machine::active_ = nullptr;
} // namespace

int main(int argc, char **argv) {
   if (argc != 16) {
      std::fprintf(stderr,
         "usage: %s ROM all5_192|all5_above|all5_below|all5_dual object_x p0_y p1_y m0_y m1_y ball_y selected_object select_ready score_digit|none score_countdown|none score_previous|none score|none score_color|none\n",
         argv[0]);
      return 2;
   }
   const Profile profile = parse_profile(argv[2]);
   auto optional_address = [&](int index) -> uint16_t {
      if (profile.has_score) return parse_address(argv[index]);
      if (std::strcmp(argv[index], "none")) fail("scoreless profile requires none score arguments");
      return 0;
   };
   Machine machine(argv[1], profile, parse_address(argv[3]),
                   {{parse_address(argv[4]), parse_address(argv[5]), parse_address(argv[6]),
                     parse_address(argv[7]), parse_address(argv[8])}},
                   parse_address(argv[9]), parse_address(argv[10]),
                   optional_address(11), optional_address(12), optional_address(13),
                   optional_address(14), optional_address(15));
   machine.run();
   std::printf("vcs_all_five_interactive_example_matrix %s ok: five-object controls and reset across %zu frames\n",
               profile.name, machine.frame_count());
   return 0;
}
