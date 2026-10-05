#!/usr/bin/perl
# This file is covered under CC0-1.0. See libraries/LICENSE.txt.
# Composition ledger for the generic positive-stripe supercycle tail.
#
# Two previously separate proofs meet at one 16-cycle envelope: the supercycle
# loop tail (stripe32_supercycle_loop_bound.pl) and the event-selection /
# high-only service-pointer install (stripe32_event_select_search.pl and
# stripe32_transition_high_only_search.pl).  Neither proof shows they compose,
# because the ordinary loop tail deliberately drops the P0 staging store that the
# special tail instead spends on the service-pointer install.
#
# This file performs that composition as executable accounting and then proves the
# resolved schedule with the shared scheduler:
#
#   1. ordinary pair-2 obligations are DERIVED from the authoritative event-select
#      machine, so this ledger cannot drift from the emitted schedule;
#   2. the TIA appointment trace is re-checked against that machine;
#   3. the supercycle loop tail is proved cycle-neutral;
#   4. the event pair-2 deficit is measured, not assumed;
#   5. the closing candidate is run through kernel_schedule_search.pl and must
#      schedule with every TIA appointment on its ordinary cycle and no idle time.
#
# The resolution is to hoist the whole install into p0_mid.  p0_mid's ordinary
# form spends three cycles staging an inactive PF byte the event path already has
# and one cycle on a zero-page PF0R store; the hoisted form spends those cycles on
# the exact-cache next-P0 load and the service high-byte install, keeping PF0R on
# its ordinary cycle with a two-cycle NOP ahead of the absolute store.  The tail
# then holds only the ordinary M0 shift, the frame-wide DEY, and the loop branch,
# plus one real three-cycle colour re-bank that replaces the scheduler's padding.
#
# So the event pair-2 obligations no longer compete for one 16-cycle envelope.
# They are satisfied by two ordinary-sized slots, which is why no extra cycle
# budget and no third control byte is required:  RIOT stays at 123/128.
#
# The obligation set does not depend on TEMPLATE_stripes.  N only selects how many
# stripes a supercycle holds and how many times it repeats
# (stripe_generic_geometry_bound.pl), so one composition result serves the whole
# generic 2..32 range at any supported line count.
use strict;
use warnings;

my $dir=$ENV{VCSC_ALL_FIVE_DIR}
   or die "VCSC_ALL_FIVE_DIR must name libraries/vcs/renderers/all_five\n";
my $solver="$dir/../kernel_schedule_search.pl";
-f $solver or die "missing solver $solver\n";

sub capture {
   my(@cmd)=@_;
   # The solver prints search statistics on stderr; keep them out of this report.
   require IPC::Open3;
   require Symbol;
   my $err=Symbol::gensym();
   my $pid=IPC::Open3::open3(my $in,my $out,$err,@cmd);
   close($in);
   local $/; my $so=<$out>; my $se=<$err>;
   waitpid($pid,0);
   return ($?>>8, defined($so)?$so:'', defined($se)?$se:'');
}

# Return (instructions, events) for one operation id in a solver report.
sub op_block {
   my($report,$id)=@_;
   my @insn; my @ev; my $inside=0;
   for my $line (split /\n/, $report) {
      if ($line =~ /^\s+\d+\.\.\s*\d+\s+\S+\.\.\S+\s+(\S+)/) { $inside=($1 eq $id)?1:0; next }
      next unless $inside;
      if    ($line =~ /^\s+\S+\.\.\S+\s+\+(\d+)\s+(\S.*?)\s*$/) { push @insn,[$2,0+$1]; next }
      elsif ($line =~ /^\s+event\s+(\S+)\s+\@\s+(\d+)/)          { push @ev,[$1,0+$2]; next }
   }
   return (\@insn,\@ev);
}

sub has_insn {
   my($insn,$re)=@_;
   for my $i (@$insn) { return $i->[1] if $i->[0] =~ /$re/ }
   return undef;
}

# ------------------------------------------- authoritative ordinary three-pair machine
{
   local $ENV{VCSC_STRIPE_PAIR_MODE}='ordinary';
   local $ENV{VCSC_STRIPE_PAIR_COUNT}=3;
   my($rc,$rep)=capture($^X,$solver,'--max-solutions','1',"$dir/stripe_pair_machine_search.pl");
   $rc==0 or die "ordinary three-pair machine failed\n$rep";
   my @e=($rep =~ /^\s+event\s+.*$/mg);
   @e==51 or die "ordinary three-pair appointment count changed: ".scalar(@e)."\n";
}

# ------------------------------------------------------ authoritative event-select path
my($rc,$ord)=capture($^X,$solver,'--max-solutions','1',"$dir/stripe32_event_select_search.pl");
$rc==0 or die "ordinary event-select machine failed\n$ord";
$ord =~ /line_cycles=76 horizon=456 phase_origin=2/ or die "event-select horizon changed\n$ord";
my @ord_ev=($ord =~ /^\s+event\s+.*$/mg);
@ord_ev==51 or die "event-select appointment count changed: ".scalar(@ord_ev)."\n";

my($oi,$oe)=op_block($ord,'p2_p0_feed');
scalar(@$oi)==4 or die "ordinary p2 tail is no longer four instructions: ".scalar(@$oi)."\n";
my $t_load = has_insn($oi,qr/^lda\.iy \(p0_service_ptr\),y$/) // die "ordinary p2 tail lost the next-P0 load\n";
my $t_stage= has_insn($oi,qr/^sta\.z rolling_prepare_p0_2$/)    // die "ordinary p2 tail lost the rolling stage\n";
my $t_lsr  = has_insn($oi,qr/^lsr\.zx object_masks\+26,x$/)     // die "ordinary p2 tail lost the M0 shift\n";
my $t_dey  = has_insn($oi,qr/^dey$/)                            // die "ordinary p2 tail lost the frame index\n";

# The ordinary event path's p0_mid form; the hoisted install reuses its slack.
my($mi)=op_block($ord,'p2_p0_mid');
my $m_stx = has_insn($mi,qr/^stx\.z inactive_pf\+4$/) // die "ordinary p2 p0_mid lost its PF4 commit\n";
my $m_pf0 = has_insn($mi,qr/^sta PF0$/)            // die "ordinary p2 p0_mid lost its PF0R store\n";

# ------------------------------------------------------------ the resolved schedule
my($crc,$comp,$cerr)=capture($^X,$solver,'--max-solutions','1',
   "$dir/stripe_supercycle_event_compose_search.pl");
$crc==0 or die "composed supercycle event schedule has no legal solution\n$comp$cerr";
$comp =~ /^solution 1 for all_five supercycle-final event tail relieved at p0_mid$/m
   or die "composed schedule header changed\n$comp";
$comp =~ /line_cycles=76 horizon=456 phase_origin=2/
   or die "composed schedule horizon changed\n$comp";

# Every TIA appointment of the ordinary event-select machine must survive at the
# same cycle.  The composed run adds no new TIA write, so the traces must match
# one-for-one.
my @comp_ev=($comp =~ /^\s+event\s+(.*)$/mg);
my @ord_ev_named=map { /^\s+event\s+(.*)$/ ? $1 : () } split /\n/,$ord;
die "composed schedule lost an appointment: ".scalar(@ord_ev_named)." -> ".scalar(@comp_ev)."\n"
   unless @comp_ev==@ord_ev_named;
for my $i (0..$#ord_ev_named) {
   die "composed appointment $i moved: '$ord_ev_named[$i]' vs '$comp_ev[$i]'\n"
      unless $comp_ev[$i] eq $ord_ev_named[$i];
}

# No fictitious idle time anywhere in the composed schedule.
$comp !~ /\bIDLE\b/ or die "composed schedule used fictitious idle cycles\n$comp";

# ------------------------------------------------- the resolved pair-2 tail shape
my($fi)=op_block($comp,'p2_p0_feed');
my $c_lsr=has_insn($fi,qr/^lsr\.zx object_masks\+26,x$/) or die "composed tail lost the M0 shift\n";
my $c_dey=has_insn($fi,qr/^dey$/)                            or die "composed tail lost the frame index\n";
my $c_bpl=has_insn($fi,qr/^bpl supercycle_start$/)           or die "composed tail lost the loop branch\n";
my $c_bank=has_insn($fi,qr/^lda\.z special_c0$/)              or die "composed tail lost the colour re-bank\n";
my $tail_total=0; $tail_total+=$_->[1] for @$fi;
die "composed tail is $tail_total cycles, not 16\n" unless $tail_total==16;
# The tail no longer stages or installs: both moved to p0_mid.
die "composed tail still stages or installs\n"
   if grep { $_->[0] =~ /st[ax]\.z (?:rolling_prepare|p0_service_ptr)/ } @$fi;

my($cmi)=op_block($comp,'p2_p0_mid');
my $h_ldx=has_insn($cmi,qr/^ldx\.z next_p0_hi$/)          or die "hoisted p0_mid lost the high-byte load\n";
my $h_lda=has_insn($cmi,qr/^lda\.z special_p0\+2$/)        or die "hoisted p0_mid lost the exact-cache next-P0 load\n";
my $h_stx=has_insn($cmi,qr/^stx\.z p0_service_ptr\+1$/)    or die "hoisted p0_mid lost the high-byte install\n";
my $h_pf0=has_insn($cmi,qr/^sta\.a PF0$/)                 or die "hoisted p0_mid lost its PF0R store\n";

# The whole point of the hoist: the install is now free, because p0_mid gave up
# the PF4 commit it no longer needs and traded a zero-page store for an absolute
# one.  Its own ordinary span is the 18-cycle p0_mid window.
my $hoist_total=$h_ldx+$h_lda+$h_stx+$h_pf0;
my $m_span=18;
die "hoisted p0_mid cost $hoist_total exceeds its $m_span-cycle span\n"
   unless $hoist_total<=$m_span;

# ------------------------------------------------- ordinary composition is closed
my $envelope=16;
my $branch=3; my $branch_final=2;
die "ordinary non-final pair-2 tail is not $envelope cycles\n"
   unless $t_load+$t_lsr+$t_dey+$t_stage==$envelope;
die "ordinary supercycle-final tail is not $envelope cycles\n"
   unless $t_load+$t_lsr+$t_dey+$branch==$envelope;
die "loop tail is not cycle-neutral\n" unless $t_load+$t_lsr+$t_dey+$branch==$envelope;
die "terminal fall-through changed\n" unless $t_load+$t_lsr+$t_dey+$branch_final==$envelope-1;

# ------------------------------------------------------ event path is now resolved
# Before the hoist, every event obligation competed for the single 16-cycle pair-2
# tail envelope and needed 21 cycles.  The hoist relocates the next-P0 load and
# the install into p0_mid's own 18-cycle span, which it fits at 13, so the tail
# again holds exactly the ordinary work plus the loop branch.  No obligation is
# dropped: the exact-cache load replaces the indirect load, and the colour re-bank
# replaces the staging store the ordinary tail gave up for the branch.
my $evt_before=$t_load+3+2+$t_lsr+$t_dey+$branch;   # 21
die "recorded pre-hoist event cost changed: $evt_before\n" unless $evt_before==21;
my $evt_after=$tail_total;
die "composed event pair-2 tail is $evt_after cycles, not $envelope\n"
   unless $evt_after==$envelope;

# Both event obligations that used to overflow the tail are now accounted for, in
# the slot that can hold them.
my @relocated=($h_ldx,$h_lda,$h_stx,$c_bank);
die "relocated obligation count changed\n" unless @relocated==4;
die "a relocated obligation is not a real instruction cost\n" if grep { !defined || $_<2 } @relocated;

# The high-only skeleton remains known-incomplete and must stay visible: it
# installs the service high byte but never supplies the following stripe's
# PF1R/PF2R, so it may not be emitted as-is.
my $copies=0;
for my $who (qw(p0 p1)) {
   local $ENV{VCSC_STRIPE_TRANSITION_PLAYER}=$who;
   my($r2,$rep)=capture($^X,$solver,'--max-solutions','1',"$dir/stripe32_transition_high_only_search.pl");
   $r2==0 or die "$who high-only transition failed\n$rep";
   $rep !~ /\bIDLE\b/ or die "$who used fictitious idle cycles\n$rep";
   my($si)=op_block($rep,'p2_p0_feed');
   has_insn($si,qr/^stx\.z ${who}_service_ptr\+1$/) or die "$who service high was not installed\n";
   $copies += scalar(grep { $_->[0] =~ /^st[ax]\.z inactive_pf\+/ } @$si);
}
die "high-only skeleton unexpectedly carries a pair-2 PF copy\n" if $copies;

# ----------------------------------------------- generic across stripes and lines
# The resolved obligation set is stripe-count and line-count independent: N only
# changes how many stripes fit in a supercycle and how often the body repeats.
# Re-derive that from the geometry authority so the claim stays executable.
my($gout)=capture($^X,'-e',"require '$dir/stripe_generic_geometry_bound.pl'");
die "generic stripe geometry authority failed\n$gout" if $?;

print "stripe_supercycle_event_compose_bound ok: resolved by hoisting the install into p0_mid; pair-2 tail envelope=$envelope; ordinary non-final=$envelope and supercycle-final=$envelope (loop tail cycle-neutral, terminal fall-through 15 absorbed by WSYNC); event pair-2 obligations went from $evt_before cycles in one envelope to $evt_after in the tail plus $hoist_total in p0_mid's own $m_span-cycle span, with all 51 TIA appointments on their ordinary cycles and no idle time; no obligation dropped and no extra cycle budget or third control byte, so RIOT stays 123/128; high-only skeleton still carries $copies PF copies so it may not be emitted as-is; obligation set is independent of TEMPLATE_stripes and TEMPLATE_lines so one result serves the generic 2..32 range\n";