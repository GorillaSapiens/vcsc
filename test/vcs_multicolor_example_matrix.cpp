//! @file vcs_multicolor_example_matrix.cpp
//! @brief Exercise the interactive public renderer examples through emulated console inputs.

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
   std::fprintf(stderr, "vcs_multicolor_example_matrix: %s\n", message.c_str());
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
   uint64_t raw_lines;
   uint8_t p0_y;
   uint8_t max_y;
   bool has_score;
   unsigned initial_score;
};

Profile parse_profile(const std::string &name) {
   if (name == "legacy") return {"legacy", 264, 78, 87, true, 123456};
   if (name == "192") return {"192", 262, 70, 95, false, 0};
   if (name == "above") return {"above", 262, 70, 87, true, 123456};
   if (name == "below") return {"below", 262, 70, 87, true, 123456};
   fail("bad profile");
}

class Machine {
public:
   Machine(const char *rom_path, const Profile &profile,
           uint16_t object_x, std::array<uint16_t,3> y,
           uint16_t selected, uint16_t select_ready,
           uint16_t score, uint16_t score_digit, uint16_t score_state,
           uint16_t score_color)
      : profile_(profile), object_x_(object_x), y_(y), selected_(selected),
        select_ready_(select_ready), score_(score), score_digit_(score_digit),
        score_state_(score_state), score_color_(score_color),
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

      // P0: both axes and both directions, one unit per frame.
      advance(kLeftLeft, kIdle);
      require(memory_[object_x_] == 43, "P0 did not move left by one pixel");
      advance(kLeftRight, kIdle);
      require(memory_[object_x_] == 44, "P0 did not move right by one pixel");
      advance(kLeftUp, kIdle);
      require(memory_[y_[0]] == profile_.p0_y - 1, "P0 did not move up by one scanline");
      advance(kLeftDown, kIdle);
      require(memory_[y_[0]] == profile_.p0_y, "P0 did not move down by one scanline");

      // SELECT must advance exactly once per press, not once per held frame.
      advance(kIdle, kSelect);
      require(memory_[selected_] == 1, "SELECT did not choose P1");
      advance(kIdle, kSelect);
      require(memory_[selected_] == 1, "held SELECT repeated");
      advance(kIdle, kIdle);
      require(memory_[select_ready_] == 1, "SELECT release did not re-arm");

      advance(kLeftLeft, kIdle);
      require(memory_[object_x_ + 1] == 107, "selected P1 did not move left");
      advance(kIdle, kSelect);
      require(memory_[selected_] == 2, "second SELECT press did not choose Ball");
      advance(kIdle, kIdle);
      advance(kLeftRight, kIdle);
      require(memory_[object_x_ + 4] == 79, "selected Ball did not move right");
      advance(kLeftDown, kIdle);
      require(memory_[y_[2]] == 46, "selected Ball did not move down");

      // Clamp the complete public coordinate range without burning hundreds of frames.
      memory_[object_x_ + 4] = 0;
      advance(kLeftLeft, kIdle);
      require(memory_[object_x_ + 4] == 0, "X underflow escaped 0");
      memory_[object_x_ + 4] = 159;
      advance(kLeftRight, kIdle);
      require(memory_[object_x_ + 4] == 159, "X overflow escaped 159");
      memory_[y_[2]] = 0;
      advance(kLeftUp, kIdle);
      require(memory_[y_[2]] == 0, "Y underflow escaped 0");
      memory_[y_[2]] = profile_.max_y;
      advance(kLeftDown, kIdle);
      require(memory_[y_[2]] == profile_.max_y, "Y overflow escaped renderer range");

      if (profile_.has_score) exercise_score();

      // RESET is an in-cartridge jump through the reset vector and must restore all state.
      memory_[object_x_] = 12;
      memory_[selected_] = 2;
      if (profile_.has_score) {
         memory_[score_] = 0x99;
         memory_[score_ + 1] = 0x99;
         memory_[score_ + 2] = 0x99;
         memory_[score_digit_] = 4;
         memory_[score_state_] = 0x32;
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
   std::array<uint16_t,3> y_;
   uint16_t selected_;
   uint16_t select_ready_;
   uint16_t score_;
   uint16_t score_digit_;
   uint16_t score_state_;
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

   static uint8_t read_bus_thunk(uint16_t address) { return active_->read_bus(address); }
   static void write_bus_thunk(uint16_t address, uint8_t value) { active_->write_bus(address, value); }
   static void clock_thunk(mos6502 *) {}

   void require(bool condition, const char *message) const {
      if (!condition) fail(std::string(profile_.name) + ": " + message);
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
         }
         else if (event.address == kVsync) {
            const bool next = (event.value & 2) != 0;
            if (next && !vsync_asserted_) vsync_cycles_.push_back(virtual_cycles_);
            vsync_asserted_ = next;
         }
         else if (event.address == kTim1t || event.address == kTim8t ||
                  event.address == kTim64t || event.address == kT1024t) {
            load_timer(event.address, event.value);
         }
      }
      writes_.clear();
   }

   void run_instruction() {
      static constexpr uint64_t kInstructionLimit = 200000000;
      static uint64_t instructions = 0;
      if (++instructions > kInstructionLimit) fail("instruction limit reached");
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
      require(memory_[score_digit_] == 0, "score did not start on ones digit");
      require(score_value() == profile_.initial_score, "score initial value changed");
      require(memory_[score_color_] == 0x0e, "score did not start at color $0e");

      // A direction is sampled only every tenth frame. The first sample records
      // it; only the second consecutive matching sample performs the action.
      memory_[score_state_] = 0x9f;
      advance_frames(kRightUp, kIdle, 19);
      require(score_value() == profile_.initial_score,
              "right joystick acted before two tenth-frame samples");
      advance(kRightUp, kIdle);
      require(score_value() == (profile_.initial_score + 1) % 1000000,
              "second stable up sample did not add ones weight");
      require(memory_[score_color_] == 0x0e,
              "vertical score change altered the score color");

      advance_frames(kRightUp, kIdle, 10);
      require(score_value() == (profile_.initial_score + 2) % 1000000,
              "held stable up did not repeat on the next tenth-frame sample");

      advance_frames(kRightDown, kIdle, 10);
      require(score_value() == (profile_.initial_score + 2) % 1000000,
              "changed direction acted on its first sample");
      advance_frames(kRightDown, kIdle, 10);
      require(score_value() == (profile_.initial_score + 1) % 1000000,
              "second stable down sample did not subtract ones weight");

      // Horizontal samples use the same filter and advance the hue by $10 each
      // time the selected digit actually changes. A held direction repeats at
      // the ten-frame sample cadence.
      set_score(profile_.initial_score);
      memory_[score_digit_] = 0;
      memory_[score_color_] = 0x0e;
      memory_[score_state_] = 0x9f;
      advance_frames(kRightLeft, kIdle, 19);
      require(memory_[score_digit_] == 0,
              "horizontal selection acted before its second sample");
      require(memory_[score_color_] == 0x0e,
              "score color changed before digit selection");
      advance(kRightLeft, kIdle);
      require(memory_[score_digit_] == 1,
              "second stable left sample did not select tens digit");
      require(memory_[score_color_] == 0x1e,
              "first digit change did not add $10 to score color");

      advance_frames(kRightLeft, kIdle, 10);
      require(memory_[score_digit_] == 2,
              "held left did not repeat at the tenth-frame sample");
      require(memory_[score_color_] == 0x2e,
              "repeated digit change did not advance score color");

      advance_frames(kRightRight, kIdle, 10);
      require(memory_[score_digit_] == 2,
              "changed horizontal direction acted on its first sample");
      require(memory_[score_color_] == 0x2e,
              "score color changed on an unstable horizontal sample");
      advance_frames(kRightRight, kIdle, 10);
      require(memory_[score_digit_] == 1,
              "second stable right sample did not select tens digit");
      require(memory_[score_color_] == 0x3e,
              "rightward digit change did not advance score color");

      // The selected tens digit still controls a decimal weight of ten.
      set_score(profile_.initial_score);
      memory_[score_state_] = 0x9f;
      advance_frames(kRightUp, kIdle, 20);
      require(score_value() == (profile_.initial_score + 10) % 1000000,
              "selected tens digit did not add 10 after filtering");
      require(memory_[score_color_] == 0x3e,
              "vertical tens change altered score color");
   }

   void require_initial(const char *which) const {
      const std::string prefix = std::string(which) + " ";
      require(memory_[object_x_] == 44, (prefix + "P0 X is not 44").c_str());
      require(memory_[object_x_ + 1] == 108, (prefix + "P1 X is not 108").c_str());
      require(memory_[object_x_ + 4] == 78, (prefix + "Ball X is not 78").c_str());
      require(memory_[y_[0]] == profile_.p0_y, (prefix + "P0 Y changed").c_str());
      require(memory_[y_[1]] == 42, (prefix + "P1 Y changed").c_str());
      require(memory_[y_[2]] == 45, (prefix + "Ball Y changed").c_str());
      require(memory_[selected_] == 0, (prefix + "selected object is not P0").c_str());
      require(memory_[select_ready_] == 1, (prefix + "SELECT latch is not armed").c_str());
      if (profile_.has_score) {
         require(score_value() == profile_.initial_score, (prefix + "score changed").c_str());
         require(memory_[score_digit_] == 0, (prefix + "selected score digit is not ones").c_str());
         require((memory_[score_state_] & 0x0f) == 0x0f,
                 (prefix + "right joystick history is not neutral").c_str());
         require(memory_[score_color_] == 0x0e, (prefix + "score color is not $0e").c_str());
      }
   }

   void validate_frame_spacing() const {
      require(!timer_overrun_, "frame timer overran");
      const uint64_t expected = profile_.raw_lines * kCyclesPerLine;
      for (size_t i = 4; i < vsync_cycles_.size(); ++i) {
         const uint64_t actual = vsync_cycles_[i] - vsync_cycles_[i - 1];
         if (actual != expected) {
            char detail[160];
            std::snprintf(detail, sizeof(detail),
               "frame %zu has %llu cycles (%llu lines), expected %llu cycles (%llu lines)",
               i, static_cast<unsigned long long>(actual),
               static_cast<unsigned long long>(actual / kCyclesPerLine),
               static_cast<unsigned long long>(expected),
               static_cast<unsigned long long>(profile_.raw_lines));
            fail(std::string(profile_.name) + ": " + detail);
         }
      }
   }
};
Machine *Machine::active_ = nullptr;
} // namespace

int main(int argc, char **argv) {
   if (argc != 13) {
      std::fprintf(stderr,
         "usage: %s ROM legacy|192|above|below object_x p0_y p1_y ball_y "
         "selected select_ready score|none score_digit|none score_state|none "
         "score_color|none\n", argv[0]);
      return 2;
   }
   const Profile profile = parse_profile(argv[2]);
   const uint16_t score = profile.has_score ? parse_address(argv[9]) : 0;
   const uint16_t score_digit = profile.has_score ? parse_address(argv[10]) : 0;
   const uint16_t score_state = profile.has_score ? parse_address(argv[11]) : 0;
   const uint16_t score_color = profile.has_score ? parse_address(argv[12]) : 0;
   if (!profile.has_score &&
       (std::strcmp(argv[9], "none") || std::strcmp(argv[10], "none") ||
        std::strcmp(argv[11], "none") || std::strcmp(argv[12], "none")))
      fail("scoreless profile requires none score arguments");

   Machine machine(argv[1], profile, parse_address(argv[3]),
                   {{parse_address(argv[4]), parse_address(argv[5]), parse_address(argv[6])}},
                   parse_address(argv[7]), parse_address(argv[8]),
                   score, score_digit, score_state, score_color);
   machine.run();
   std::printf("vcs_multicolor_example_matrix %s ok: interactive controls and reset across %zu frames\n",
               profile.name, machine.frame_count());
   return 0;
}
