#!/usr/bin/perl
# This file is covered under CC0-1.0. See libraries/LICENSE.txt.
# Search cycle-exact 6502/TIA kernel schedules described by a Perl data file.
#
# This is deliberately a small scheduling engine rather than a renderer-specific
# script.  The input file supplies both the high-level meaning of each operation
# and the exact assembly template/cycle count which realizes it.  The solver
# permutes ready operations, inserts idle cycles where necessary, and rejects a
# partial schedule as soon as an event window/deadline can no longer be met.
#
# INPUT
# -----
# The input file is evaluated with Perl's `do` and must return one hash reference:
#
# {
#   name        => 'short problem name',
#   description => 'what is being scheduled and why',
#   line_cycles => 76,             # defaults to 76
#   horizon     => 152,            # absolute CPU cycles searched
#   phase_origin=> 0,              # optional scanline phase of cycle zero
#   # Optional real CPU fillers.  When present, every scheduler-created idle
#   # gap must be exactly representable by these instruction blocks; this
#   # prevents fictitious one-cycle idle time from making a schedule look legal.
#   idle_fillers => [
#     { text=>'nop', cycles=>2 },
#     { text=>'nop.z harmless', cycles=>3 },
#   ],
#   operations  => [
#     {
#       id          => 'pf0_left', # unique [A-Za-z0-9_.-]+ name
#       description => 'write left PF0 for visible line 0',
#       # Use either one `asm` block ...
#       asm => [                    # assembly is documentation AND cycle source
#         [ 'lda stripe_pf0l', 3 ],
#         [ 'sta PF0',          3 ],
#       ],
#       # ... or multiple concrete implementations of the same semantic job:
#       implementations => [
#         { name=>'dynamic', asm=>[ ... ], events=>[ ... ] },
#         { name=>'cached',  asm=>[ ... ], events=>[ ... ] },
#       ],
#       after => [ 'something' ],  # optional operation dependencies
#       earliest => 0,              # optional absolute start-cycle floor
#       latest_end => 151,          # optional absolute finish-cycle ceiling
#       events => [                 # optional externally visible events
#         {
#           name    => 'PF0L write',
#           offset  => 5,           # event occurs start+offset, zero based
#           windows => [ [22,32] ], # inclusive absolute cycle windows
#         },
#       ],
#     },
#   ],
# };
#
# `asm` may also use hash entries:
#   { text => 'lda foo', cycles => 3 }
# which is useful when adding comments or generating input programmatically.
#
# `idle_fillers` is optional.  Without it the solver preserves the historical
# behavior and may leave arbitrary idle gaps.  With it, every gap between
# operations must be synthesizable from the listed fillers.  This is useful for
# 6502 kernels because there is no one-cycle NOP.  A 2-cycle NOP plus a 3-cycle
# NOP-like filler can synthesize every gap except one cycle.  Timing adjustments
# caused by otherwise-equivalent addressing modes (for example LDA/STA absolute
# taking one cycle longer than zero page) should be represented as operation
# implementations, because they also affect registers/memory semantics.
#
# `phase_origin` changes only printed line:cycle coordinates.  It is useful for
# periodic schedules whose natural epoch starts part-way through a scanline.
# For example phase_origin=>2 makes absolute scheduler cycle zero print as 0:02;
# cycle 74 then prints as 1:00.  Event windows and operation limits remain in
# absolute scheduler cycles and are not shifted.
#
# Event windows are absolute within `horizon`.  For a 76-cycle scanline pair,
# cycle 0..75 is line 0 and 76..151 is line 1.  Thus a write legal at cycles
# 20..30 of the second line uses [96,106].  A longer horizon can model multiple
# pairs.  This is intentional: work done near cycle 145 can prepare values used
# by the *next* pair, and dependencies can express that relationship directly.
#
# An operation is a semantic job.  Each concrete implementation is an
# indivisible block. Put register-sensitive instruction sequences that must stay
# together in one implementation. The search tries every implementation as well
# as every legal ordering/placement. Split freely movable work
# (for example six independent ROM->RAM staging copies) into separate blocks so
# the solver can interleave them with beam-critical writes.
#
# OUTPUT
# ------
# For every reported solution the script prints:
#   * absolute start/end cycle and line:cycle coordinates for each operation;
#   * the high-level description;
#   * every assembly instruction with its individual cycle cost;
#   * named event coordinates;
#   * idle gaps inserted by the scheduler.
#
# By default the first legal solution is printed.  `--max-solutions N` prints up
# to N solutions.  `--all` exhaustively enumerates every legal schedule.  If no
# schedule exists, exit status is 1 and pruning/search statistics are printed.
# Invalid input is exit status 2.
#
# This solver does NOT currently model page-cross penalties, branch taken/not
# taken alternatives, or register liveness inside an operation.  Put each
# concrete alternative in its own operation/template (or separate input file)
# with its real cycle count.  Keeping those choices explicit makes the result
# auditable against the generated assembly.

use strict;
use warnings;
use Getopt::Long qw(GetOptions);
use File::Basename qw(dirname);
use File::Spec;
use Cwd qw(abs_path);

my $max_solutions = 1;
my $all = 0;
my $help = 0;
GetOptions(
   'max-solutions=i' => \$max_solutions,
   'all'             => \$all,
   'help|h'          => \$help,
) or usage(2);
usage(0) if $help;
usage(2) unless @ARGV == 1;
$max_solutions >= 1 or die "--max-solutions must be >= 1\n";
$max_solutions = 0 if $all; # zero means unlimited

my $input_path = abs_path($ARGV[0]);
defined $input_path or die "cannot resolve $ARGV[0]\n";
my $problem = do $input_path;
if (!defined $problem) {
   die $@ if $@;
   die "cannot read $input_path: $!\n" if $!;
   die "$input_path did not return a value\n";
}
ref($problem) eq 'HASH' or die "$input_path must return a hash reference\n";

my $line_cycles = $problem->{line_cycles} // 76;
my $phase_origin = $problem->{phase_origin} // 0;
my $horizon = $problem->{horizon};
my $ops_in = $problem->{operations};
my $idle_fillers_in = $problem->{idle_fillers};
$line_cycles =~ /^\d+$/ && $line_cycles > 0
   or die "line_cycles must be a positive integer\n";
$phase_origin =~ /^\d+$/ && $phase_origin < $line_cycles
   or die "phase_origin must be an integer in 0..".($line_cycles-1)."\n";
$horizon =~ /^\d+$/ && $horizon > 0
   or die "horizon must be a positive integer\n";
ref($ops_in) eq 'ARRAY' && @$ops_in
   or die "operations must be a non-empty array\n";

my @idle_fillers;
if (defined $idle_fillers_in) {
   ref($idle_fillers_in) eq 'ARRAY' && @$idle_fillers_in
      or die "idle_fillers must be a non-empty array\n";
   for my $f (@$idle_fillers_in) {
      ref($f) eq 'HASH' or die "idle filler must be a hash\n";
      my $text=$f->{text};
      my $cycles=$f->{cycles};
      defined($text) && length($text) or die "idle filler text is empty\n";
      defined($cycles) && $cycles =~ /^\d+$/ && $cycles > 0
         or die "idle filler '$text' has invalid cycles\n";
      push @idle_fillers,{text=>$text,cycles=>0+$cycles};
   }
}

# Return one concrete filler sequence for GAP cycles, or undef when a real CPU
# cannot synthesize that idle period from the problem's allowed fillers.
# Empty gaps are always legal.  Inputs without idle_fillers retain unrestricted
# historical behavior for compatibility with older search problems.
my %idle_plan_cache=(0=>[]);
sub idle_plan {
   my($gap)=@_;
   return [] if $gap==0;
   return [ {text=>'IDLE',cycles=>$gap} ] unless @idle_fillers;
   return $idle_plan_cache{$gap} if exists $idle_plan_cache{$gap};
   my @plan;
   for my $n (1..$gap) {
      next if exists $idle_plan_cache{$n};
      FILL: for my $f (@idle_fillers) {
         my $prev=$n-$f->{cycles};
         next if $prev < 0 || !exists $idle_plan_cache{$prev};
         my $pp=$idle_plan_cache{$prev};
         $idle_plan_cache{$n}=[ @$pp, $f ];
         last FILL;
      }
   }
   return $idle_plan_cache{$gap};
}

my @ops;
my %index;
for my $src (@$ops_in) {
   ref($src) eq 'HASH' or die "each operation must be a hash reference\n";
   my $id = $src->{id} // '';
   $id =~ /^[A-Za-z0-9_.-]+$/ or die "invalid operation id '$id'\n";
   exists $index{$id} and die "duplicate operation id '$id'\n";
   my @impl_src;
   if (exists $src->{implementations}) {
      ref($src->{implementations}) eq 'ARRAY' && @{$src->{implementations}}
         or die "$id: implementations must be a non-empty array\n";
      exists $src->{asm} and die "$id: use asm or implementations, not both\n";
      @impl_src=@{$src->{implementations}};
   } else {
      exists $src->{asm} or die "$id: requires asm or implementations\n";
      @impl_src=({ name=>'default', asm=>$src->{asm}, (exists($src->{events}) ? (events=>$src->{events}) : ()) });
   }
   my @impl;
   for my $is (@impl_src) {
      ref($is) eq 'HASH' or die "$id: implementation must be a hash\n";
      my $iname=$is->{name} // 'default';
      $iname =~ /^[A-Za-z0-9_.-]+$/ or die "$id: invalid implementation name '$iname'\n";
      my $asm=$is->{asm};
      ref($asm) eq 'ARRAY' && @$asm or die "$id/$iname: asm must be a non-empty array\n";
      my @insn;
      my $cycles=0;
      for my $a (@$asm) {
         my ($text,$n);
         if (ref($a) eq 'ARRAY') { ($text,$n)=@$a; }
         elsif (ref($a) eq 'HASH') { ($text,$n)=@$a{qw(text cycles)}; }
         else { die "$id/$iname: asm entry must be [text,cycles] or a hash\n"; }
         defined($text) && length($text) or die "$id/$iname: asm text is empty\n";
         defined($n) && $n =~ /^\d+$/ && $n > 0 or die "$id/$iname: bad cycle count for '$text'\n";
         push @insn,{text=>$text,cycles=>0+$n};
         $cycles+=$n;
      }
      my $events = (exists($is->{events}) && defined($is->{events})) ? $is->{events} : ($src->{events}//[]);
      ref($events) eq 'ARRAY' or die "$id/$iname: events must be an array\n";
      my @events;
      for my $e (@$events) {
         ref($e) eq 'HASH' or die "$id/$iname: event must be a hash\n";
         my $name=$e->{name}//'event';
         my $offset=$e->{offset};
         defined($offset) && $offset =~ /^\d+$/ && $offset < $cycles
            or die "$id/$iname/$name: offset must be within operation (0..".($cycles-1).")\n";
         my $windows=$e->{windows};
         ref($windows) eq 'ARRAY' && @$windows
            or die "$id/$iname/$name: windows must be a non-empty array\n";
         my @w;
         for my $r (@$windows) {
            ref($r) eq 'ARRAY' && @$r == 2 or die "$id/$iname/$name: window must be [first,last]\n";
            my($a,$b)=@$r;
            defined($a) && defined($b) && $a =~ /^\d+$/ && $b =~ /^\d+$/ && $a <= $b && $b < $horizon
               or die "$id/$iname/$name: invalid window [$a,$b] for horizon $horizon\n";
            push @w,[0+$a,0+$b];
         }
         push @events,{name=>$name,offset=>0+$offset,windows=>\@w};
      }
      push @impl,{name=>$iname,asm=>\@insn,cycles=>$cycles,events=>\@events};
   }
   my $after = $src->{after} // [];
   ref($after) eq 'ARRAY' or die "$id: after must be an array\n";
   my $earliest = $src->{earliest} // 0;
   my $latest_end = $src->{latest_end} // ($horizon-1);
   $earliest =~ /^\d+$/ && $earliest < $horizon or die "$id: bad earliest\n";
   $latest_end =~ /^\d+$/ && $latest_end < $horizon or die "$id: bad latest_end\n";
   for my $imp (@impl) {
      $earliest + $imp->{cycles} - 1 <= $latest_end
         or die "$id/$imp->{name}: operation cannot fit between earliest/latest_end\n";
   }
   $index{$id}=scalar @ops;
   push @ops, {
      id=>$id,
      description=>$src->{description} // '',
      implementations=>\@impl,
      after_ids=>[ @$after ],
      earliest=>0+$earliest,
      latest_end=>0+$latest_end,
   };
}

@ops <= 63 or die "at most 63 operations are supported by the bitmask search\n";
for my $op (@ops) {
   my $mask=0;
   for my $dep (@{$op->{after_ids}}) {
      exists $index{$dep} or die "$op->{id}: unknown dependency '$dep'\n";
      $dep ne $op->{id} or die "$op->{id}: operation cannot depend on itself\n";
      $mask |= (1 << $index{$dep});
   }
   $op->{after_mask}=$mask;
}

# Detect dependency cycles before search.
my @mark=(0)x@ops;
sub visit_dep {
   my($i)=@_;
   die "dependency cycle involving $ops[$i]{id}\n" if $mark[$i]==1;
   return if $mark[$i]==2;
   $mark[$i]=1;
   for my $j (0..$#ops) {
      visit_dep($j) if $ops[$i]{after_mask} & (1 << $j);
   }
   $mark[$i]=2;
}
visit_dep($_) for 0..$#ops;

my $all_mask = @ops == 63 ? ~0 : ((1 << @ops)-1);
my $solutions=0;
my $visited=0;
my $pruned_deadline=0;
my $pruned_horizon=0;
my %memo;

sub coord {
   my($c)=@_;
   my $p=$c+$phase_origin;
   return sprintf('%d:%02d', int($p/$line_cycles), $p % $line_cycles);
}

sub event_fits {
   my($imp,$start)=@_;
   for my $e (@{$imp->{events}}) {
      my $t=$start+$e->{offset};
      my $ok=0;
      for my $w (@{$e->{windows}}) {
         if ($t >= $w->[0] && $t <= $w->[1]) { $ok=1; last; }
      }
      return 0 unless $ok;
   }
   return 1;
}

sub candidate_starts {
   my($op,$imp,$time)=@_;
   my $first=$time > $op->{earliest} ? $time : $op->{earliest};
   my $last=$op->{latest_end}-$imp->{cycles}+1;
   $last=$horizon-$imp->{cycles} if $last > $horizon-$imp->{cycles};
   return () if $first > $last;
   my @s;
   for my $start ($first..$last) {
      next unless idle_plan($start-$time);
      push @s,$start if event_fits($imp,$start);
   }
   return @s;
}

sub impossible_remaining {
   my($mask,$time)=@_;
   for my $i (0..$#ops) {
      next if $mask & (1 << $i);
      my $op=$ops[$i];
      my $first=$time > $op->{earliest} ? $time : $op->{earliest};
      my $one_impl_reachable=0;
      IMP: for my $imp (@{$op->{implementations}}) {
         next if $first+$imp->{cycles}-1 > $op->{latest_end} || $first+$imp->{cycles} > $horizon;
         for my $e (@{$imp->{events}}) {
            my $reachable=0;
            for my $w (@{$e->{windows}}) {
               my $lo=$first+$e->{offset};
               my $hi=($op->{latest_end}-$imp->{cycles}+1)+$e->{offset};
               if ($hi >= $w->[0] && $lo <= $w->[1]) { $reachable=1; last; }
            }
            next IMP unless $reachable;
         }
         $one_impl_reachable=1;
         last;
      }
      unless ($one_impl_reachable) { ++$pruned_deadline; return 1; }
   }
   return 0;
}

sub print_solution {
   my($sched)=@_;
   print "solution ",($solutions+1)," for ",($problem->{name}//$input_path),"\n";
   print(($problem->{description}//''), "\n") if length($problem->{description}//'');
   print "line_cycles=$line_cycles horizon=$horizon phase_origin=$phase_origin\n";
   my $cursor=0;
   for my $p (@$sched) {
      my($i,$impi,$start)=@$p;
      my $op=$ops[$i];
      my $imp=$op->{implementations}[$impi];
      if ($start>$cursor) {
         my $gap=$start-$cursor;
         my $plan=idle_plan($gap);
         printf "  %3d..%3d  %s..%s  IDLE %d cycles",
            $cursor,$start-1,coord($cursor),coord($start-1),$gap;
         if (@idle_fillers && $plan) {
            print " (",join(' + ',map { $_->{text}."/".$_->{cycles} } @$plan),")";
         }
         print "\n";
      }
      my $end=$start+$imp->{cycles}-1;
      printf "  %3d..%3d  %s..%s  %-20s %s\n",
         $start,$end,coord($start),coord($end),$op->{id}.($imp->{name} eq 'default'?'':"[$imp->{name}]"),$op->{description};
      my $c=$start;
      for my $a (@{$imp->{asm}}) {
         my $ie=$c+$a->{cycles}-1;
         printf "      %s..%s  +%-2d  %s\n",coord($c),coord($ie),$a->{cycles},$a->{text};
         $c += $a->{cycles};
      }
      for my $e (@{$imp->{events}}) {
         my $t=$start+$e->{offset};
         printf "      event %-18s @ %3d (%s)\n",$e->{name},$t,coord($t);
      }
      $cursor=$end+1;
   }
   if ($cursor<$horizon) {
      my $gap=$horizon-$cursor;
      my $plan=idle_plan($gap);
      printf "  %3d..%3d  %s..%s  IDLE %d cycles",
         $cursor,$horizon-1,coord($cursor),coord($horizon-1),$gap;
      if (@idle_fillers && $plan) {
         print " (",join(' + ',map { $_->{text}."/".$_->{cycles} } @$plan),")";
      }
      print "\n";
   }
   print "\n";
}

sub search {
   my($mask,$time,$sched)=@_;
   return if $max_solutions && $solutions >= $max_solutions;
   ++$visited;
   if ($mask == $all_mask) {
      print_solution($sched);
      ++$solutions;
      return;
   }
   return if impossible_remaining($mask,$time);

   # Memoization is safe for a first-solution search because future feasibility
   # depends only on completed operations and current cycle.  Do not memoize an
   # exhaustive run: distinct prefixes are distinct schedules worth printing.
   if (!$all && $max_solutions == 1) {
      my $key="$mask:$time";
      return if $memo{$key}++;
   }

   my @ready;
   for my $i (0..$#ops) {
      next if $mask & (1 << $i);
      my $dep=$ops[$i]{after_mask};
      push @ready,$i if (($mask & $dep) == $dep);
   }
   # Earliest-deadline-first generally collapses the beam-critical search tree.
   @ready=sort {
      $ops[$a]{latest_end} <=> $ops[$b]{latest_end}
      || $ops[$a]{id} cmp $ops[$b]{id}
   } @ready;

   for my $i (@ready) {
      my $op=$ops[$i];
      for my $impi (0..$#{$op->{implementations}}) {
         my $imp=$op->{implementations}[$impi];
         my @starts=candidate_starts($op,$imp,$time);
         next unless @starts;
         for my $start (@starts) {
            my $next=$start+$imp->{cycles};
            if ($next>$horizon) { ++$pruned_horizon; next; }
            push @$sched,[$i,$impi,$start];
            search($mask | (1 << $i),$next,$sched);
            pop @$sched;
            return if $max_solutions && $solutions >= $max_solutions;
         }
      }
   }
}

search(0,0,[]);
printf STDERR "searched=%d pruned_deadline=%d pruned_horizon=%d solutions=%d\n",
   $visited,$pruned_deadline,$pruned_horizon,$solutions;
exit($solutions ? 0 : 1);

sub usage {
   my($rc)=@_;
   print STDERR "usage: $0 [--max-solutions N | --all] PROBLEM.pl\n";
   print STDERR "       $0 --help\n";
   exit $rc;
}
