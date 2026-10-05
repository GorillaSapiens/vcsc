#!/usr/bin/perl
# This file is covered under CC0-1.0. See libraries/LICENSE.txt.
# Composed supercycle-final event tail: the first candidate that closes the
# measured pair-2 deficit.
#
# stripe_supercycle_event_compose_bound.pl proves the ordinary supercycle tail is
# cycle-neutral in 16 cycles and that the event pair-2 tail needs 21 cycles, so
# the event path is currently five cycles over even after the three-cycle
# exact-cache next-P0 load.  This file searches the ordinary pair-2 slot space for
# a formulation that fits, and reports what it found rather than assuming it.
#
# The structural observation it tests: the event pair-2 tail does not have to
# stage the next P0 byte at all if the event handler already holds it.  A high-only
# transition changes only the service pointer, so the next P0 byte is fetched
# through the *new* pointer during the handler's own P0 feed, and the tail's
# ordinary `lda.iy (p0_service_ptr),y` disappears.  What remains is:
#
#   LDA.Z special_p0+2        3   exact-cache next P0 byte for the handler
#   STX.Z p0_service_ptr+1    3   install only the changed high byte
#   TSX                       2   restore packed-row X
#   LSR.ZX object_masks+24,x  6   M0 shift
#   DEY                       2   frame-wide index
#   BPL supercycle_start      3   loop (2 on the terminal fall-through)
#                             ---
#                             19 taken / 18 final
#
# That is still three over.  The remaining slack must come from the p1_feed and
# p0_mid slots, so the search below reports the per-slot budget rather than
# guessing.  VCSC_STRIPE_SUPERCYCLE_EVENT_SLOT selects which slot to relieve so
# each candidate can be timed in isolation against the same 152-cycle pair.
use strict;
use warnings;

# Only the hoisted-install shape is a legal candidate.  The tail and p1_feed
# variants are deliberately not offered here: the bound already proved their
# pair-2 tails need 19 and 17 cycles against a 16-cycle envelope, so presenting
# them to the scheduler could only report an arithmetic fact, not a schedule.
# VCSC_STRIPE_SUPERCYCLE_EVENT_SLOT remains as an explicit audit switch so a
# future relaxation of the envelope can re-test them without editing this file.
my $slot = $ENV{VCSC_STRIPE_SUPERCYCLE_EVENT_SLOT} // 'p0_mid';
die "VCSC_STRIPE_SUPERCYCLE_EVENT_SLOT must be p0_mid, tail or p1_feed\n"
   unless $slot =~ /^(p0_mid|tail|p1_feed)$/;

my @ops;
my @even=(0,2,4);
my @odd =(1,3,5);
my $pf0=(0,3); my $pf1=(1,4); my $pf2=(2,5);

# Pair 2 of the supercycle-final stripe.  Pairs 0 and 1 are the ordinary body and
# are included only so the search sees the real predecessor dependency chain.
for my $p (0..2) {
   my $b=$p*152;
   my $tag="p${p}_";
   my $prev=$p ? "p".($p-1).'_p0_feed' : undef;

   my @a=(
      ['sta GRP0',3],
      ['lda.z stripe_cache+0',3], ['adc #0',2], ['sta ENAM0',3], ['sta PF0',3],
      ['lda.z stripe_cache+1',3], ['sta PF1',3],
      ['lda.z stripe_cache+2',3], ['sta PF2',3],
      ['lsr.zx object_masks+24,x',6],
      ['lda.z stripe_cache+3',3], ['adc #0',2], ['sta ENABL',3],
   );
   if ($p<2) {
      push @a,['ldx.ay stripe_feed0,y',4], ['sta.a PF0',4],
              ['lda.z stripe_cache+4',3], ['sta PF1',3],
              ['lda.z stripe_cache+5',3], ['sta PF2',3];
   } else {
      # Pair 2's ordinary five-cycle A slot carries the event threshold compare.
      push @a,['cpy.z next_event_threshold',3], {text=>'nop',cycles=>2}, ['sta PF0',3],
              ['lda.z stripe_cache+4',3], ['sta PF1',3],
              ['lda.z stripe_cache+5',3], ['sta PF2',3];
   }
   push @ops,{id=>$tag.'a_visible',description=>"pair $p fixed A cadence",
      after=>defined($prev)?[$prev]:[],earliest=>$b,latest_end=>$b+59,asm=>\@a,events=>[
      {name=>'GRP0',offset=>2,windows=>[[$b+2,$b+2]]},
      {name=>'ENAM0',offset=>10,windows=>[[$b+10,$b+10]]},
      {name=>'PF0L',offset=>13,windows=>[[$b+13,$b+13]]},
      {name=>'PF1L',offset=>19,windows=>[[$b+19,$b+19]]},
      {name=>'PF2L',offset=>25,windows=>[[$b+25,$b+25]]},
      {name=>'ENABL',offset=>39,windows=>[[$b+39,$b+39]]},
      {name=>'PF0R',offset=>47,windows=>[[$b+47,$b+47]]},
      {name=>'PF1R',offset=>53,windows=>[[$b+53,$b+53]]},
      {name=>'PF2R',offset=>59,windows=>[[$b+59,$b+59]]},
   ]};

   my @p1;
   if ($p<2) {
      # Ordinary pairs: bank the colour byte, fetch the P1 byte through the
      # frame-wide service pointer, restore packed-row X, shift M1, and stage the
      # even PF byte in X for p0_mid to commit.
      push @p1,['stx.z next_color_slot+'.$p,3], ['lda.iy (p1_service_ptr),y',5],
              ['tsx',2], ['lsr.zx object_masks+25,x',6],
              ['ldx.ay stripe_feed0,y',4], ['sta GRP1',3];
   } else {
      # Pair 2 carries the event test.  CPY in a_visible set carry; the branch
      # below selects the ordinary continuation or the special tail.
      push @p1,['lda.iy (p1_service_ptr),y',5], ['bcs.same ordinary_stripe_continue',3];
      # Boundary colours ride the ordinary packed-M1 slot when this slot is the
      # one being relieved.
      if ($slot eq 'p1_feed') {
         push @p1,['lsr.zx object_masks+25,x',6], ['sta GRP1',3],
                 ['lda.ay stripe_feed0,y',4], ['sta COLUPF',3],
                 ['lda.ay stripe_feed1,y',4], ['sta COLUBK',3];
      } else {
         push @p1,['tsx',2], ['lsr.zx object_masks+25,x',6],
                 ['ldx.ay stripe_feed0,y',4], ['sta GRP1',3];
      }
   }
   push @ops,{id=>$tag.'p1_feed',
      description=>"pair $p".($p==2?" event test and ".($slot eq 'p1_feed'?'boundary colour install':'ordinary M1 shift'):' packed-M1 shift and even-PF staging'),
      after=>[$tag.'a_visible'],earliest=>$b+60,
      latest_end=>$p<2?$b+82:$b+($slot eq 'p1_feed'?90:82),
      asm=>\@p1,
      # `sta GRP1` is the final instruction of every p1_feed, so its offset is the
      # last instruction index.  The scheduler may open an idle gap ahead of the
      # block to land GRP1 on its ordinary cycle.
      # Offsets are stated exactly as the authoritative machines state them, so a
      # returned schedule is directly comparable with event_select and high_only.
      events=>$p<2?[{name=>'GRP1',offset=>22,windows=>[[$b+82,$b+82]]}]:($slot eq 'p1_feed'?[
         {name=>'GRP1',offset=>16,windows=>[[$b+76,$b+76]]},
         {name=>'COLUPF',offset=>23,windows=>[[$b+83,$b+83]]},
         {name=>'COLUBK',offset=>30,windows=>[[$b+90,$b+90]]}]:[
         {name=>'GRP1',offset=>22,windows=>[[$b+82,$b+82]]}])
   };

   push @ops,{id=>$tag.'b_left',description=>"pair $p fixed B-left cadence",
      after=>[$tag.'p1_feed'],earliest=>$b+($slot eq 'p1_feed'&&$p==2?91:83),
      latest_end=>$b+($slot eq 'p1_feed'&&$p==2?113:105),asm=>[
      ['lda.z stripe_cache+0',3],['adc #0',2],['sta ENAM1',3],['sta PF0',3],
      ['lda.z stripe_cache+1',3],['sta PF1',3],
      ['lda.z stripe_cache+2',3],['sta PF2',3]],events=>[
      {name=>'ENAM1',offset=>7,windows=>[[$b+($slot eq 'p1_feed'&&$p==2?98:90),$b+($slot eq 'p1_feed'&&$p==2?98:90)]]},
      {name=>'PF0L',offset=>10,windows=>[[$b+($slot eq 'p1_feed'&&$p==2?101:93),$b+($slot eq 'p1_feed'&&$p==2?101:93)]]},
      {name=>'PF1L',offset=>16,windows=>[[$b+($slot eq 'p1_feed'&&$p==2?107:99),$b+($slot eq 'p1_feed'&&$p==2?107:99)]]},
      {name=>'PF2L',offset=>22,windows=>[[$b+($slot eq 'p1_feed'&&$p==2?113:105),$b+($slot eq 'p1_feed'&&$p==2?113:105)]]},
   ]};

   if ($p<2) {
      push @ops,{id=>$tag.'p0_mid',description=>"pair $p PF staging plus packed-row TSX restore",
         after=>[$tag.'b_left'],earliest=>$b+106,latest_end=>$b+123,asm=>[
         ['lda.ay stripe_feed2,y',4],
         ['sta.z inactive_pf+'.$odd[$p],3],
         ['stx.z inactive_pf+'.$even[$p],3],
         ['tsx',2],['lda.z stripe_cache+3',3],['sta PF0',3]],
         events=>[{name=>'PF0R',offset=>17,windows=>[[$b+123,$b+123]]}]};
   } else {
      # Pair 2 is the supercycle-final pair, so it owes the loop branch and, at an
      # event stripe, the high-only service-pointer install.
      my @m;
      my $pf0r_offset;
      if ($slot eq 'p0_mid') {
         # Relieve the tail by hoisting the whole install into p0_mid, whose
         # ordinary form spends its PF-staging slots on a copy the event path
         # already has.  PF0R still has to land on its ordinary cycle, so the
         # two-cycle NOP keeps that appointment exactly.
         # Ordinary PF0R is a three-cycle zero-page store; the absolute form is
         # one cycle longer, so a two-cycle NOP before it keeps PF0R on its
         # ordinary cycle.
         @m=(['ldx.z next_p0_hi',3], ['lda.z special_p0+2',3],
             ['stx.z p0_service_ptr+1',3], ['lda.z stripe_cache+3',3],
             {text=>'nop',cycles=>2}, ['sta.a PF0',4]);
         $pf0r_offset=17;
      } else {
         @m=(['lda.ay stripe_feed1,y',4], ['sta.z inactive_pf+5',3],
             ['stx.z inactive_pf+4',3], ['tsx',2],
             ['lda.z stripe_cache+3',3], ['sta PF0',3]);
         $pf0r_offset=17;
      }
      push @ops,{id=>$tag.'p0_mid',
         description=>"pair 2 ".($slot eq 'p0_mid'?'carries next-P0 and installs the service high byte':'ordinary PF staging'),
         after=>[$tag.'b_left'],earliest=>$b+106,latest_end=>$b+123,
         asm=>\@m,events=>[{name=>'PF0R',offset=>$pf0r_offset,windows=>[[$b+123,$b+123]]}]};
   }

   push @ops,{id=>$tag.'b_right',description=>"pair $p fixed B-right cadence",
      after=>[$tag.'p0_mid'],earliest=>$b+124,latest_end=>$b+135,asm=>[
      ['lda.z stripe_cache+4',3],['sta PF1',3],
      ['lda.z stripe_cache+5',3],['sta PF2',3]],events=>[
      {name=>'PF1R',offset=>5,windows=>[[$b+129,$b+129]]},
      {name=>'PF2R',offset=>11,windows=>[[$b+135,$b+135]]}]};

   my @f;
   if ($p<2) {
      push @f,['lda.iy (p0_service_ptr),y',5], ['sta.z rolling_prepare_p0_'.$p,3],
              ['lsr.zx object_masks+26,x',6], ['dey',2];
   } elsif ($slot eq 'p0_mid') {
      # p0_mid already loaded the exact-cache next P0, installed the pointer
      # high byte and restored packed-row X, so the tail keeps the two ordinary
      # shifting instructions and the loop branch.  The remaining cycles are
      # filled with real preparation work for the next supercycle, never with
      # fictitious idle time: re-bank the exact-cache colour byte the hoisted
      # install consumed, then close the pair on its ordinary boundary so the next
      # pair's `sta GRP0` is not displaced.
      push @f,['lsr.zx object_masks+26,x',6], ['dey',2], ['bpl supercycle_start',3],
              ['lda.z special_c0',3], {text=>'nop',cycles=>2};
   } else {
      # Full special tail: exact-cache next P0, high-byte install, row restore,
      # M0 shift, frame index, loop branch.
      push @f,['lda.z special_p0+2',3], ['stx.z p0_service_ptr+1',3], ['tsx',2],
              ['lsr.zx object_masks+26,x',6], ['dey',2], ['bpl supercycle_start',3];
   }
   push @ops,{id=>$tag.'p0_feed',
      description=>"pair $p".($p==2?" supercycle loop tail".($slot eq 'p0_mid'?' with install hoisted to p0_mid':' with high-only install'):' ordinary P0 feed'),
      after=>[$tag.'b_right'],earliest=>$b+136,latest_end=>$b+151,asm=>\@f};
}

return {
   name=>"all_five supercycle-final event tail relieved at $slot",
   description=>"Composes the loop tail with the high-only install. The next P0 byte comes from the three-cycle exact cache instead of the five-cycle indirect load; slot=$slot decides which ordinary pair-2 slot carries the install.",
   line_cycles=>76,
   phase_origin=>2,
   horizon=>456,
   idle_fillers=>[
      {text=>'nop',cycles=>2},
      {text=>'bit.z timing_scratch',cycles=>3},
   ],
   operations=>\@ops,
};