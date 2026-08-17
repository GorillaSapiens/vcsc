#include "dynamic_video_probe.h"

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstring>

#include "../simulator/mos6502/mos6502.h"

namespace {
constexpr uint64_t kCyclesPerLine = 76;
constexpr unsigned kMaxInstructions = 250000;
constexpr unsigned kMaxFrameSamples = 12;

/* Keep synchronized with mapper_t; the C API uses integers to avoid exposing
 * the disassembler's private enum through a C++ header. */
constexpr int kMap2K = 1;
constexpr int kMap4K = 2;
constexpr int kMapF8 = 3;
constexpr int kMapF6 = 4;
constexpr int kMapF4 = 5;
constexpr int kMapFA = 6;
constexpr int kMapDPC = 7;
constexpr int kMapJANE = 10;
constexpr int kMap0840 = 11;
constexpr int kMapUA = 12;
constexpr int kMapUASW = 13;

struct PendingWrite {
   uint16_t address;
   uint8_t value;
};

class ProbeMachine {
public:
   ProbeMachine(const uint8_t *rom, size_t rom_size, int mapper,
                size_t bank_count, size_t reset_bank, bool superchip)
      : rom_(rom), rom_size_(rom_size), mapper_(mapper),
        bank_count_(bank_count), bank_(reset_bank), superchip_(superchip),
        cpu_(read_thunk, write_thunk, nullptr)
   {
      active_ = this;
      std::memset(ram_, 0, sizeof(ram_));
      std::memset(cart_ram_, 0, sizeof(cart_ram_));
      cpu_.IRQ(true);
      cpu_.NMI(true);
      cpu_.Reset();
   }

   int run(vcsc_video_probe_result_t *out)
   {
      unsigned instructions;
      for (instructions = 0; instructions < kMaxInstructions; ++instructions) {
         pending_count_ = 0;
         const uint64_t before = cpu_cycles_;
         cpu_.Run(1, cpu_cycles_, mos6502::INST_COUNT);
         const uint64_t delta = cpu_cycles_ - before;
         if (delta == 0) {
            halted_ = true;
            break;
         }
         virtual_cycles_ += delta;
         apply_pending();
         if (sample_count_ >= 7 && stable_tail()) break;
      }
      if (instructions == kMaxInstructions) instruction_limit_ = true;
      fill_result(out);
      return out->frames != 0u;
   }

private:
   const uint8_t *rom_;
   size_t rom_size_;
   int mapper_;
   size_t bank_count_;
   size_t bank_;
   bool superchip_;
   uint8_t ram_[128];
   uint8_t cart_ram_[256];
   mos6502 cpu_;
   uint64_t cpu_cycles_ = 0;
   uint64_t virtual_cycles_ = 0;
   bool timer_active_ = false;
   uint64_t timer_start_ = 0;
   uint16_t timer_divisor_ = 1;
   uint8_t timer_loaded_ = 0;
   bool vsync_ = false;
   bool have_vsync_rise_ = false;
   uint64_t last_vsync_rise_ = 0;
   unsigned samples_[kMaxFrameSamples]{};
   unsigned sample_count_ = 0;
   PendingWrite pending_[8]{};
   unsigned pending_count_ = 0;
   bool halted_ = false;
   bool instruction_limit_ = false;

   static ProbeMachine *active_;
   static uint8_t read_thunk(uint16_t address) { return active_->read(address); }
   static void write_thunk(uint16_t address, uint8_t value) {
      active_->write(address, value);
   }

   static uint16_t bus_address(uint16_t address) {
      return static_cast<uint16_t>(address & 0x1fffu);
   }

   bool select_bank(uint16_t bus)
   {
      size_t next = bank_;
      bool hit = false;
      if ((mapper_ == kMapF8 || mapper_ == kMapDPC) &&
          bus >= 0x1ff8u && bus <= 0x1ff9u) {
         next = static_cast<size_t>(bus - 0x1ff8u); hit = true;
      }
      else if (mapper_ == kMapF6 && bus >= 0x1ff6u && bus <= 0x1ff9u) {
         next = static_cast<size_t>(bus - 0x1ff6u); hit = true;
      }
      else if (mapper_ == kMapF4 && bus >= 0x1ff4u && bus <= 0x1ffbu) {
         next = static_cast<size_t>(bus - 0x1ff4u); hit = true;
      }
      else if (mapper_ == kMapFA && bus >= 0x1ff8u && bus <= 0x1ffau) {
         next = static_cast<size_t>(bus - 0x1ff8u); hit = true;
      }
      else if (mapper_ == kMapJANE) {
         if (bus == 0x1ff0u) { next = 0u; hit = true; }
         else if (bus == 0x1ff1u) { next = 1u; hit = true; }
         else if (bus == 0x1ff8u) { next = 2u; hit = true; }
         else if (bus == 0x1ff9u) { next = 3u; hit = true; }
      }
      else if (mapper_ == kMap0840) {
         switch (bus & 0x1840u) {
         case 0x0800u: next = 0u; hit = true; break;
         case 0x0840u: next = 1u; hit = true; break;
         default: break;
         }
      }
      else if (mapper_ == kMapUA || mapper_ == kMapUASW) {
         switch (bus & 0x1260u) {
         case 0x0220u: next = mapper_ == kMapUASW ? 1u : 0u; hit = true; break;
         case 0x0240u: next = mapper_ == kMapUASW ? 0u : 1u; hit = true; break;
         default: break;
         }
      }
      if (hit && next < bank_count_) bank_ = next;
      return hit;
   }

   bool tia_selected(uint16_t bus) const {
      return (bus & 0x1080u) == 0u;
   }
   bool riot_ram_selected(uint16_t bus) const {
      return (bus & 0x1280u) == 0x0080u;
   }
   bool riot_io_selected(uint16_t bus) const {
      return (bus & 0x1280u) == 0x0280u;
   }

   uint8_t timer_value() const
   {
      if (!timer_active_) return 0;
      const uint64_t ticks = (virtual_cycles_ - timer_start_) / timer_divisor_;
      if (ticks <= timer_loaded_)
         return static_cast<uint8_t>(timer_loaded_ - ticks);
      return static_cast<uint8_t>(255u - ((ticks - timer_loaded_ - 1u) & 255u));
   }

   bool timer_underflowed() const
   {
      if (!timer_active_) return false;
      return (virtual_cycles_ - timer_start_) / timer_divisor_ > timer_loaded_;
   }

   uint8_t cart_read(uint16_t bus)
   {
      if (mapper_ == kMapDPC) return 0; /* DPC register semantics are not probed. */
      if (mapper_ == kMapFA) {
         if (bus >= 0x1100u && bus <= 0x11ffu)
            return cart_ram_[bus & 0xffu];
         if (bus >= 0x1000u && bus <= 0x10ffu) return 0;
      }
      if (superchip_) {
         if (bus >= 0x1080u && bus <= 0x10ffu)
            return cart_ram_[bus & 0x7fu];
         if (bus >= 0x1000u && bus <= 0x107fu) return 0;
      }
      select_bank(bus);
      size_t off;
      if (mapper_ == kMap2K)
         off = static_cast<size_t>(bus & 0x07ffu);
      else
         off = static_cast<size_t>(bus & 0x0fffu);
      size_t physical = bank_ * (mapper_ == kMap2K ? 2048u : 4096u) + off;
      return physical < rom_size_ ? rom_[physical] : 0xffu;
   }

   void cart_write(uint16_t bus, uint8_t value)
   {
      if (mapper_ == kMapFA && bus >= 0x1000u && bus <= 0x10ffu) {
         cart_ram_[bus & 0xffu] = value;
         return;
      }
      if (superchip_ && bus >= 0x1000u && bus <= 0x107fu) {
         cart_ram_[bus & 0x7fu] = value;
         return;
      }
      (void)select_bank(bus);
   }

   uint8_t read(uint16_t address)
   {
      const uint16_t bus = bus_address(address);
      if (bus & 0x1000u) return cart_read(bus);
      (void)select_bank(bus);
      if (tia_selected(bus)) {
         const uint8_t reg = static_cast<uint8_t>(bus & 0x3fu);
         if (reg >= 0x08u && reg <= 0x0du) return 0x80u;
         return 0;
      }
      if (riot_ram_selected(bus)) return ram_[bus & 0x7fu];
      if (riot_io_selected(bus)) {
         const uint16_t reg = static_cast<uint16_t>(0x0280u | (bus & 0x1fu));
         if (reg == 0x0280u || reg == 0x0282u) return 0xffu;
         if (reg == 0x0284u) return timer_value();
         if (reg == 0x0285u) return timer_underflowed() ? 0x80u : 0u;
         return 0;
      }
      return 0;
   }

   void queue_write(uint16_t bus, uint8_t value)
   {
      if (pending_count_ < sizeof(pending_) / sizeof(pending_[0]))
         pending_[pending_count_++] = { bus, value };
   }

   void write(uint16_t address, uint8_t value)
   {
      const uint16_t bus = bus_address(address);
      if (bus & 0x1000u) {
         cart_write(bus, value);
         return;
      }
      (void)select_bank(bus);
      if (tia_selected(bus)) {
         const uint16_t reg = static_cast<uint16_t>(bus & 0x3fu);
         if (reg == 0x00u || reg == 0x02u) queue_write(reg, value);
         return;
      }
      if (riot_ram_selected(bus)) {
         ram_[bus & 0x7fu] = value;
         return;
      }
      if (riot_io_selected(bus)) {
         const uint16_t reg = static_cast<uint16_t>(0x0280u | (bus & 0x1fu));
         if (reg >= 0x0294u && reg <= 0x0297u) queue_write(reg, value);
      }
   }

   void load_timer(uint16_t reg, uint8_t value)
   {
      timer_active_ = true;
      timer_start_ = virtual_cycles_;
      timer_loaded_ = value;
      timer_divisor_ = reg == 0x0294u ? 1u :
                       reg == 0x0295u ? 8u :
                       reg == 0x0296u ? 64u : 1024u;
   }

   void note_vsync(uint8_t value)
   {
      const bool next = (value & 0x02u) != 0;
      if (next && !vsync_) {
         if (have_vsync_rise_) {
            const uint64_t delta = virtual_cycles_ - last_vsync_rise_;
            const unsigned lines = static_cast<unsigned>((delta + kCyclesPerLine / 2u) /
                                                         kCyclesPerLine);
            if (lines >= 180u && lines <= 400u && sample_count_ < kMaxFrameSamples)
               samples_[sample_count_++] = lines;
         }
         last_vsync_rise_ = virtual_cycles_;
         have_vsync_rise_ = true;
      }
      vsync_ = next;
   }

   void apply_pending()
   {
      for (unsigned i = 0; i < pending_count_; ++i) {
         const uint16_t reg = pending_[i].address;
         const uint8_t value = pending_[i].value;
         if (reg == 0x02u) {
            const uint64_t within = virtual_cycles_ % kCyclesPerLine;
            virtual_cycles_ += within ? kCyclesPerLine - within : kCyclesPerLine;
         }
         else if (reg == 0x00u) note_vsync(value);
         else if (reg >= 0x0294u && reg <= 0x0297u) load_timer(reg, value);
      }
      pending_count_ = 0;
   }

   bool stable_tail() const
   {
      if (sample_count_ < 5u) return false;
      const unsigned first = sample_count_ - 5u;
      unsigned lo = samples_[first], hi = samples_[first];
      for (unsigned i = first + 1u; i < sample_count_; ++i) {
         lo = std::min(lo, samples_[i]);
         hi = std::max(hi, samples_[i]);
      }
      return hi - lo <= 1u;
   }

   void fill_result(vcsc_video_probe_result_t *out) const
   {
      std::memset(out, 0, sizeof(*out));
      out->frames = sample_count_;
      out->halted = halted_ ? 1 : 0;
      out->instruction_limit = instruction_limit_ ? 1 : 0;
      if (!sample_count_) return;
      unsigned lo = samples_[0], hi = samples_[0];
      uint64_t sum = 0;
      for (unsigned i = 0; i < sample_count_; ++i) {
         lo = std::min(lo, samples_[i]);
         hi = std::max(hi, samples_[i]);
         sum += samples_[i];
      }
      out->min_lines = lo;
      out->max_lines = hi;
      out->stable_lines = static_cast<unsigned>((sum + sample_count_ / 2u) / sample_count_);
      if (sample_count_ >= 4u && hi - lo <= 1u) out->stable = 1;
      else if (sample_count_ >= 6u) {
         unsigned tlo = samples_[sample_count_ - 4u];
         unsigned thi = tlo;
         uint64_t tsum = 0;
         for (unsigned i = sample_count_ - 4u; i < sample_count_; ++i) {
            tlo = std::min(tlo, samples_[i]);
            thi = std::max(thi, samples_[i]);
            tsum += samples_[i];
         }
         if (thi - tlo <= 1u) {
            out->stable = 1;
            out->min_lines = tlo;
            out->max_lines = thi;
            out->stable_lines = static_cast<unsigned>((tsum + 2u) / 4u);
         }
      }
   }
};

ProbeMachine *ProbeMachine::active_ = nullptr;
}

extern "C" int vcsc_dynamic_video_probe(const uint8_t *rom, size_t rom_size,
                                         int mapper, size_t bank_count,
                                         size_t reset_bank, int superchip,
                                         vcsc_video_probe_result_t *result)
{
   if (!rom || !result || bank_count == 0u || reset_bank >= bank_count) return 0;
   std::memset(result, 0, sizeof(*result));
   if (mapper == kMapDPC || mapper < kMap2K || mapper > kMapDPC) return 0;
   ProbeMachine machine(rom, rom_size, mapper, bank_count, reset_bank,
                        superchip != 0);
   return machine.run(result);
}
