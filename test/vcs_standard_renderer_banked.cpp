//! @file vcs_standard_renderer_banked.cpp
//! @brief Verify banked standard-renderer switching, timing, and visible raster identity.

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
constexpr uint64_t kCyclesPerScanline = 76;
constexpr uint64_t kExpectedFrameCycles = 20140;
constexpr uint16_t kVsync = 0x0000;
constexpr uint16_t kVblank = 0x0001;
constexpr uint16_t kWsync = 0x0002;
constexpr uint16_t kIntim = 0x0284;
constexpr uint16_t kTim1t = 0x0294;
constexpr uint16_t kTim8t = 0x0295;
constexpr uint16_t kTim64t = 0x0296;
constexpr uint16_t kT1024t = 0x0297;
constexpr int kFramesToRun = 8;
constexpr int kFirstDigestFrame = 2;
constexpr int kLastDigestFrame = 5;

struct WriteEvent {
   uint16_t address;
   uint8_t value;
};

std::vector<uint8_t> rom;
std::array<uint8_t, 65536> memory_image{};
std::array<uint8_t, 128> superchip{};
std::vector<WriteEvent> writes;
uint64_t virtual_cycles = 0;
uint64_t cpu_cycles = 0;
uint64_t frame_start = 0;
std::vector<uint64_t> frame_periods;
int frame = -1;
bool vsync_asserted = false;
bool vblank_asserted = false;
bool visible_started = false;
bool capture_frame = false;
bool capture_finished = false;
uint64_t raster_hash = 1469598103934665603ULL;
size_t raster_events = 0;
size_t hotspot_events = 0;
size_t destination_switches = 0;
size_t source_restores = 0;
bool timer_active = false;
uint64_t timer_start = 0;
uint16_t timer_divisor = 1;
uint8_t timer_loaded = 0;

int bank_count = 1;
uint16_t first_hotspot = 0;
int selected_file_bank = 0;
bool has_superchip = false;
uint16_t hook_count_address = 0;
uint16_t hook_epoch_address = 0;
uint16_t hook_failure_address = 0;
uint16_t ball_x_address = 0;
uint16_t score_address = 0;

[[noreturn]] void fail(const char *message) {
   std::fprintf(stderr, "vcs_standard_renderer_banked: %s\n", message);
   std::exit(1);
}

uint16_t canonical(uint16_t address) {
   return static_cast<uint16_t>(address & 0x1FFFu);
}

bool bank_for_hotspot(uint16_t address, int &file_bank) {
   if (bank_count <= 1) return false;
   const uint16_t a = canonical(address);
   if (a < first_hotspot || a >= static_cast<uint16_t>(first_hotspot + bank_count))
      return false;
   file_bank = static_cast<int>(a - first_hotspot);
   return true;
}

uint8_t timer_value() {
   if (!timer_active) return memory_image[kIntim];
   const uint64_t ticks = (virtual_cycles - timer_start) / timer_divisor;
   if (ticks <= timer_loaded) return static_cast<uint8_t>(timer_loaded - ticks);
   return static_cast<uint8_t>(255 - ((ticks - timer_loaded - 1) & 255));
}

uint8_t read_mapped(uint16_t address) {
   const uint16_t a = canonical(address);
   if (has_superchip && a >= 0x1080 && a <= 0x10FF)
      return superchip[static_cast<size_t>(a - 0x1080)];
   if (a >= 0x1000) {
      const size_t offset = static_cast<size_t>(selected_file_bank) * 4096u +
                            static_cast<size_t>(a - 0x1000);
      if (offset >= rom.size()) fail("ROM read fell outside cartridge image");
      return rom[offset];
   }
   if (a == kIntim) return timer_value();
   return memory_image[a];
}

uint8_t read_bus(uint16_t address) {
   int file_bank = 0;
   if (bank_for_hotspot(address, file_bank)) {
      selected_file_bank = file_bank;
      if (frame >= 0) {
         ++hotspot_events;
         if (!vblank_asserted) fail("selector read occurred while VBLANK was clear");
      }
   }
   return read_mapped(address);
}

void write_bus(uint16_t address, uint8_t value) {
   writes.push_back({address, value});
}

void clock_cycle(mos6502 *) {}

void hash_byte(uint8_t value) {
   raster_hash ^= value;
   raster_hash *= 1099511628211ULL;
}

void hash_visible_write(uint16_t address, uint8_t value) {
   if (!capture_frame || capture_finished || address > 0x002C) return;
   const uint64_t relative = virtual_cycles - frame_start;
   for (int shift = 0; shift < 8; ++shift)
      hash_byte(static_cast<uint8_t>((relative >> (shift * 8)) & 0xFF));
   const bool data_ignored = address == 0x0002 || address == 0x0003 ||
      (address >= 0x0010 && address <= 0x0014) ||
      (address >= 0x002A && address <= 0x002C);
   const uint8_t visible_value = data_ignored ? 0 : value;
   hash_byte(static_cast<uint8_t>(address & 0xFF));
   hash_byte(visible_value);
   ++raster_events;
}

uint8_t inspect_address(uint16_t address) {
   const uint16_t a = canonical(address);
   if (has_superchip && a >= 0x1080 && a <= 0x10FF)
      return superchip[static_cast<size_t>(a - 0x1080)];
   return memory_image[a];
}

void verify_frame_boundary() {
   const int startup_file_bank = bank_count - 1;
   if (selected_file_bank != startup_file_bank)
      fail("VSYNC began before the trampoline restored the startup bank");

   if (frame >= 1) {
      const uint8_t count = inspect_address(hook_count_address);
      if (count != static_cast<uint8_t>(frame)) {
         std::fprintf(stderr,
            "vcs_standard_renderer_banked: frame %d hook count is %u; expected %d\n",
            frame, count, frame);
         std::exit(1);
      }
      if (inspect_address(hook_epoch_address) != 1)
         fail("banked overscan work did not publish the next-frame epoch");
      if (inspect_address(hook_failure_address) != 0)
         fail("banked overscan work reported a state failure");
      const std::array<uint8_t, 5> expected_x{{24, 132, 54, 112, 104}};
      for (size_t i = 0; i < expected_x.size(); ++i) {
         const uint16_t base = static_cast<uint16_t>(ball_x_address - 4);
         if (inspect_address(static_cast<uint16_t>(base + i)) != expected_x[i]) {
            std::fprintf(stderr, "vcs_standard_renderer_banked: frame %d object %zu X is %u expected %u\n",
               frame, i, inspect_address(static_cast<uint16_t>(base + i)), expected_x[i]);
            std::exit(1);
         }
      }
      if (inspect_address(score_address) != 0x21 ||
          inspect_address(static_cast<uint16_t>(score_address + 1)) != 0x43 ||
          inspect_address(static_cast<uint16_t>(score_address + 2)) != 0x65)
         fail("banked overscan work did not update the next-frame BCD score");
   }
}

void apply_write(uint16_t address, uint8_t value) {
   const uint16_t a = canonical(address);
   int file_bank = 0;
   if (bank_for_hotspot(address, file_bank)) {
      selected_file_bank = file_bank;
      if (frame >= 0) {
         if (!vblank_asserted)
            fail("selector write occurred while VBLANK was clear");
         ++hotspot_events;
         if (file_bank == bank_count - 2) ++destination_switches;
         if (file_bank == bank_count - 1) ++source_restores;
      }
      return;
   }

   if (has_superchip && a >= 0x1000 && a <= 0x107F) {
      superchip[static_cast<size_t>(a - 0x1000)] = value;
      return;
   }

   if (a < 0x1000) memory_image[a] = value;
   hash_visible_write(a, value);

   if (a == kWsync) {
      const uint64_t within = virtual_cycles % kCyclesPerScanline;
      virtual_cycles += within ? kCyclesPerScanline - within : kCyclesPerScanline;
   }
   else if (a == kVsync) {
      const bool next = (value & 2) != 0;
      if (next && !vsync_asserted) {
         if (frame >= 0) frame_periods.push_back(virtual_cycles - frame_start);
         ++frame;
         frame_start = virtual_cycles;
         capture_frame = frame >= kFirstDigestFrame && frame <= kLastDigestFrame;
         capture_finished = false;
         visible_started = false;
         verify_frame_boundary();
      }
      vsync_asserted = next;
   }
   else if (a == kVblank) {
      const bool next = (value & 2) != 0;
      if (!next) visible_started = true;
      if (next && visible_started) capture_finished = true;
      vblank_asserted = next;
   }
   else if (a >= kTim1t && a <= kT1024t) {
      timer_active = true;
      timer_start = virtual_cycles;
      timer_loaded = value;
      timer_divisor = a == kTim1t ? 1 : a == kTim8t ? 8 : a == kTim64t ? 64 : 1024;
   }
}

void apply_writes() {
   for (const WriteEvent &event : writes) apply_write(event.address, event.value);
   writes.clear();
}

uint16_t parse_u16(const char *text) {
   char *end = nullptr;
   const unsigned long value = std::strtoul(text, &end, 0);
   if (!text[0] || !end || *end || value > 0xFFFF) fail("bad address argument");
   return static_cast<uint16_t>(value);
}

void select_mapper(const std::string &mapper) {
   if (mapper == "4K") {
      bank_count = 1;
      first_hotspot = 0;
      has_superchip = false;
   }
   else if (mapper == "F8" || mapper == "F8SC") {
      bank_count = 2;
      first_hotspot = 0x1FF8;
      has_superchip = mapper == "F8SC";
   }
   else if (mapper == "F6") {
      bank_count = 4;
      first_hotspot = 0x1FF6;
      has_superchip = false;
   }
   else if (mapper == "F4") {
      bank_count = 8;
      first_hotspot = 0x1FF4;
      has_superchip = false;
   }
   else fail("unknown mapper argument");
   selected_file_bank = bank_count - 1;
}
} // namespace

int main(int argc, char **argv) {
   if (argc != 9) {
      std::fprintf(stderr,
         "usage: %s ROM MAPPER hook_count hook_epoch hook_failure ball_x score\n",
         argv[0]);
      return 2;
   }
   select_mapper(argv[2]);
   hook_count_address = parse_u16(argv[3]);
   hook_epoch_address = parse_u16(argv[4]);
   hook_failure_address = parse_u16(argv[5]);
   ball_x_address = parse_u16(argv[6]);
   score_address = parse_u16(argv[7]);
   const uint16_t signature_address = parse_u16(argv[8]);

   std::ifstream input(argv[1], std::ios::binary);
   if (!input) fail("could not open ROM");
   rom.assign(std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>());
   if (rom.size() != static_cast<size_t>(bank_count) * 4096u)
      fail("ROM size does not match mapper bank count");

   memory_image.fill(0);
   superchip.fill(0xA7);
   mos6502 cpu(read_bus, write_bus, clock_cycle);
   cpu.Reset();

   constexpr uint64_t kInstructionLimit = 20000000;
   for (uint64_t instructions = 0;
        instructions < kInstructionLimit && frame < kFramesToRun;
        ++instructions) {
      writes.clear();
      const uint64_t before = cpu_cycles;
      cpu.Run(1, cpu_cycles, mos6502::INST_COUNT);
      virtual_cycles += cpu_cycles - before;
      apply_writes();
   }
   if (frame < kFramesToRun) fail("instruction limit reached before frame checks completed");

   if (frame_periods.size() < static_cast<size_t>(kFramesToRun))
      fail("missing frame period samples");
   for (size_t i = 1; i < frame_periods.size(); ++i) {
      if (frame_periods[i] != kExpectedFrameCycles) {
         std::fprintf(stderr,
            "vcs_standard_renderer_banked: frame period %zu is %llu; expected %llu\n",
            i, static_cast<unsigned long long>(frame_periods[i]),
            static_cast<unsigned long long>(kExpectedFrameCycles));
         return 1;
      }
   }

   if (inspect_address(signature_address) != 0x5A)
      fail("game-state signature was not preserved");
   if (raster_events == 0) fail("visible raster digest is empty");

   const size_t expected_switches = bank_count == 1 ? 0 : static_cast<size_t>(frame);
   if (destination_switches != expected_switches || source_restores != expected_switches) {
      std::fprintf(stderr,
         "vcs_standard_renderer_banked: switches destination=%zu restore=%zu expected=%zu\n",
         destination_switches, source_restores, expected_switches);
      return 1;
   }
   if (hotspot_events != expected_switches * 2)
      fail("unexpected number of mapper hotspot accesses");

   std::printf(
      "mapper=%s frames=%d period=%llu raster=%016llx events=%zu switches=%zu hook=%u\n",
      argv[2], frame,
      static_cast<unsigned long long>(kExpectedFrameCycles),
      static_cast<unsigned long long>(raster_hash), raster_events,
      destination_switches, inspect_address(hook_count_address));
   return 0;
}
