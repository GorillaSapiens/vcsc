//! @file assembler/listing.h
//! @brief Declares assembly listing generation for the n65 assembler.
//! @ingroup assembler

#ifndef LISTING_H
#define LISTING_H

#include <stdio.h>
#include "ir.h"

//! Listing writer state; owns the output stream while it is open.
typedef struct listing_writer {
   FILE *fp;
} listing_writer_t;

int listing_open(listing_writer_t *lst, const char *path);
void listing_close(listing_writer_t *lst);

void listing_write_record(listing_writer_t *lst,
                          const stmt_t *stmt,
                          long addr,
                          const unsigned char *bytes,
                          int byte_count);

void listing_write_no_bytes(listing_writer_t *lst, const stmt_t *stmt);

#endif
