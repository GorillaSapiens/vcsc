#!/usr/bin/perl
# runner: perl @FILE@ @REPO@
# phase: compile
# timeout: 20
# expectexit: 0
# expectstdout: inline analysis unit tests passed

use strict;
use warnings;
use File::Spec;
use File::Temp qw(tempdir);
use Cwd qw(abs_path);

my $repo = abs_path($ARGV[0] // File::Spec->catdir(File::Spec->curdir(), '..'));
my $tmp = tempdir(CLEANUP => 1);
my $src = File::Spec->catfile($tmp, 'inline_analysis_unit.c');
my $exe = File::Spec->catfile($tmp, 'inline_analysis_unit');

open my $fh, '>', $src or die "could not write $src: $!\n";
print $fh <<'C_EOF';
#include <stdio.h>
#include <stdlib.h>
#include "compile_inline_analysis.h"

static void require_true(int ok, const char *what) {
   if (!ok) {
      fprintf(stderr, "inline analysis unit failure: %s\n", what);
      exit(1);
   }
}

int main(void) {
   int caller_a, caller_b, site_a, site_b, site_c, site_d;
   int zero, once, twice, sibling, exported, declaration, source_inline, late;
   unsigned base = INLINE_FUNCTION_DEFINED | INLINE_FUNCTION_INTERNAL;

   inline_analysis_reset();
   require_true(inline_analysis_direct_call_site_count(&zero) == 0,
                "unknown function must have zero calls");
   require_true(!inline_analysis_is_baseline_candidate(&zero),
                "unknown function must not be a candidate");

   inline_analysis_register_function(&zero, base);
   require_true(!inline_analysis_is_baseline_candidate(&zero),
                "zero-call internal definition must not be a candidate");

   inline_analysis_register_function(&once, base);
   inline_analysis_record_direct_call(&caller_a, &site_a, &once);
   require_true(inline_analysis_direct_call_site_count(&once) == 1,
                "one callsite must count as one");
   require_true(inline_analysis_single_direct_caller(&once) == &caller_a,
                "one callsite must retain its caller");
   require_true(inline_analysis_single_direct_callsite(&once) == &site_a,
                "one callsite must retain its exact source call expression");
   require_true(inline_analysis_is_baseline_candidate(&once),
                "one-call internal definition must be a candidate");

   inline_analysis_register_function(&twice, base);
   inline_analysis_record_direct_call(&caller_a, &site_b, &twice);
   inline_analysis_record_direct_call(&caller_a, &site_c, &twice);
   require_true(inline_analysis_direct_call_site_count(&twice) == 2,
                "two calls from one caller must count as two callsites");
   require_true(inline_analysis_single_direct_caller(&twice) == NULL,
                "multi-call function must not report a single caller");
   require_true(inline_analysis_single_direct_callsite(&twice) == NULL,
                "multi-call function must not report a single call expression");
   require_true(!inline_analysis_is_baseline_candidate(&twice),
                "two-call internal definition must not be a candidate");

   inline_analysis_register_function(&sibling, base);
   inline_analysis_record_direct_call(&caller_a, &site_d, &sibling);
   require_true(inline_analysis_is_baseline_candidate(&once) &&
                inline_analysis_is_baseline_candidate(&sibling),
                "distinct callees called once each must both be candidates");

   inline_analysis_register_function(&exported, INLINE_FUNCTION_DEFINED);
   inline_analysis_record_direct_call(&caller_a, &site_a, &exported);
   require_true(!inline_analysis_is_baseline_candidate(&exported),
                "exported definition must not be a baseline candidate");

   inline_analysis_register_function(&declaration, INLINE_FUNCTION_INTERNAL);
   inline_analysis_record_direct_call(&caller_a, &site_a, &declaration);
   require_true(!inline_analysis_is_baseline_candidate(&declaration),
                "body-less declaration must not be a baseline candidate");

   inline_analysis_register_function(&source_inline,
      base | INLINE_FUNCTION_SOURCE_INLINE);
   inline_analysis_record_direct_call(&caller_a, &site_a, &source_inline);
   require_true(!inline_analysis_is_baseline_candidate(&source_inline),
                "source inline function must remain separate from optimizer candidates");

   inline_analysis_record_direct_call(&caller_b, &site_b, &late);
   inline_analysis_register_function(&late, base);
   require_true(inline_analysis_direct_call_site_count(&late) == 1 &&
                inline_analysis_single_direct_caller(&late) == &caller_b &&
                inline_analysis_is_baseline_candidate(&late),
                "late registration must preserve already-recorded call facts");

   inline_analysis_reset();
   {
      int root, child, grandchild, unreachable, runtime_only, cycle_a, cycle_b;
      int edge_root_child, edge_child_grandchild, edge_runtime, edge_cycle_ab, edge_cycle_ba;

      inline_analysis_register_function(&root, base);
      inline_analysis_register_function(&child, base);
      inline_analysis_register_function(&grandchild, base);
      inline_analysis_register_function(&unreachable, base);
      inline_analysis_register_function(&runtime_only, base);
      inline_analysis_register_function(&cycle_a, base);
      inline_analysis_register_function(&cycle_b, base);
      inline_analysis_record_direct_call(&root, &edge_root_child, &child);
      inline_analysis_record_direct_call(&child, &edge_child_grandchild, &grandchild);
      inline_analysis_record_direct_call(NULL, &edge_runtime, &runtime_only);
      inline_analysis_record_direct_call(&cycle_a, &edge_cycle_ab, &cycle_b);
      inline_analysis_record_direct_call(&cycle_b, &edge_cycle_ba, &cycle_a);
      inline_analysis_mark_reachable_root(&root);
      inline_analysis_compute_reachability();
      require_true(inline_analysis_is_reachable(&root) &&
                   inline_analysis_is_reachable(&child) &&
                   inline_analysis_is_reachable(&grandchild),
                   "reachability must propagate through enabled direct calls");
      require_true(!inline_analysis_is_reachable(&unreachable),
                   "unrooted function must remain unreachable");
      require_true(inline_analysis_is_reachable(&runtime_only) &&
                   !inline_analysis_is_baseline_candidate(&runtime_only),
                   "runtime-initializer call must root its callee without making it inlineable");
      require_true(inline_analysis_is_in_cycle(&cycle_a) &&
                   inline_analysis_is_in_cycle(&cycle_b),
                   "call-cycle members must be recorded even when unreachable");

      inline_analysis_reset_reachability();
      inline_analysis_mark_reachable_root(&root);
      inline_analysis_set_direct_call_reachability(&root, &edge_root_child, false);
      inline_analysis_compute_reachability();
      require_true(inline_analysis_is_reachable(&root) &&
                   !inline_analysis_is_reachable(&child) &&
                   !inline_analysis_is_reachable(&grandchild),
                   "disabled direct call must not propagate reachability");
   }

   inline_analysis_reset();
   require_true(inline_analysis_direct_call_site_count(&once) == 0 &&
                !inline_analysis_is_baseline_candidate(&once),
                "reset must clear all translation-unit facts");

   puts("inline analysis unit tests passed");
   return 0;
}
C_EOF
close $fh;

my @cmd = (
   'gcc', '-Wall', '-Wextra', '-Werror', '-pedantic',
   '-I', File::Spec->catdir($repo, 'compiler'),
   $src, File::Spec->catfile($repo, 'compiler', 'compile_inline_analysis.c'),
   '-o', $exe,
);
system(@cmd) == 0 or die "compile failed: @cmd\n";
my $status = system($exe);
die "could not run $exe: $!\n" if $status == -1;
exit(128 + ($status & 127)) if $status & 127;
exit($status >> 8);
