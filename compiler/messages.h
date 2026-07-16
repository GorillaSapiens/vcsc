//! @file compiler/messages.h
//! @brief Declares compiler diagnostics for the n65 compiler.
//! @ingroup compiler

#ifndef _INCLUDE_MESSAGES_H_
#define _INCLUDE_MESSAGES_H_

// printf style messages emitted by the compiler
// XRAY_DEBUG is needed to see debug() messages

#include "noreturn.h"

void noreturn yyerror(const char *fmt, ...);
void yywarn(const char *fmt, ...);
void message(const char *fmt, ...);
void message_set_location(const char *filename, int line, int column, const char *near);
void message_clear_location(void);
void debug(const char *fmt, ...);
//void noreturn error(const char *fmt, ...);
void noreturn error_user(const char *fmt, ...);
void noreturn error_unimplemented(const char *fmt, ...);
void noreturn error_unreachable(const char *fmt, ...);
void warning(const char *fmt, ...);

#endif
