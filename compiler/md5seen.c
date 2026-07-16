//! @file compiler/md5seen.c
//! @brief Implements MD5 duplicate tracking for the n65 compiler.
//! @ingroup compiler

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

#include "messages.h"
#include "md5.h"
#include "md5seen.h"
#include "xray.h"

typedef struct MD5Seen {
   const char *filename;
   uint8_t md5[16];
   struct MD5Seen *next;
} MD5Seen;

static MD5Seen *root = NULL;

//! @brief Perform the md5seen step used for include-content identity tracking.
bool md5seen(const char *filename, FILE *f) {
   uint8_t md5[16];
   md5File(f, md5);
   fseek(f, 0, SEEK_SET);

   for (MD5Seen *node = root; node; node = node->next) {
      if (!memcmp(md5, node->md5, sizeof(md5))) {
         debug("md5seen: '%s' and '%s' match", filename, node->filename);
         return true;
      }
   }

   MD5Seen *node = (MD5Seen *) malloc(sizeof(MD5Seen));
   node->filename = strdup(filename);
   memcpy(node->md5, md5, sizeof(md5));
   node->next = root;
   root = node;

   return false;
}
