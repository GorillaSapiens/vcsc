//! @file vcs_standard_pairwise.cpp
//! @brief Exhaust every pair of standard-renderer horizontal object positions.

#include <array>
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
constexpr uint16_t kWsync = 0x0002;
constexpr uint16_t kResp0 = 0x0010;
constexpr uint16_t kResbl = 0x0014;
constexpr uint16_t kHmp0 = 0x0020;
constexpr uint16_t kHmbl = 0x0024;
constexpr uint16_t kHmove = 0x002A;
constexpr size_t kObjectCount = 5;
constexpr int kCoordinateCount = 160;
constexpr int kPairCount = 10;
constexpr int kExpectedCases = kPairCount * kCoordinateCount * kCoordinateCount;

struct WriteEvent {
   uint16_t address;
   uint8_t value;
};

struct PositionResult {
   std::array<int, kObjectCount> resp_cycle;
   std::array<int, kObjectCount> resp_count;
   std::array<int, kObjectCount> hmp_value;
   std::array<int, kObjectCount> hmp_count;
   std::array<int, kObjectCount> remainder_count;
   int hmove_count;

   PositionResult() : hmove_count(0) {
      resp_cycle.fill(-1);
      resp_count.fill(0);
      hmp_value.fill(-1);
      hmp_count.fill(0);
      remainder_count.fill(0);
   }
};

uint8_t memory_image[65536];
uint64_t cpu_cycles = 0;
uint64_t virtual_cycles = 0;
std::vector<WriteEvent> writes;
uint8_t object_x_zp = 0;
uint8_t pointer_workspace_zp = 0;
PositionResult *current_result = nullptr;

[[noreturn]] void fail(const char *message) {
   std::fprintf(stderr, "vcs_standard_pairwise: %s\n", message);
   std::exit(1);
}

uint8_t read_bus(uint16_t address) {
   return memory_image[address];
}

void write_bus(uint16_t address, uint8_t value) {
   if (address < kRomBase) memory_image[address] = value;
   writes.push_back({address, value});
}

void clock_cycle(mos6502 *) {}

uint16_t parse_address(const char *text, const char *what) {
   char *end = nullptr;
   const unsigned long value = std::strtoul(text, &end, 0);
   if (!text[0] || !end || *end || value > 0xFFFF) {
      std::fprintf(stderr, "vcs_standard_pairwise: bad %s address\n", what);
      std::exit(1);
   }
   return static_cast<uint16_t>(value);
}

uint8_t expected_remainder(uint8_t x) {
   int remainder = x;
   do {
      remainder -= 15;
   } while (remainder >= 0);
   return static_cast<uint8_t>(remainder);
}

uint8_t expected_hmp(uint8_t x) {
   static constexpr std::array<uint8_t, 16> table{{
      0x80, 0x70, 0x60, 0x50, 0x40, 0x30, 0x20, 0x10,
      0x00, 0xF0, 0xE0, 0xD0, 0xC0, 0xB0, 0xA0, 0x90
   }};
   const int index = 16 + static_cast<int8_t>(expected_remainder(x));
   if (index < 0 || index >= static_cast<int>(table.size()))
      fail("horizontal remainder fell outside repostable");
   return table[static_cast<size_t>(index)];
}

int expected_resp_cycle(uint8_t x) {
   return 18 + 5 * (static_cast<int>(x) / 15 + 1);
}

uint16_t find_horizontal_position_start() {
   const std::array<uint8_t, 20> pattern{{
      0xA2, 0x04,             // LDX #4
      0x24, 0x00,             // legal three-cycle BIT delay
      0xB5, object_x_zp,      // LDA vcs_standard_object_x,X
      0x38,                   // SEC
      0xE9, 0x0F,             // SBC #15
      0xB0, 0xFC,             // BCS divide loop
      0x95, static_cast<uint8_t>(pointer_workspace_zp + 6),
      0x95, 0x10,             // STA RESP0,X
      0x85, 0x02,             // STA WSYNC
      0xCA,                   // DEX
      0x10, 0xF0              // BPL object loop
   }};

   int found = 0;
   uint16_t address = 0;
   for (size_t offset = 0; offset + pattern.size() <= kRomSize; ++offset) {
      if (std::memcmp(memory_image + kRomBase + offset,
                      pattern.data(), pattern.size()) == 0) {
         ++found;
         address = static_cast<uint16_t>(kRomBase + offset);
      }
   }
   if (found != 1) {
      std::fprintf(stderr,
         "vcs_standard_pairwise: horizontal-position signature matched %d times\n",
         found);
      std::exit(1);
   }
   return address;
}

void apply_writes() {
   if (!current_result) fail("missing result capture");
   for (const WriteEvent &event : writes) {
      if (event.address == kWsync) {
         const uint64_t within = virtual_cycles % kCyclesPerScanline;
         virtual_cycles += within ? kCyclesPerScanline - within : kCyclesPerScanline;
      }
      else if (event.address >= kResp0 && event.address <= kResbl) {
         const size_t object = static_cast<size_t>(event.address - kResp0);
         ++current_result->resp_count[object];
         if (current_result->resp_cycle[object] < 0)
            current_result->resp_cycle[object] =
               static_cast<int>(virtual_cycles % kCyclesPerScanline);
      }
      else if (event.address >= kHmp0 && event.address <= kHmbl) {
         const size_t object = static_cast<size_t>(event.address - kHmp0);
         ++current_result->hmp_count[object];
         if (current_result->hmp_value[object] < 0)
            current_result->hmp_value[object] = event.value;
      }
      else if (event.address == kHmove) {
         ++current_result->hmove_count;
      }
      else if (event.address >= static_cast<uint16_t>(pointer_workspace_zp + 6) &&
               event.address <= static_cast<uint16_t>(pointer_workspace_zp + 10)) {
         const size_t object = static_cast<size_t>(
            event.address - static_cast<uint16_t>(pointer_workspace_zp + 6));
         ++current_result->remainder_count[object];
      }
   }
   writes.clear();
}

void report_case(size_t first,
                 size_t second,
                 uint8_t first_x,
                 uint8_t second_x,
                 size_t object,
                 const char *message) {
   static constexpr std::array<const char *, kObjectCount> names{{
      "P0", "P1", "M0", "M1", "BL"
   }};
   std::fprintf(stderr,
      "vcs_standard_pairwise: pair %s/%s X=%u/%u object %s: %s\n",
      names[first], names[second], first_x, second_x, names[object], message);
   std::exit(1);
}

void run_case(mos6502 &cpu,
              uint16_t position_start,
              size_t first,
              size_t second,
              uint8_t first_x,
              uint8_t second_x) {
   static constexpr std::array<uint8_t, kObjectCount> sentinels{{
      7, 41, 83, 127, 151
   }};
   std::array<uint8_t, kObjectCount> expected = sentinels;
   expected[first] = first_x;
   expected[second] = second_x;

   for (size_t object = 0; object < kObjectCount; ++object) {
      memory_image[static_cast<uint8_t>(object_x_zp + object)] = expected[object];
      memory_image[static_cast<uint8_t>(pointer_workspace_zp + 6 + object)] = 0xCC;
   }

   PositionResult result;
   current_result = &result;
   virtual_cycles = 0;
   writes.clear();
   cpu.SetPC(position_start);
   cpu.SetA(0xA5);
   cpu.SetX(0x5A);
   cpu.SetY(0xC3);
   cpu.SetS(0xFD);
   cpu.SetP(0x24); // IRQ disabled, decimal mode clear.

   constexpr int kInstructionLimit = 256;
   int instructions = 0;
   while (result.hmove_count == 0 && instructions < kInstructionLimit) {
      const uint64_t before = cpu_cycles;
      cpu.Run(1, cpu_cycles, mos6502::INST_COUNT);
      virtual_cycles += cpu_cycles - before;
      apply_writes();
      ++instructions;
   }
   current_result = nullptr;
   if (result.hmove_count != 1)
      report_case(first, second, first_x, second_x, 0,
                  "horizontal routine did not issue exactly one HMOVE");

   for (size_t object = 0; object < kObjectCount; ++object) {
      const uint8_t x = expected[object];
      if (memory_image[static_cast<uint8_t>(object_x_zp + object)] != x)
         report_case(first, second, first_x, second_x, object,
                     "public X value was modified");
      if (result.resp_count[object] != 1)
         report_case(first, second, first_x, second_x, object,
                     "RESP strobe count is not one");
      if (result.hmp_count[object] != 1)
         report_case(first, second, first_x, second_x, object,
                     "HMxx write count is not one");
      if (result.remainder_count[object] != 1)
         report_case(first, second, first_x, second_x, object,
                     "coarse remainder write count is not one");
      if (result.resp_cycle[object] != expected_resp_cycle(x))
         report_case(first, second, first_x, second_x, object,
                     "RESP cycle does not encode requested X");
      if (result.hmp_value[object] != expected_hmp(x))
         report_case(first, second, first_x, second_x, object,
                     "HMxx value does not encode requested X");
      if (memory_image[static_cast<uint8_t>(pointer_workspace_zp + 6 + object)] !=
          expected_remainder(x))
         report_case(first, second, first_x, second_x, object,
                     "stored coarse remainder is wrong");
   }
}
} // namespace

int main(int argc, char **argv) {
   if (argc != 4) {
      std::fprintf(stderr,
         "usage: %s ROM object_x pointer_workspace\n", argv[0]);
      return 2;
   }
   const uint16_t object_x = parse_address(argv[2], "object X");
   const uint16_t workspace = parse_address(argv[3], "pointer workspace");
   if (object_x > 0xFB || workspace > 0xF5)
      fail("test symbols do not fit their required zero-page spans");
   object_x_zp = static_cast<uint8_t>(object_x);
   pointer_workspace_zp = static_cast<uint8_t>(workspace);

   std::memset(memory_image, 0, sizeof(memory_image));
   std::ifstream rom(argv[1], std::ios::binary);
   if (!rom) fail("could not open ROM");
   rom.read(reinterpret_cast<char *>(memory_image + kRomBase), kRomSize);
   if (rom.gcount() != static_cast<std::streamsize>(kRomSize))
      fail("ROM is not exactly 4096 bytes");

   const uint16_t position_start = find_horizontal_position_start();
   mos6502 cpu(read_bus, write_bus, clock_cycle);

   int cases = 0;
   for (size_t first = 0; first < kObjectCount; ++first) {
      for (size_t second = first + 1; second < kObjectCount; ++second) {
         for (int first_x = 0; first_x < kCoordinateCount; ++first_x) {
            for (int second_x = 0; second_x < kCoordinateCount; ++second_x) {
               run_case(cpu, position_start, first, second,
                        static_cast<uint8_t>(first_x),
                        static_cast<uint8_t>(second_x));
               ++cases;
            }
         }
      }
   }
   if (cases != kExpectedCases) fail("internal case count is wrong");

   std::printf(
      "vcs_standard_pairwise ok: 10 pairs x 160 x 160 = 256000 cases\n");
   return 0;
}
