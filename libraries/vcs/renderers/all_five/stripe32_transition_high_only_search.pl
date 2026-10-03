# This file is covered under CC0-1.0. See libraries/LICENSE.txt.
# Boundary-color timing proof for an isolated one-player stripes32 transition
# when service-pointer low bytes are frame-invariant (see
# stripe32_service_low_invariant.pl).  Only the changing player's high byte is
# installed at the end of the special stripe; there is no following handoff
# pair and no skipped BL/M1/M0 shift/composite byte.
#
# VCSC_STRIPE_TRANSITION_PLAYER selects p0 or p1.  This proof assumes the next
# event is not in the immediately following stripe; adjacent events/runs remain
# a separate composition problem.
use strict;
use warnings;
my$which=lc($ENV{VCSC_STRIPE_TRANSITION_PLAYER}//'p0');
die "VCSC_STRIPE_TRANSITION_PLAYER must be p0 or p1\n" unless $which eq 'p0'||$which eq 'p1';
my @ops;
my @pf0=(0,3); my @pf1=(1,4); my @pf2=(2,5);
sub aev { my($b)=@_; return (
 {name=>'GRP0',offset=>2,windows=>[[$b+2,$b+2]]}, {name=>'ENAM0',offset=>10,windows=>[[$b+10,$b+10]]},
 {name=>'PF0L',offset=>13,windows=>[[$b+13,$b+13]]}, {name=>'PF1L',offset=>19,windows=>[[$b+19,$b+19]]},
 {name=>'PF2L',offset=>25,windows=>[[$b+25,$b+25]]}, {name=>'ENABL',offset=>39,windows=>[[$b+39,$b+39]]},
 {name=>'PF0R',offset=>47,windows=>[[$b+47,$b+47]]}, {name=>'PF1R',offset=>53,windows=>[[$b+53,$b+53]]},
 {name=>'PF2R',offset=>59,windows=>[[$b+59,$b+59]]}, ); }
sub blev { my($b,$shift)=@_; return (
 {name=>'ENAM1',offset=>7,windows=>[[$b+90+$shift,$b+90+$shift]]}, {name=>'PF0L',offset=>10,windows=>[[$b+93+$shift,$b+93+$shift]]},
 {name=>'PF1L',offset=>16,windows=>[[$b+99+$shift,$b+99+$shift]]}, {name=>'PF2L',offset=>22,windows=>[[$b+105+$shift,$b+105+$shift]]}, ); }
sub brev { my($b)=@_; return (
 {name=>'PF1R',offset=>5,windows=>[[$b+129,$b+129]]}, {name=>'PF2R',offset=>11,windows=>[[$b+135,$b+135]]}, ); }

for my$p(0..2){
 my$b=$p*152; my$tag="p${p}_"; my$prev=$p?'p'.($p-1).'_p0_feed':undef;
 my@a=(['sta GRP0',3],['lda.z stripe_cache+0',3],['adc #0',2],['sta ENAM0',3],['sta PF0',3],
        ['lda.z stripe_cache+1',3],['sta PF1',3],['lda.z stripe_cache+2',3],['sta PF2',3],
        ['lsr.zx object_masks+0,x',6],['lda.z stripe_cache+3',3],['adc #0',2],['sta ENABL',3]);
 if($p<2){push@a,['ldx.ay stripe_feed0,y',4],['sta.a PF0',4],['lda.z stripe_cache+4',3],['sta PF1',3],['lda.z stripe_cache+5',3],['sta PF2',3];}
 else {push@a,['cpy.z next_event_threshold',3],['nop',2],['sta PF0',3],['lda.z stripe_cache+4',3],['sta PF1',3],['lda.z stripe_cache+5',3],['sta PF2',3];}
 push@ops,{id=>$tag.'a_visible',after=>defined($prev)?[$prev]:[],earliest=>$b,latest_end=>$b+59,description=>"special $which pair $p A",asm=>\@a,events=>[aev($b)]};

 my@p1;
 if($p<2){push@p1,["stx.z inactive_pf+$pf0[$p]",3];}
 if($which eq 'p1') { push@p1,["lda.z special_p1+$p",3],['nop',2]; }
 else                { push@p1,['lda.iy (p1_service_ptr),y',5]; }
 if($p<2){push@p1,['tsx',2],['lsr.zx object_masks+12,x',6],['ldx.ay stripe_feed1,y',4],['sta GRP1',3];}
 else {
    # Next-event ordinary branch is taken in this isolated-event proof.
    # For changing P1, exact3+nop2 has the same five cycles as indirect P1.
    unshift @p1,['bcs.same next_event_not_adjacent',3];
    push@p1,['lsr.zx object_masks+12,x',6],['sta GRP1',3],
             ['lda.ay stripe_feed0,y',4],['sta COLUPF',3],['lda.ay stripe_feed1,y',4],['sta COLUBK',3];
 }
 push@ops,{id=>$tag.'p1_feed',after=>[$tag.'a_visible'],earliest=>$b+60,latest_end=>$p<2?$b+82:$b+90,
           description=>"special $which pair $p P1".($p==2?' plus boundary colors':''),asm=>\@p1,
           events=>$p<2?[{name=>'GRP1',offset=>22,windows=>[[$b+82,$b+82]]}]:[
             {name=>'GRP1',offset=>16,windows=>[[$b+76,$b+76]]},{name=>'COLUPF',offset=>23,windows=>[[$b+83,$b+83]]},{name=>'COLUBK',offset=>30,windows=>[[$b+90,$b+90]]}]};

 my$shift=$p==2?8:0;
 push@ops,{id=>$tag.'b_left',after=>[$tag.'p1_feed'],earliest=>$b+83+$shift,latest_end=>$b+105+$shift,description=>"pair $p B-left",asm=>[
   ['lda.z stripe_cache+0',3],['adc #0',2],['sta ENAM1',3],['sta PF0',3],['lda.z stripe_cache+1',3],['sta PF1',3],['lda.z stripe_cache+2',3],['sta PF2',3]],events=>[blev($b,$shift)]};
 if($p<2){
   push@ops,{id=>$tag.'p0_mid',after=>[$tag.'b_left'],earliest=>$b+106,latest_end=>$b+123,description=>"pair $p PF staging",asm=>[
      ['lda.ay stripe_feed2,y',4],["sta.z inactive_pf+$pf2[$p]",3],["stx.z inactive_pf+$pf1[$p]",3],['tsx',2],['lda.z stripe_cache+3',3],['sta PF0',3]],
      events=>[{name=>'PF0R',offset=>17,windows=>[[$b+123,$b+123]]}]};
 } else {
   push@ops,{id=>$tag.'p0_mid',after=>[$tag.'b_left'],earliest=>$b+114,latest_end=>$b+123,description=>"pair2 loads next $which service high while preserving PF0R",asm=>[
      ["ldx.z next_${which}_hi",3],['lda.z stripe_cache+3',3],['sta.a PF0',4]],events=>[{name=>'PF0R',offset=>9,windows=>[[$b+123,$b+123]]}]};
 }
 push@ops,{id=>$tag.'b_right',after=>[$tag.'p0_mid'],earliest=>$b+124,latest_end=>$b+135,description=>"pair $p B-right",asm=>[
   ['lda.z stripe_cache+4',3],['sta PF1',3],['lda.z stripe_cache+5',3],['sta PF2',3]],events=>[brev($b)]};

 my@p0;
 if($p<2){
   if($which eq 'p0') { @p0=(["lda.z special_p0+$p",3],['nop',2],["sta.z special_prepare_p0_$p",3],['lsr.zx object_masks+24,x',6],['dey',2]); }
   else                { @p0=(['lda.iy (p0_service_ptr),y',5],["sta.z rolling_prepare_p0_$p",3],['lsr.zx object_masks+24,x',6],['dey',2]); }
 } else {
   if($which eq 'p0') {
      @p0=(['lda.z special_p0+2',3],['stx.z p0_service_ptr+1',3],['tsx',2],['lsr.zx object_masks+24,x',6],['dey',2]);
   } else {
      @p0=(['lda.z handoff_p0',3],['stx.z p1_service_ptr+1',3],['tsx',2],['lsr.zx object_masks+24,x',6],['dey',2]);
   }
 }
 push@ops,{id=>$tag.'p0_feed',after=>[$tag.'b_right'],earliest=>$b+136,latest_end=>$b+151,description=>"pair $p P0; high-only transition commit on pair2",asm=>\@p0};
}
return {name=>"all_five stripes32 isolated $which high-only transition",description=>'Boundary-color special stripe installs only the changing service high byte before the next stripe; no handoff pair or nonplayer composites are required.',line_cycles=>76,phase_origin=>2,horizon=>456,idle_fillers=>[{text=>'nop',cycles=>2},{text=>'bit.z timing_scratch',cycles=>3}],operations=>\@ops};
