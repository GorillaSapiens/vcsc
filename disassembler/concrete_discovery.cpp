#include "concrete_discovery.h"

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <vector>

#include "../simulator/mos6502/mos6502.h"

namespace {
constexpr unsigned kMaxInstructions = 250000;
constexpr unsigned kConvergenceInstructions = 16384;
constexpr uint64_t kCyclesPerLine = 76;
constexpr int kMap1K = VCSC_VIDEO_MAP_1K;
constexpr int kMap2K = VCSC_VIDEO_MAP_2K;
constexpr int kMap4K = VCSC_VIDEO_MAP_4K;
constexpr int kMapF8 = VCSC_VIDEO_MAP_F8;
constexpr int kMapF6 = VCSC_VIDEO_MAP_F6;
constexpr int kMapF4 = VCSC_VIDEO_MAP_F4;
constexpr int kMapFA = VCSC_VIDEO_MAP_FA;
constexpr int kMapDPC = VCSC_VIDEO_MAP_DPC;
constexpr int kMapWD = VCSC_VIDEO_MAP_WD;
constexpr int kMapWDSW = VCSC_VIDEO_MAP_WDSW;
constexpr int kMapFC = VCSC_VIDEO_MAP_FC;
constexpr int kMapE0 = VCSC_VIDEO_MAP_E0;
constexpr int kMapE7 = VCSC_VIDEO_MAP_E7;
constexpr int kMap3F = VCSC_VIDEO_MAP_3F;
constexpr int kMap3E = VCSC_VIDEO_MAP_3E;
constexpr int kMapCV = VCSC_VIDEO_MAP_CV;
constexpr int kMapJANE = VCSC_VIDEO_MAP_JANE;
constexpr int kMap0840 = VCSC_VIDEO_MAP_0840;
constexpr int kMapUA = VCSC_VIDEO_MAP_UA;
constexpr int kMapUASW = VCSC_VIDEO_MAP_UASW;
constexpr int kMap0FA0 = VCSC_VIDEO_MAP_0FA0;
constexpr int kMapFE = VCSC_VIDEO_MAP_FE;

constexpr uint16_t kThreeERamFlag = 0x8000u;
constexpr unsigned kThreeERamBanks = 32u;
constexpr size_t kCartRamBytes = 32768u;

static const uint8_t kWdBankOrg[8][4] = {
   { 0, 0, 1, 3 }, { 0, 1, 2, 3 }, { 4, 5, 6, 7 }, { 7, 4, 2, 3 },
   { 0, 0, 6, 7 }, { 0, 1, 7, 6 }, { 2, 3, 4, 5 }, { 6, 0, 5, 1 }
};

constexpr uint32_t kInputSWCHA = 1u << 0;
constexpr uint32_t kInputSWCHB = 1u << 1;
constexpr uint32_t kInputINPT0 = 1u << 2;

struct PendingWrite {
   uint16_t address;
   uint8_t value;
};

static unsigned instruction_length(uint8_t opcode)
{
   const char *mode = mos6502::GetAddr(opcode);
   if (!mode || std::strcmp(mode, "(null)") == 0) return 1u;
   if (std::strcmp(mode, "IMP") == 0 || std::strcmp(mode, "ACC") == 0)
      return 1u;
   if (std::strcmp(mode, "IMM") == 0 || std::strcmp(mode, "ZER") == 0 ||
       std::strcmp(mode, "ZEX") == 0 || std::strcmp(mode, "ZEY") == 0 ||
       std::strcmp(mode, "REL") == 0 || std::strcmp(mode, "INX") == 0 ||
       std::strcmp(mode, "INY") == 0)
      return 2u;
   return 3u;
}

class DiscoveryMachine {
public:
   DiscoveryMachine(const uint8_t *rom, size_t rom_size, int mapper,
                    size_t bank_count, size_t reset_bank, bool superchip,
                    uint8_t swcha, uint8_t swchb, const uint8_t inpt[6],
                    uint8_t *rom_exec_start, uint16_t *rom_exec_pc,
                    vcsc_concrete_result_t *result)
      : rom_(rom), rom_size_(rom_size), mapper_(mapper), bank_count_(bank_count),
        bank_(reset_bank), superchip_(superchip), rom_exec_start_(rom_exec_start),
        rom_exec_pc_(rom_exec_pc), result_(result), swcha_(swcha), swchb_(swchb),
        cpu_(read_thunk, write_thunk, nullptr)
   {
      active_ = this;
      std::memset(ram_, 0, sizeof(ram_));
      std::memset(cart_ram_, 0, sizeof(cart_ram_));
      std::fill(ram_source_, ram_source_ + VCSC_CONCRETE_RIOT_RAM_SIZE, VCSC_CONCRETE_NO_SOURCE);
      std::memset(result_, 0, sizeof(*result_));
      for (unsigned i = 0; i < VCSC_CONCRETE_RIOT_RAM_SIZE; ++i)
         result_->ram_source_offset[i] = VCSC_CONCRETE_NO_SOURCE;
      for (unsigned i = 0; i < VCSC_CONCRETE_RIOT_RAM_SIZE * VCSC_CONCRETE_MAX_INSN_BYTES; ++i)
         result_->ram_exec_source[i] = VCSC_CONCRETE_NO_SOURCE;
      std::memset(rom_exec_start_, 0, rom_size_);
      std::memset(rom_exec_pc_, 0, rom_size_ * sizeof(*rom_exec_pc_));
      std::memcpy(inpt_, inpt, sizeof(inpt_));
      cpu_.IRQ(true);
      cpu_.NMI(true);
      cpu_.Reset();
   }

   int run()
   {
      unsigned instructions;
      unsigned executed = 0;
      unsigned stale = 0;
      for (instructions = 0; instructions < kMaxInstructions; ++instructions) {
         const unsigned starts_before = result_->rom_instruction_starts +
                                        result_->ram_instruction_starts;
         const uint16_t pc = cpu_.GetPC();
         current_pc_ = pc;
         current_data_source_ = VCSC_CONCRETE_NO_SOURCE;
         current_data_value_ = 0;
         current_data_reads_ = 0;
         pending_count_ = 0;
         uint8_t opcode = peek_opcode(pc);
         current_opcode_ = opcode;
         current_len_ = instruction_length(opcode);
         const char *mnemonic = mos6502::GetCode(opcode);
         if (mnemonic && ((std::strcmp(mnemonic, "RTS") == 0 && jsr_depth_ == 0u) ||
                          (std::strcmp(mnemonic, "RTI") == 0 && interrupt_depth_ == 0u))) {
            result_->top_level_return = 1;
            break;
         }
         note_instruction(pc, opcode);

         const uint64_t before = cpu_cycles_;
         cpu_.Run(1, cpu_cycles_, mos6502::INST_COUNT);
         const uint64_t delta = cpu_cycles_ - before;
         if (delta == 0) {
            result_->halted = 1;
            break;
         }
         ++executed;
         virtual_cycles_ += delta;
         apply_pending();
         update_register_provenance(opcode);
         if (mnemonic) {
            if (std::strcmp(mnemonic, "JSR") == 0) ++jsr_depth_;
            else if (std::strcmp(mnemonic, "RTS") == 0 && jsr_depth_ != 0u) --jsr_depth_;
            else if (std::strcmp(mnemonic, "BRK") == 0) ++interrupt_depth_;
            else if (std::strcmp(mnemonic, "RTI") == 0 && interrupt_depth_ != 0u) --interrupt_depth_;
         }
         if (result_->rom_instruction_starts + result_->ram_instruction_starts == starts_before)
            ++stale;
         else
            stale = 0;
         if (stale >= kConvergenceInstructions) {
            result_->converged = 1;
            break;
         }
      }
      result_->instructions = executed;
      if (instructions == kMaxInstructions) result_->instruction_limit = 1;
      result_->final_pc = cpu_.GetPC();
      result_->final_a = cpu_.GetA();
      result_->final_x = cpu_.GetX();
      result_->final_y = cpu_.GetY();
      result_->final_sp = cpu_.GetS();
      result_->final_p = cpu_.GetP();
      std::memcpy(result_->ram, ram_, sizeof(ram_));
      for (unsigned i = 0; i < VCSC_CONCRETE_RIOT_RAM_SIZE; ++i)
         result_->ram_source_offset[i] = ram_source_[i];
      return 1;
   }

private:
   const uint8_t *rom_;
   size_t rom_size_;
   int mapper_;
   size_t bank_count_;
   size_t bank_;
   bool superchip_;
   uint8_t *rom_exec_start_;
   uint16_t *rom_exec_pc_;
   vcsc_concrete_result_t *result_;
   uint8_t swcha_ = 0xffu;
   uint8_t swchb_ = 0xffu;
   uint8_t inpt_[6] = { 0x80u, 0x80u, 0x80u, 0x80u, 0x80u, 0x80u };
   uint8_t ram_[VCSC_CONCRETE_RIOT_RAM_SIZE];
   uint32_t ram_source_[VCSC_CONCRETE_RIOT_RAM_SIZE];
   uint8_t cart_ram_[kCartRamBytes];
   mos6502 cpu_;
   uint64_t cpu_cycles_ = 0;
   uint64_t virtual_cycles_ = 0;
   bool timer_active_ = false;
   uint64_t timer_start_ = 0;
   uint16_t timer_divisor_ = 1;
   uint8_t timer_loaded_ = 0;
   PendingWrite pending_[8]{};
   unsigned pending_count_ = 0;
   uint16_t current_pc_ = 0;
   uint8_t current_opcode_ = 0;
   unsigned current_len_ = 1;
   uint32_t current_data_source_ = VCSC_CONCRETE_NO_SOURCE;
   uint8_t current_data_value_ = 0;
   unsigned current_data_reads_ = 0;
   uint32_t a_source_ = VCSC_CONCRETE_NO_SOURCE;
   uint32_t x_source_ = VCSC_CONCRETE_NO_SOURCE;
   uint32_t y_source_ = VCSC_CONCRETE_NO_SOURCE;
   unsigned jsr_depth_ = 0;
   unsigned interrupt_depth_ = 0;
   uint8_t wd_config_ = 0u;
   bool wd_pending_ = false;
   uint8_t wd_pending_config_ = 0u;
   uint16_t fc_pending_ = 0u;
   uint8_t e0_segment_[3] = { 4u, 5u, 6u };
   unsigned e7_lower_ = 0u;
   unsigned e7_ram_block_ = 0u;
   uint16_t three_config_ = 0u;
   bool fe_waiting_data_ = false;

   static DiscoveryMachine *active_;
   static uint8_t read_thunk(uint16_t address) { return active_->read(address); }
   static void write_thunk(uint16_t address, uint8_t value) { active_->write(address, value); }

   static uint16_t bus_address(uint16_t address) {
      return static_cast<uint16_t>(address & 0x1fffu);
   }

   bool tia_selected(uint16_t bus) const { return (bus & 0x1080u) == 0u; }
   bool riot_ram_selected(uint16_t bus) const { return (bus & 0x1280u) == 0x0080u; }
   bool riot_io_selected(uint16_t bus) const { return (bus & 0x1280u) == 0x0280u; }

   bool mapper_is_wd() const { return mapper_ == kMapWD || mapper_ == kMapWDSW; }

   size_t wd_physical_bank(size_t logical) const
   {
      if (mapper_ == kMapWDSW) {
         if (logical == 2u) return 3u;
         if (logical == 3u) return 2u;
      }
      return logical;
   }

   bool select_simple_bank(uint16_t bus)
   {
      size_t next = bank_;
      bool hit = false;
      if (mapper_ == kMapF8 && bus >= 0x1ff8u && bus <= 0x1ff9u) {
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
      else if (mapper_ == kMap0FA0) {
         switch (bus & 0x16e0u) {
         case 0x06a0u: next = 0u; hit = true; break;
         case 0x06c0u: next = 1u; hit = true; break;
         default: break;
         }
      }
      if (hit && next < bank_count_) bank_ = next;
      return hit;
   }

   void fc_write_selector(uint16_t bus, uint8_t value)
   {
      if (mapper_ != kMapFC || bank_count_ == 0u) return;
      if (bus == 0x1ff8u) {
         fc_pending_ = static_cast<uint16_t>(value & 3u);
      }
      else if (bus == 0x1ff9u) {
         const unsigned high = static_cast<unsigned>(value) << 2;
         if (high < bank_count_)
            fc_pending_ = static_cast<uint16_t>((fc_pending_ + high) % bank_count_);
         else
            fc_pending_ = static_cast<uint16_t>(value % bank_count_);
      }
   }

   void fc_commit_if_needed(uint16_t bus)
   {
      if (mapper_ == kMapFC && bus == 0x1ffcu && bank_count_ != 0u)
         bank_ = static_cast<size_t>(fc_pending_ % bank_count_);
   }

   void e0_select(uint16_t bus)
   {
      if (mapper_ != kMapE0 || bus < 0x1fe0u || bus > 0x1ff7u) return;
      const unsigned segment = static_cast<unsigned>((bus - 0x1fe0u) >> 3);
      if (segment < 3u) e0_segment_[segment] = static_cast<uint8_t>(bus & 7u);
   }

   void e7_select(uint16_t bus)
   {
      if (mapper_ != kMapE7) return;
      if (bus >= 0x1fe8u && bus <= 0x1febu) {
         e7_ram_block_ = static_cast<unsigned>(bus & 3u);
         return;
      }
      if (bank_count_ == 4u) {
         if (bus >= 0x1fe4u && bus <= 0x1fe7u) e7_lower_ = static_cast<unsigned>(bus & 3u);
      }
      else if (bank_count_ == 6u) {
         static const uint8_t banks[8] = { 0, 1, 0, 1, 2, 3, 4, 5 };
         if (bus >= 0x1fe0u && bus <= 0x1fe7u) e7_lower_ = banks[bus & 7u];
      }
      else if (bank_count_ == 8u) {
         if (bus >= 0x1fe0u && bus <= 0x1fe7u) e7_lower_ = static_cast<unsigned>(bus & 7u);
      }
   }

   bool threee_ram_selected() const
   {
      return mapper_ == kMap3E && (three_config_ & kThreeERamFlag) != 0u;
   }

   unsigned threee_ram_bank() const { return static_cast<unsigned>(three_config_ & 0x1fu); }

   void three_write_selector(uint16_t bus, uint8_t value)
   {
      if (mapper_ == kMap3F) {
         if (bus <= 0x003fu && bank_count_ != 0u)
            three_config_ = static_cast<uint16_t>(value % bank_count_);
         return;
      }
      if (mapper_ != kMap3E) return;
      if (bus == 0x003eu)
         three_config_ = static_cast<uint16_t>(kThreeERamFlag | (value % kThreeERamBanks));
      else if (bus == 0x003fu && bank_count_ != 0u)
         three_config_ = static_cast<uint16_t>(value % bank_count_);
   }

   static size_t fe_bank_from_data(uint8_t value)
   {
      return static_cast<size_t>(((value >> 5) ^ 0x07u) & 1u);
   }

   void fe_observe_access(uint16_t bus, uint8_t value)
   {
      if (mapper_ != kMapFE) return;
      const bool was_waiting = fe_waiting_data_;
      if (was_waiting && bank_count_ >= 2u) {
         const size_t next = fe_bank_from_data(value);
         if (next < bank_count_) bank_ = next;
         fe_waiting_data_ = false;
      }
      if (bus == 0x01feu) fe_waiting_data_ = true;
   }

   bool map_cart(uint16_t bus, size_t *physical) const
   {
      if (!(bus & 0x1000u)) return false;

      if (mapper_ == kMap1K) {
         *physical = static_cast<size_t>(bus & 0x03ffu);
         return *physical < rom_size_;
      }
      if (mapper_ == kMap2K) {
         *physical = static_cast<size_t>(bus & 0x07ffu);
         return *physical < rom_size_;
      }
      if (mapper_ == kMapCV) {
         if (bus < 0x1800u) return false;
         *physical = static_cast<size_t>(bus & 0x07ffu);
         return *physical < rom_size_;
      }
      if (mapper_is_wd()) {
         if (bus < 0x1080u) return false;
         const unsigned segment = static_cast<unsigned>((bus - 0x1000u) >> 10);
         if (segment >= 4u) return false;
         const size_t logical = kWdBankOrg[wd_config_ & 7u][segment];
         const size_t physical_bank = wd_physical_bank(logical);
         *physical = physical_bank * 1024u + static_cast<size_t>(bus & 0x03ffu);
         return *physical < std::min<size_t>(rom_size_, 8192u);
      }
      if (mapper_ == kMapE0) {
         const unsigned segment = static_cast<unsigned>((bus - 0x1000u) >> 10);
         if (segment >= 4u) return false;
         const size_t pb = segment < 3u ? e0_segment_[segment] : 7u;
         *physical = pb * 1024u + static_cast<size_t>(bus & 0x03ffu);
         return pb < bank_count_ && *physical < rom_size_;
      }
      if (mapper_ == kMapE7) {
         size_t pb;
         if (bus < 0x1800u) {
            if (e7_lower_ == bank_count_ - 1u) return false;
            pb = e7_lower_;
         }
         else {
            if (bus < 0x1a00u || bank_count_ == 0u) return false;
            pb = bank_count_ - 1u;
         }
         *physical = pb * 2048u + static_cast<size_t>(bus & 0x07ffu);
         return pb < bank_count_ && *physical < rom_size_;
      }
      if (mapper_ == kMap3F || mapper_ == kMap3E) {
         size_t pb;
         if (bus < 0x1800u) {
            if (threee_ram_selected()) return false;
            pb = bank_count_ ? static_cast<size_t>(three_config_ % bank_count_) : 0u;
         }
         else
            pb = bank_count_ ? bank_count_ - 1u : 0u;
         *physical = pb * 2048u + static_cast<size_t>(bus & 0x07ffu);
         return pb < bank_count_ && *physical < rom_size_;
      }

      /* FA and Superchip hide their RAM aliases rather than exposing the ROM
       * bytes underneath them to the CPU. */
      if (mapper_ == kMapFA && bus < 0x1200u) return false;
      if (superchip_ && bus < 0x1100u) return false;

      const size_t off = static_cast<size_t>(bus & 0x0fffu);
      *physical = bank_ * 4096u + off;
      return bank_ < bank_count_ && *physical < rom_size_;
   }

   uint8_t cart_peek(uint16_t bus) const
   {
      if (mapper_ == kMapFA) {
         if (bus >= 0x1100u && bus <= 0x11ffu) return cart_ram_[bus & 0xffu];
         if (bus >= 0x1000u && bus <= 0x10ffu) return 0u;
      }
      if (superchip_) {
         if (bus >= 0x1080u && bus <= 0x10ffu) return cart_ram_[bus & 0x7fu];
         if (bus >= 0x1000u && bus <= 0x107fu) return 0u;
      }
      if (mapper_ == kMapCV) {
         if (bus >= 0x1000u && bus <= 0x13ffu) return cart_ram_[bus & 0x03ffu];
         if (bus >= 0x1400u && bus <= 0x17ffu) return 0u;
      }
      if (mapper_is_wd()) {
         if (bus >= 0x1000u && bus <= 0x103fu) return cart_ram_[bus & 0x3fu];
         if (bus >= 0x1040u && bus <= 0x107fu) return 0u;
      }
      if (mapper_ == kMapE7) {
         if (e7_lower_ == bank_count_ - 1u && bus >= 0x1000u && bus < 0x1800u) {
            if (bus >= 0x1400u) return cart_ram_[bus & 0x03ffu];
            return 0u;
         }
         if (bus >= 0x1800u && bus < 0x1a00u) {
            if (bus >= 0x1900u)
               return cart_ram_[1024u + e7_ram_block_ * 256u + (bus & 0xffu)];
            return 0u;
         }
      }
      if (threee_ram_selected() && bus >= 0x1000u && bus < 0x1800u) {
         if (bus >= 0x1400u)
            return cart_ram_[threee_ram_bank() * 1024u + (bus & 0x03ffu)];
         return 0u;
      }
      size_t physical;
      if (map_cart(bus, &physical)) return rom_[physical];
      return 0xffu;
   }

   uint8_t peek_opcode(uint16_t address) const
   {
      const uint16_t bus = bus_address(address);
      if (bus & 0x1000u) return cart_peek(bus);
      if (riot_ram_selected(bus)) return ram_[bus & 0x7fu];
      return 0u;
   }

   void note_instruction(uint16_t pc, uint8_t opcode)
   {
      const uint16_t bus = bus_address(pc);
      if (bus & 0x1000u) {
         size_t physical;
         if (map_cart(bus, &physical)) {
            if (!rom_exec_start_[physical]) {
               rom_exec_start_[physical] = 1;
               rom_exec_pc_[physical] = pc;
               ++result_->rom_instruction_starts;
            }
         }
         return;
      }
      if (riot_ram_selected(bus)) {
         const unsigned idx = static_cast<unsigned>(bus & 0x7fu);
         if (!result_->ram_exec_start[idx]) {
            result_->ram_exec_start[idx] = 1;
            result_->ram_exec_pc[idx] = pc;
            const unsigned len = instruction_length(opcode);
            result_->ram_exec_len[idx] = static_cast<uint8_t>(len);
            for (unsigned j = 0; j < len && j < VCSC_CONCRETE_MAX_INSN_BYTES; ++j) {
               const uint16_t a = static_cast<uint16_t>(pc + j);
               const uint16_t ab = bus_address(a);
               uint8_t v = 0;
               if (riot_ram_selected(ab)) {
                  const unsigned ri = static_cast<unsigned>(ab & 0x7fu);
                  v = ram_[ri];
                  result_->ram_exec_source[idx * VCSC_CONCRETE_MAX_INSN_BYTES + j] = ram_source_[ri];
               }
               result_->ram_exec_bytes[idx * VCSC_CONCRETE_MAX_INSN_BYTES + j] = v;
            }
            ++result_->ram_instruction_starts;
         }
      }
   }

   uint8_t timer_value() const
   {
      if (!timer_active_) return 0;
      const uint64_t ticks = (virtual_cycles_ - timer_start_) / timer_divisor_;
      if (ticks <= timer_loaded_) return static_cast<uint8_t>(timer_loaded_ - ticks);
      return static_cast<uint8_t>(255u - ((ticks - timer_loaded_ - 1u) & 255u));
   }

   bool timer_underflowed() const
   {
      if (!timer_active_) return false;
      return (virtual_cycles_ - timer_start_) / timer_divisor_ > timer_loaded_;
   }

   uint8_t cart_read(uint16_t bus)
   {
      /* Immediate/simple hotspot families switch on the access before the
       * returned ROM byte is observed, matching the established probe model.
       * Segmented/staged families below update after the current access so the
       * next CPU cycle sees the new mapping. */
      (void)select_simple_bank(bus);

      size_t physical = 0u;
      const bool rom_value = map_cart(bus, &physical);
      const uint8_t value = cart_peek(bus);
      const uint16_t delta = static_cast<uint16_t>(bus - bus_address(current_pc_));
      const bool fetch_byte = delta < current_len_;
      if (rom_value && !fetch_byte) {
         current_data_source_ = static_cast<uint32_t>(physical);
         current_data_value_ = value;
         ++current_data_reads_;
      }

      if (mapper_ == kMapFC) fc_commit_if_needed(bus);
      else if (mapper_ == kMapE0) e0_select(bus);
      else if (mapper_ == kMapE7) e7_select(bus);
      fe_observe_access(bus, value);
      return value;
   }

   void cart_write(uint16_t bus, uint8_t value)
   {
      if (mapper_ == kMapFA && bus >= 0x1000u && bus <= 0x10ffu) {
         cart_ram_[bus & 0xffu] = value;
      }
      else if (superchip_ && bus >= 0x1000u && bus <= 0x107fu) {
         cart_ram_[bus & 0x7fu] = value;
      }
      else if (mapper_ == kMapCV && bus >= 0x1400u && bus <= 0x17ffu) {
         cart_ram_[bus & 0x03ffu] = value;
      }
      else if (mapper_is_wd() && bus >= 0x1040u && bus <= 0x107fu) {
         cart_ram_[bus & 0x3fu] = value;
      }
      else if (mapper_ == kMapE7) {
         if (e7_lower_ == bank_count_ - 1u && bus >= 0x1000u && bus < 0x1400u)
            cart_ram_[bus & 0x03ffu] = value;
         else if (bus >= 0x1800u && bus < 0x1900u)
            cart_ram_[1024u + e7_ram_block_ * 256u + (bus & 0xffu)] = value;
      }
      else if (threee_ram_selected() && bus >= 0x1000u && bus < 0x1400u) {
         cart_ram_[threee_ram_bank() * 1024u + (bus & 0x03ffu)] = value;
      }

      (void)select_simple_bank(bus);
      if (mapper_ == kMapFC) {
         fc_write_selector(bus, value);
         fc_commit_if_needed(bus);
      }
      else if (mapper_ == kMapE0) e0_select(bus);
      else if (mapper_ == kMapE7) e7_select(bus);
      fe_observe_access(bus, value);
   }

   uint8_t read(uint16_t address)
   {
      const uint16_t bus = bus_address(address);
      if (bus & 0x1000u) return cart_read(bus);

      (void)select_simple_bank(bus);
      uint8_t value = 0u;
      if (tia_selected(bus)) {
         const uint8_t reg = static_cast<uint8_t>(bus & 0x3fu);
         if (reg >= 0x08u && reg <= 0x0du) {
            result_->input_read_mask |= kInputINPT0 << (reg - 0x08u);
            value = inpt_[reg - 0x08u];
         }
         if (mapper_is_wd() && reg >= 0x30u && reg <= 0x3fu) {
            wd_pending_ = true;
            wd_pending_config_ = static_cast<uint8_t>(reg & 7u);
         }
         fe_observe_access(bus, value);
         return value;
      }
      if (riot_ram_selected(bus)) {
         const unsigned idx = static_cast<unsigned>(bus & 0x7fu);
         current_data_source_ = ram_source_[idx];
         current_data_value_ = ram_[idx];
         ++current_data_reads_;
         value = ram_[idx];
         fe_observe_access(bus, value);
         return value;
      }
      if (riot_io_selected(bus)) {
         const uint16_t reg = static_cast<uint16_t>(0x0280u | (bus & 0x1fu));
         if (reg == 0x0280u) {
            result_->input_read_mask |= kInputSWCHA;
            value = swcha_;
         }
         else if (reg == 0x0282u) {
            result_->input_read_mask |= kInputSWCHB;
            value = swchb_;
         }
         else if (reg == 0x0284u) value = timer_value();
         else if (reg == 0x0285u) value = timer_underflowed() ? 0x80u : 0u;
         fe_observe_access(bus, value);
         return value;
      }
      fe_observe_access(bus, value);
      return value;
   }

   uint32_t store_source() const
   {
      const char *m = mos6502::GetCode(current_opcode_);
      if (!m) return VCSC_CONCRETE_NO_SOURCE;
      if (std::strcmp(m, "STA") == 0) return a_source_;
      if (std::strcmp(m, "STX") == 0) return x_source_;
      if (std::strcmp(m, "STY") == 0) return y_source_;
      return VCSC_CONCRETE_NO_SOURCE;
   }

   void queue_write(uint16_t bus, uint8_t value)
   {
      if (pending_count_ < sizeof(pending_) / sizeof(pending_[0]))
         pending_[pending_count_++] = { bus, value };
   }

   void write(uint16_t address, uint8_t value)
   {
      const uint16_t bus = bus_address(address);
      if (bus & 0x1000u) { cart_write(bus, value); return; }

      (void)select_simple_bank(bus);
      three_write_selector(bus, value);
      if (tia_selected(bus)) {
         const uint16_t reg = static_cast<uint16_t>(bus & 0x3fu);
         if (reg == 0x02u) queue_write(reg, value);
         fe_observe_access(bus, value);
         return;
      }
      if (riot_ram_selected(bus)) {
         const unsigned idx = static_cast<unsigned>(bus & 0x7fu);
         if (!result_->ram_written[idx]) {
            result_->ram_written[idx] = 1;
            ++result_->ram_bytes_written;
         }
         ram_[idx] = value;
         ram_source_[idx] = store_source();
         fe_observe_access(bus, value);
         return;
      }
      if (riot_io_selected(bus)) {
         const uint16_t reg = static_cast<uint16_t>(0x0280u | (bus & 0x1fu));
         if (reg >= 0x0294u && reg <= 0x0297u) queue_write(reg, value);
      }
      fe_observe_access(bus, value);
   }

   void load_timer(uint16_t reg, uint8_t value)
   {
      timer_active_ = true;
      timer_start_ = virtual_cycles_;
      timer_loaded_ = value;
      timer_divisor_ = reg == 0x0294u ? 1u : reg == 0x0295u ? 8u :
                       reg == 0x0296u ? 64u : 1024u;
   }

   void apply_pending()
   {
      for (unsigned i = 0; i < pending_count_; ++i) {
         const uint16_t reg = pending_[i].address;
         if (reg == 0x02u) {
            const uint64_t within = virtual_cycles_ % kCyclesPerLine;
            virtual_cycles_ += within ? kCyclesPerLine - within : kCyclesPerLine;
         }
         else if (reg >= 0x0294u && reg <= 0x0297u)
            load_timer(reg, pending_[i].value);
      }
      pending_count_ = 0;
      if (wd_pending_) {
         wd_config_ = wd_pending_config_;
         wd_pending_ = false;
      }
   }

   uint32_t immediate_source(uint16_t pc) const
   {
      const uint16_t bus = bus_address(static_cast<uint16_t>(pc + 1u));
      size_t physical;
      if ((bus & 0x1000u) && map_cart(bus, &physical))
         return static_cast<uint32_t>(physical);
      if (riot_ram_selected(bus)) return ram_source_[bus & 0x7fu];
      return VCSC_CONCRETE_NO_SOURCE;
   }

   void update_register_provenance(uint8_t opcode)
   {
      const char *m = mos6502::GetCode(opcode);
      const char *mode = mos6502::GetAddr(opcode);
      if (!m) { a_source_ = x_source_ = y_source_ = VCSC_CONCRETE_NO_SOURCE; return; }
      uint32_t load_source = current_data_reads_ ? current_data_source_ : VCSC_CONCRETE_NO_SOURCE;
      if (mode && std::strcmp(mode, "IMM") == 0) load_source = immediate_source(current_pc_);
      if (std::strcmp(m, "LDA") == 0) a_source_ = load_source;
      else if (std::strcmp(m, "LDX") == 0) x_source_ = load_source;
      else if (std::strcmp(m, "LDY") == 0) y_source_ = load_source;
      else if (std::strcmp(m, "TAX") == 0) x_source_ = a_source_;
      else if (std::strcmp(m, "TAY") == 0) y_source_ = a_source_;
      else if (std::strcmp(m, "TXA") == 0) a_source_ = x_source_;
      else if (std::strcmp(m, "TYA") == 0) a_source_ = y_source_;
      else if (std::strcmp(m, "PLA") == 0) a_source_ = load_source;
      else if (std::strcmp(m, "INX") == 0 || std::strcmp(m, "DEX") == 0) x_source_ = VCSC_CONCRETE_NO_SOURCE;
      else if (std::strcmp(m, "INY") == 0 || std::strcmp(m, "DEY") == 0) y_source_ = VCSC_CONCRETE_NO_SOURCE;
      else if (std::strcmp(m, "ADC") == 0 || std::strcmp(m, "SBC") == 0 ||
               std::strcmp(m, "AND") == 0 || std::strcmp(m, "ORA") == 0 ||
               std::strcmp(m, "EOR") == 0 || std::strcmp(m, "ASL") == 0 ||
               std::strcmp(m, "LSR") == 0 || std::strcmp(m, "ROL") == 0 ||
               std::strcmp(m, "ROR") == 0)
         a_source_ = VCSC_CONCRETE_NO_SOURCE;
   }
};

DiscoveryMachine *DiscoveryMachine::active_ = nullptr;

static unsigned merge_run(size_t rom_size,
                          uint8_t *rom_exec_start, uint16_t *rom_exec_pc,
                          vcsc_concrete_result_t *dst,
                          const uint8_t *run_exec_start,
                          const uint16_t *run_exec_pc,
                          const vcsc_concrete_result_t &src,
                          bool keep_final_cpu)
{
   unsigned new_reachability = 0;
   dst->instructions += src.instructions;
   dst->input_read_mask |= src.input_read_mask;
   dst->halted |= src.halted;
   dst->instruction_limit |= src.instruction_limit;
   dst->converged |= src.converged;
   dst->top_level_return |= src.top_level_return;
   ++dst->scenarios_run;

   if (keep_final_cpu) {
      dst->final_pc = src.final_pc;
      dst->final_a = src.final_a;
      dst->final_x = src.final_x;
      dst->final_y = src.final_y;
      dst->final_sp = src.final_sp;
      dst->final_p = src.final_p;
   }

   for (size_t i = 0; i < rom_size; ++i) {
      if (!run_exec_start[i] || rom_exec_start[i]) continue;
      rom_exec_start[i] = 1;
      rom_exec_pc[i] = run_exec_pc[i];
      ++dst->rom_instruction_starts;
      ++new_reachability;
   }

   for (unsigned i = 0; i < VCSC_CONCRETE_RIOT_RAM_SIZE; ++i) {
      if (src.ram_written[i] && !dst->ram_written[i]) {
         dst->ram_written[i] = 1;
         ++dst->ram_bytes_written;
      }
      if (dst->ram_source_offset[i] == VCSC_CONCRETE_NO_SOURCE &&
          src.ram_source_offset[i] != VCSC_CONCRETE_NO_SOURCE)
         dst->ram_source_offset[i] = src.ram_source_offset[i];
      if (!src.ram_exec_start[i] || dst->ram_exec_start[i]) continue;
      dst->ram_exec_start[i] = 1;
      dst->ram_exec_pc[i] = src.ram_exec_pc[i];
      dst->ram_exec_len[i] = src.ram_exec_len[i];
      for (unsigned j = 0; j < VCSC_CONCRETE_MAX_INSN_BYTES; ++j) {
         const unsigned di = i * VCSC_CONCRETE_MAX_INSN_BYTES + j;
         dst->ram_exec_bytes[di] = src.ram_exec_bytes[di];
         dst->ram_exec_source[di] = src.ram_exec_source[di];
      }
      ++dst->ram_instruction_starts;
      ++new_reachability;
   }
   if (new_reachability) ++dst->scenarios_with_new_reachability;
   return new_reachability;
}
}

extern "C" int vcsc_concrete_discover(const uint8_t *rom, size_t rom_size,
                                        int mapper, size_t bank_count,
                                        size_t reset_bank, int superchip,
                                        uint8_t *rom_exec_start,
                                        uint16_t *rom_exec_pc,
                                        vcsc_concrete_result_t *result)
{
   if (!rom || !rom_exec_start || !rom_exec_pc || !result ||
       bank_count == 0u || reset_bank >= bank_count) return 0;
   switch (mapper) {
   case kMap1K:
   case kMap2K:
   case kMap4K:
   case kMapF8:
   case kMapF6:
   case kMapF4:
   case kMapFA:
   case kMapWD:
   case kMapWDSW:
   case kMapFC:
   case kMapE0:
   case kMapE7:
   case kMap3F:
   case kMap3E:
   case kMapCV:
   case kMapJANE:
   case kMap0840:
   case kMapUA:
   case kMapUASW:
   case kMap0FA0:
   case kMapFE:
      break;
   case kMapDPC:
      /* DPC register/data-fetcher semantics remain intentionally outside the
       * concrete pass; static analysis is authoritative for DPC until that
       * coprocessor model is faithful. */
      std::memset(result, 0, sizeof(*result));
      return 0;
   default:
      std::memset(result, 0, sizeof(*result));
      return 0;
   }

   std::memset(result, 0, sizeof(*result));
   std::memset(rom_exec_start, 0, rom_size);
   std::memset(rom_exec_pc, 0, rom_size * sizeof(*rom_exec_pc));
   for (unsigned i = 0; i < VCSC_CONCRETE_RIOT_RAM_SIZE; ++i)
      result->ram_source_offset[i] = VCSC_CONCRETE_NO_SOURCE;
   for (unsigned i = 0; i < VCSC_CONCRETE_RIOT_RAM_SIZE * VCSC_CONCRETE_MAX_INSN_BYTES; ++i)
      result->ram_exec_source[i] = VCSC_CONCRETE_NO_SOURCE;

   auto run_one = [&](uint8_t swcha, uint8_t swchb, const uint8_t inpt[6],
                      bool keep_final_cpu) -> int {
      std::vector<uint8_t> run_exec(rom_size, 0);
      std::vector<uint16_t> run_pc(rom_size, 0);
      vcsc_concrete_result_t run_result{};
      DiscoveryMachine machine(rom, rom_size, mapper, bank_count, reset_bank,
                               superchip != 0, swcha, swchb, inpt,
                               run_exec.data(), run_pc.data(), &run_result);
      if (!machine.run()) return 0;
      merge_run(rom_size, rom_exec_start, rom_exec_pc, result,
                run_exec.data(), run_pc.data(), run_result, keep_final_cpu);
      return 1;
   };

   uint8_t neutral_inpt[6] = { 0x80u, 0x80u, 0x80u, 0x80u, 0x80u, 0x80u };
   if (!run_one(0xffu, 0xffu, neutral_inpt, true)) return 0;

   /* H1 alternate-input discovery.  Do not blindly multiply every concrete
    * run: only vary an input family after an already executed path actually
    * read it.  Each scenario changes one active-low input at a time, so every
    * newly observed instruction is a real execution under a simple, documented
    * controller/console state rather than a speculative static edge. */
   if (result->input_read_mask & kInputSWCHA) {
      for (unsigned bit = 0; bit < 8u; ++bit) {
         uint8_t swcha = (uint8_t)(0xffu & ~(1u << bit));
         if (!run_one(swcha, 0xffu, neutral_inpt, false)) return 0;
      }
   }
   if (result->input_read_mask & kInputSWCHB) {
      static const unsigned useful_bits[] = { 7u, 6u, 3u, 1u, 0u };
      for (unsigned bit : useful_bits) {
         uint8_t swchb = (uint8_t)(0xffu & ~(1u << bit));
         if (!run_one(0xffu, swchb, neutral_inpt, false)) return 0;
      }
   }
   for (unsigned input = 0; input < 6u; ++input) {
      if (!(result->input_read_mask & (kInputINPT0 << input))) continue;
      uint8_t active_inpt[6] = { 0x80u, 0x80u, 0x80u, 0x80u, 0x80u, 0x80u };
      active_inpt[input] = 0x00u;
      if (!run_one(0xffu, 0xffu, active_inpt, false)) return 0;
   }
   return 1;
}
