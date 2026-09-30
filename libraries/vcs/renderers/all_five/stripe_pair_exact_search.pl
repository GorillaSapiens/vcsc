# This file is covered under CC0-1.0. See libraries/LICENSE.txt.
# Compatibility shim for the former one-pair refill proof.
#
# The authoritative ordinary/refill cadence now lives in
# stripe_pair_machine_search.pl.  Keep this filename only so old developer
# commands do not silently resurrect a second copy of the 152-cycle machine.

use strict;
use warnings;
use File::Basename qw(dirname);
use File::Spec;

local $ENV{VCSC_STRIPE_PAIR_MODE}='refill';
my $path=File::Spec->catfile(dirname(__FILE__),'stripe_pair_machine_search.pl');
my $problem=do $path;
if (!defined $problem) {
   die $@ if $@;
   die "cannot read $path: $!\n" if $!;
   die "$path did not return a problem\n";
}
return $problem;
