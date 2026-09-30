# This file is covered under CC0-1.0. See libraries/LICENSE.txt.
# Compatibility shim for the former separately transcribed three-pair proof.
# The authoritative cadence and complete six-PF/two-color service now live in
# stripe_pair_machine_search.pl.

use strict;
use warnings;
use File::Basename qw(dirname);
use File::Spec;

local $ENV{VCSC_STRIPE_PAIR_MODE}='refill';
local $ENV{VCSC_STRIPE_PAIR_COUNT}=3;
my $path=File::Spec->catfile(dirname(__FILE__),'stripe_pair_machine_search.pl');
my $problem=do $path;
if (!defined $problem) {
   die $@ if $@;
   die "cannot read $path: $!\n" if $!;
   die "$path did not return a problem\n";
}
return $problem;
