//! @file assembler/ihex.h
//! @brief Declares Intel HEX emission for the n65 assembler.
//! @ingroup assembler

#ifndef IHEX_H
#define IHEX_H

#include <stdio.h>

#define IHEX_MAX_ADDR 65536

typedef struct ihex_image {
   unsigned char data[IHEX_MAX_ADDR];
   unsigned char used[IHEX_MAX_ADDR];
   int has_data;
   unsigned short min_addr;
   unsigned short max_addr;
} ihex_image_t;

void ihex_image_init(ihex_image_t *img);
int ihex_write_byte(ihex_image_t *img, long addr, unsigned char value);
int ihex_write_word(ihex_image_t *img, long addr, unsigned short value);
int ihex_dump(FILE *fp, const ihex_image_t *img);

#endif
