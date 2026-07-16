//! @file compiler/set.h
//! @brief Declares string-keyed set/map collection for the n65 compiler.
//! @ingroup compiler

#ifndef _INCLUDE_SET_H_
#define _INCLUDE_SET_H_

// required typedefs
//! Opaque string-keyed collection used by compiler registries.
struct Set;
typedef struct Set Set;

// create a new Set
Set *new_set(void);

// delete an existing set, freeing all memory
void del_set(Set *set);

// add a key/value pair to a set.  allocation/free of key & value handled by caller
int set_add(Set *set, const char *key, const void *value);

// get the value associated with key
const void *set_get(Set *set, const char *key);

// remove a key from the Set
void set_rm(Set *set, const char *key);

#endif
