//! @file assembler/ihex.c
//! @brief Implements Intel HEX emission for the n65 assembler.
//! @ingroup assembler

#include <stdio.h>
#include <string.h>
#include "ihex.h"

void ihex_image_init(ihex_image_t *img)
{
   memset(img->data, 0, sizeof(img->data));
   memset(img->used, 0, sizeof(img->used));
   img->has_data = 0;
   img->min_addr = 0;
   img->max_addr = 0;
}

//! @brief Handle Intel HEX addr ok logic for ihex.
static int ihex_addr_ok(long addr)
{
   return addr >= 0 && addr < IHEX_MAX_ADDR;
}

//! @brief Handle Intel HEX write byte logic for ihex.
int ihex_write_byte(ihex_image_t *img, long addr, unsigned char value)
{
   if (!ihex_addr_ok(addr))
      return 0;

   img->data[addr] = value;
   img->used[addr] = 1;

   if (!img->has_data) {
      img->has_data = 1;
      img->min_addr = (unsigned short)addr;
      img->max_addr = (unsigned short)addr;
   } else {
      if (addr < img->min_addr)
         img->min_addr = (unsigned short)addr;
      if (addr > img->max_addr)
         img->max_addr = (unsigned short)addr;
   }

   return 1;
}

//! @brief Handle Intel HEX write word logic for ihex.
int ihex_write_word(ihex_image_t *img, long addr, unsigned short value)
{
   if (!ihex_write_byte(img, addr, (unsigned char)(value & 0xFF)))
      return 0;
   if (!ihex_write_byte(img, addr + 1, (unsigned char)((value >> 8) & 0xFF)))
      return 0;
   return 1;
}

//! @brief Handle Intel HEX emit record logic for ihex.
static void ihex_emit_record(FILE *fp,
                             unsigned char count,
                             unsigned short addr,
                             unsigned char rectype,
                             const unsigned char *data)
{
   unsigned int sum;
   unsigned char cksum;
   unsigned int i;

   sum = count;
   sum += (addr >> 8) & 0xFF;
   sum += addr & 0xFF;
   sum += rectype;

   fprintf(fp, ":%02X%04X%02X", count, addr, rectype);

   for (i = 0; i < count; i++) {
      fprintf(fp, "%02X", data[i]);
      sum += data[i];
   }

   cksum = (unsigned char)((-((int)sum)) & 0xFF);
   fprintf(fp, "%02X\n", cksum);
}

//! @brief Handle Intel HEX dump logic for ihex.
int ihex_dump(FILE *fp, const ihex_image_t *img)
{
   unsigned int addr;

   if (!img->has_data) {
      ihex_emit_record(fp, 0, 0, 0x01, NULL);
      return 1;
   }

   addr = img->min_addr;
   while (addr <= img->max_addr) {
      unsigned char buf[16];
      unsigned char count;
      unsigned int start;

      while (addr <= img->max_addr && !img->used[addr])
         addr++;

      if (addr > img->max_addr)
         break;

      start = addr;
      count = 0;

      while (addr <= img->max_addr &&
             img->used[addr] &&
             count < sizeof(buf)) {
         buf[count++] = img->data[addr];
         addr++;
      }

      ihex_emit_record(fp, count, (unsigned short)start, 0x00, buf);
   }

   ihex_emit_record(fp, 0, 0, 0x01, NULL);
   return 1;
}
