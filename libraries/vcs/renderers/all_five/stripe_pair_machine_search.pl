# This file is covered under CC0-1.0. See libraries/LICENSE.txt.
# Authoritative periodic all_five stripes=2 visible-machine schedule.
#
# One pair is exactly 152 CPU cycles.  Its epoch begins at physical scanline A
# cycle 2, where STA GRP0 starts, and ends after cycle 1 of the following A
# line.  phase_origin=>2 therefore prints physical scanline coordinates while
# the search uses a simple 0..151 periodic interval.
#
# This file is the single source of truth for that repeating cadence.  Fixed TIA
# appointments are shared by all modes.  Player/refill work is interchangeable
# feed work occupying the same slots; it is not allowed to create a differently
# timed service row.
#
# Environment:
#   VCSC_STRIPE_PAIR_MODE=ordinary  dynamic player production (default)
#   VCSC_STRIPE_PAIR_MODE=refill    cached players + double-buffer refill
#   VCSC_STRIPE_PAIR_MODE=rowedge   cached next-row P0 pays the row backedge
#   VCSC_STRIPE_PAIR_MODE=either    solver may choose ordinary/refill (one pair only)
#   VCSC_STRIPE_PAIR_COUNT=N        compose N exact 152-cycle pairs (default 1)
#
# Refill mode is currently defined for one or three pairs.  It models the
# production-oriented exact-cache service: VBLANK prepares the three P1/P0
# graphics bytes, so the visible service spends no cycles on activity tests.
# P1 carries PF bytes 0/2/4 in X while copying colors 0/1; P0 stages bytes
# 1/3/5, commits X, loads its exact cached sprite byte, restores the row X,
# and closes on the same pair boundary.

use strict;
use warnings;

my $mode=$ENV{VCSC_STRIPE_PAIR_MODE} // 'ordinary';
$mode =~ /^(?:ordinary|refill|rowedge|either)$/
   or die "VCSC_STRIPE_PAIR_MODE must be ordinary, refill, rowedge, or either\n";
my $count=$ENV{VCSC_STRIPE_PAIR_COUNT} // 1;
$count =~ /^\d+$/ && $count >= 1 && $count <= 16
   or die "VCSC_STRIPE_PAIR_COUNT must be 1..16\n";
$mode ne 'either' || $count==1
   or die "VCSC_STRIPE_PAIR_MODE=either is supported only for one pair\n";
$mode ne 'refill' || $count==1 || $count==3
   or die "refill mode is currently defined for one or three pairs\n";

sub selected_impls {
   my($ordinary,$refill)=@_;
   return [$ordinary] if $mode eq 'ordinary' || $mode eq 'rowedge';
   return [$refill] if $mode eq 'refill';
   return [$ordinary,$refill];
}

my @refill_even_pf=(0,2,4);
my @refill_odd_pf=(1,3,5);
my @refill_color=(0,1,undef);
my @ops;

for my $p (0..$count-1) {
   my $b=$p*152;
   my $tag=$count==1 ? '' : "p${p}_";
   my $prev=$p ? (($count==1?'':"p".($p-1)."_").'p0_feed') : undef;

   push @ops, {
      id=>$tag.'a_visible',
      description=>"pair $p scanline A fixed TIA cadence and Ball/P1 bookkeeping",
      after=>defined($prev)?[$prev]:[], earliest=>$b, latest_end=>$b+59,
      asm=>[
         ['sta GRP0',3],
         ['lda.z stripe_cache+0',3], ['adc #0',2], ['sta ENAM0',3], ['sta PF0',3],
         ['ldy.z stripe_cache+1',3], ['sty PF1',3],
         ['ldy.z stripe_cache+2',3], ['sty PF2',3],
         ['lsr.zx object_masks+24,x',6],
         ['lda.z stripe_cache+3',3], ['adc #0',2], ['sta ENABL',3],
         ['dec.z player1_y',5], ['sta PF0',3],
         ['ldy.z stripe_cache+4',3], ['sty PF1',3],
         ['ldy.z stripe_cache+5',3], ['sty PF2',3],
      ],
      events=>[
         {name=>'GRP0', offset=>2, windows=>[[$b+2,$b+2]]},
         {name=>'ENAM0',offset=>10,windows=>[[$b+10,$b+10]]},
         {name=>'PF0L', offset=>13,windows=>[[$b+13,$b+13]]},
         {name=>'PF1L', offset=>19,windows=>[[$b+19,$b+19]]},
         {name=>'PF2L', offset=>25,windows=>[[$b+25,$b+25]]},
         {name=>'ENABL',offset=>39,windows=>[[$b+39,$b+39]]},
         {name=>'PF0R', offset=>47,windows=>[[$b+47,$b+47]]},
         {name=>'PF1R', offset=>53,windows=>[[$b+53,$b+53]]},
         {name=>'PF2R', offset=>59,windows=>[[$b+59,$b+59]]},
      ],
   };

   my $p1_ordinary={
      name=>'ordinary_dynamic',
      asm=>[
         ['ldy.z player1_y',3], ['cpy.z object_masks+15',3],
         ['bcc.same activeP1',3], ['lda.iy (player1_graphics),y',5],
         ['lsr.zx object_masks+25,x',6], ['sta GRP1',3],
      ],
      events=>[{name=>'GRP1',offset=>22,windows=>[[$b+82,$b+82]]}],
   };
   my $even_pf=$count==1 ? 0 : $refill_even_pf[$p];
   my $color=$count==1 ? 0 : $refill_color[$p];
   my @p1_refill_asm=(
      ["lda.z p1_service_byte+$p",3],
      ["ldx.a next_stripe_pf+$even_pf",4],
   );
   if (defined $color) {
      push @p1_refill_asm,
         ["ldy.a next_stripe_color+$color",4],
         ["sty.z next_color_slot+$color",3];
   } else {
      push @p1_refill_asm,
         ['bit.a timing_scratch',4],
         ['bit.z timing_scratch',3];
   }
   push @p1_refill_asm,
      ['lsr.a object_masks_service_m1',6], ['sta GRP1',3];
   my $p1_refill={
      name=>defined($color) ? "refill_exact_pf${even_pf}_color$color" : "refill_exact_pf$even_pf",
      asm=>\@p1_refill_asm,
      events=>[{name=>'GRP1',offset=>22,windows=>[[$b+82,$b+82]]}],
   };
   push @ops, {
      id=>$tag.'p1_feed',
      description=>"pair $p fixed 23-cycle P1 feed slot",
      after=>[$tag.'a_visible'], earliest=>$b+60, latest_end=>$b+82,
      implementations=>selected_impls($p1_ordinary,$p1_refill),
   };

   push @ops, {
      id=>$tag.'b_left',
      description=>"pair $p scanline B fixed left-half TIA cadence",
      after=>[$tag.'p1_feed'], earliest=>$b+83, latest_end=>$b+105,
      asm=>[
         ['lda.z stripe_cache+0',3], ['adc #0',2], ['sta ENAM1',3], ['sta PF0',3],
         ['lda.z stripe_cache+1',3], ['sta PF1',3],
         ['lda.z stripe_cache+2',3], ['sta PF2',3],
      ],
      events=>[
         {name=>'ENAM1',offset=>7, windows=>[[$b+90,$b+90]]},
         {name=>'PF0L', offset=>10,windows=>[[$b+93,$b+93]]},
         {name=>'PF1L', offset=>16,windows=>[[$b+99,$b+99]]},
         {name=>'PF2L', offset=>22,windows=>[[$b+105,$b+105]]},
      ],
   };

   my $p0_mid_ordinary={
      name=>'ordinary_dynamic',
      asm=>[
         ['ldy.z player0_y',3], ['dey',2], ['cpy.z object_masks+11',3],
         ['sty.z player0_y',3], ['lda.z stripe_cache+3',3], ['sta.a PF0',4],
      ],
      events=>[{name=>'PF0R',offset=>17,windows=>[[$b+123,$b+123]]}],
   };
   my $odd_pf=$count==1 ? 1 : $refill_odd_pf[$p];
   my $p0_mid_refill={
      name=>"refill_exact_pf$odd_pf",
      asm=>[
         ['dec.z player0_y',5],
         ["lda.a next_stripe_pf+$odd_pf",4], ["sta.z inactive_pf+$odd_pf",3],
         ['lda.z stripe_cache+3',3], ['sta.z PF0',3],
      ],
      events=>[{name=>'PF0R',offset=>17,windows=>[[$b+123,$b+123]]}],
   };
   push @ops, {
      id=>$tag.'p0_mid',
      description=>"pair $p fixed 18-cycle P0 bookkeeping/feed slot ending at PF0R",
      after=>[$tag.'b_left'], earliest=>$b+106, latest_end=>$b+123,
      implementations=>selected_impls($p0_mid_ordinary,$p0_mid_refill),
   };

   push @ops, {
      id=>$tag.'b_right',
      description=>"pair $p scanline B fixed right PF1/PF2 cadence",
      after=>[$tag.'p0_mid'], earliest=>$b+124, latest_end=>$b+135,
      asm=>[
         ['lda.z stripe_cache+4',3], ['sta PF1',3],
         ['lda.z stripe_cache+5',3], ['sta PF2',3],
      ],
      events=>[
         {name=>'PF1R',offset=>5, windows=>[[$b+129,$b+129]]},
         {name=>'PF2R',offset=>11,windows=>[[$b+135,$b+135]]},
      ],
   };

   my $p0_ordinary={
      name=>'ordinary_dynamic',
      asm=>[
         ['bcc.same activeP0',3], ['lda.iy (player0_graphics),y',5],
         ['lsr.zx object_masks+26,x',6], ['nop',2],
      ],
   };
   my $p0_refill={
      name=>"refill_exact_commit_pf$even_pf",
      asm=>[
         ["stx.z inactive_pf+$even_pf",3],
         ["lda.z p0_service_byte+$p",3],
         ['lsr.z object_masks_service_m0',5],
         ['ldx #service_row_x',2],
         ['bit.z timing_scratch',3],
      ],
   };
   my $p0_rowedge={
      name=>'rowedge_cached_p0_backedge',
      asm=>[
         # X still selects the final packed-mask pair.  The row-entry P0 byte
         # for the following row was prepared during VBLANK.  A deliberate
         # taken page-cross branch is four cycles, making load+M0+INX+backedge
         # exactly the ordinary 16-cycle tail with A holding next GRP0.
         ['lda.zx next_row_p0_cache,x',4],
         ['lsr.zx object_masks+26,x',6],
         ['inx',2],
         ['bne.cross pair0',4],
      ],
   };
   my $p0_impls = $mode eq 'rowedge' ? [$p0_rowedge] : selected_impls($p0_ordinary,$p0_refill);
   push @ops, {
      id=>$tag.'p0_feed',
      description=>"pair $p fixed 16-cycle P0 feed/carry slot ending at next A cycle 1",
      after=>[$tag.'b_right'], earliest=>$b+136, latest_end=>$b+151,
      implementations=>$p0_impls,
   };
}

return {
   name=>"all_five authoritative ".($count*152)."-cycle machine [$mode]",
   description=>"$count periodic two-scanline renderer pair(s). TIA appointments are immutable; feed implementations may change only inside each fixed 152-cycle envelope.",
   line_cycles=>76,
   phase_origin=>2,
   horizon=>$count*152,
   idle_fillers=>[
      {text=>'nop',cycles=>2},
      {text=>'bit.z timing_scratch',cycles=>3},
   ],
   operations=>\@ops,
};
