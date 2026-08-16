#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 90
# expectstdout: vcs_animated_gallery_ram_accounting ok: all 128 RIOT bytes, zero main-activation bytes, 77 free bytes, four-byte startup workspace, direct-countdown renderer state, packed persistent gallery state, high-level frame installation, and measured four-byte hardware-stack causes match the authoritative schema-16 JSON baseline
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use JSON::PP;
use Symbol qw(gensym);

sub usage { die "usage: $0 REPO TMP\n"; }
sub slurp_fh { my($fh)=@_; local $/; return <$fh> // ''; }
sub capture {
   my(@cmd)=@_; my $err=gensym; my $pid=open3(my $in,my $out,$err,@cmd); close($in);
   my $so=slurp_fh($out); my $se=slurp_fh($err); waitpid($pid,0);
   return ($?>>8,$?&127,$so,$se);
}
sub read_file {
   my($path)=@_; open(my $fh,'<:raw',$path) or die "read $path: $!\n";
   local $/; my $text=<$fh>; close($fh); return $text // '';
}
sub write_file {
   my($path,$text)=@_; open(my $fh,'>:raw',$path) or die "write $path: $!\n";
   print {$fh} $text; close($fh) or die "close $path: $!\n";
}
sub without_usage { my($s)=@_; $s =~ s/\AMEMORY USAGE\n(?:  [^\n]+\n)+//; return $s; }
sub hexnum { return hex($_[0]); }

my $repo=shift @ARGV // usage();
my $tmp=shift @ARGV // usage();
usage() if @ARGV;
$repo=abs_path($repo) // die "resolve repository\n";
make_path($tmp);
$tmp=abs_path($tmp) // die "resolve temporary directory\n";

my $driver=File::Spec->catfile($repo,qw(driver vcsc));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $source=File::Spec->catfile($repo,qw(examples 03_player_color_192 02_animated_sprites player_color_192_animated_sprites.c26));
my $build_source=File::Spec->catfile($tmp,'animated_gallery.c26');
my $assembly=File::Spec->catfile($tmp,'animated_gallery.s26');
my $bin=File::Spec->catfile($tmp,'animated_gallery.bin');
my $mapfile=File::Spec->catfile($tmp,'animated_gallery.map');
my $actual_file=File::Spec->catfile($tmp,'animated_gallery_ram_accounting.json');
my $golden_file=File::Spec->catfile($repo,qw(test fixtures vcs_animated_gallery_ram_accounting golden.json));
write_file($build_source,read_file($source));

my($rc,$sig,$out,$err)=capture($driver,'-S','-I',$vcs,'-Wc,-X,scratch',$source,'-o',$assembly);
$rc==0 && !$sig or die "scratch-diagnostic compile failed\n$out$err";
$out eq '' or die "scratch-diagnostic compile wrote stdout\n$out";
my @scratch;
for my $line (split /\n/,$err) {
   next unless $line =~ /^SCRATCH\s+/;
   $line =~ /^SCRATCH scope=(\S+) owner=(\S+) slot=(\d+) symbol=(\S+) size=(\d+) group=(\S+) allocation=(\S+) reason=(\S+) acquisitions=(\d+)$/
      or die "malformed scratch diagnostic: $line\n";
   push @scratch, {
      scope=>$1, owner=>$2, slot=>0+$3, symbol=>$4, size=>0+$5,
      group=>$6, allocation=>$7, reason=>$8, acquisitions=>0+$9,
   };
}
@scratch==0 or die "scratch diagnostic reported ".scalar(@scratch)." slots; fixed VSYNC should require none\n";

($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-Map',$mapfile,$build_source,'-o',$bin);
$rc==0 && !$sig or die "animated gallery build failed\n$out$err";
without_usage($out) eq '' && $err eq '' or die "animated gallery build wrote output\n$out$err";
-s $bin==4096 or die "animated gallery is not a 4K cartridge\n";
my $map=read_file($mapfile);
my $asm=read_file($assembly);
index($asm,'__phaseworkspace$V1$__vcsc_scratch_0')<0
   or die "fixed VSYNC unexpectedly materialized phase-scoped compiler scratch\n";
index($asm,'__phaseworkspace$V1$game_workspace')>=0
   or die "direct-countdown renderer workspace lacks explicit phase-workspace ownership metadata\n";
$map =~ /rom\s+used=3244 bytes .*free=846 bytes/
   or die "3244-byte absolute-alignment animated-gallery ROM result changed\n";
$map =~ /ram\s+used=51 bytes .*free=77 bytes .*objects=47 bytes hardware-stack=4 bytes/
   or die "51-byte post-startup-rewrite RAM result changed\n";
$map =~ /^\s+CODE\.__vcsc_function\$install_frames\s+load=\$[0-9A-Fa-f]{4}\s+size=\$00E8/m
   or die "optimized high-level install_frames code size changed from 232 bytes\n";
$map !~ /^\s+BSS\.__vcsc_activation\$install_frames\b/m
   or die "high-level install_frames unexpectedly gained activation RAM\n";

my %layouts;
while ($map =~ /^\s+(?:BSS|DATA|ZEROPAGE)\.__vcsc_object\$(\S+)\s+[^\n]*?run=\$([0-9A-Fa-f]{4})\s+size=\$([0-9A-Fa-f]{4})([^\n]*)/mg) {
   my($name,$start,$size,$tail)=($1,hexnum($2),hexnum($3),$4);
   my $phase;
   if ($tail =~ /\bphase=\$([0-9A-Fa-f]{2})/) { $phase=hexnum($1); }
   elsif ($tail =~ /\bphase=unscoped/) { $phase='unscoped'; }
   $layouts{$name}={start=>$start,size=>$size,phase=>$phase};
}
my %globals;
while ($map =~ /^\s+\$([0-9A-Fa-f]{4})\s+(\S+)\s+/mg) {
   $globals{$2}=hexnum($1) unless exists $globals{$2};
}
$map !~ /^\s+BSS\.__vcsc_activation\$main\b/m
   or die "fixed VSYNC/direct lowering unexpectedly materialized main activation RAM\n";
my($activation_start,$activation_size)=(undef,0);
$map =~ /^\s+region=ram depth=(\d+) bytes=\$([0-9A-Fa-f]{4}) physical=\$([0-9A-Fa-f]{4})-\$([0-9A-Fa-f]{4}) extra=\$([0-9A-Fa-f]{4}) weighted-depth=(\d+) bank-extra-slots=(\d+)/m
   or die "map missing hardware-stack summary\n";
my %stack=(depth=>0+$1,size=>hexnum($2),start=>hexnum($3),end=>hexnum($4),
           hidden_extra=>hexnum($5),weighted_depth=>0+$6,bank_extra_slots=>0+$7);

my @edges;
while ($map =~ /^\s+EDGE\s+(\S+)\s+->\s+(\S+)\s+slots=(\d+)\s+reason=(\S+)\s+object=\S+(?:\s+bank-bridge=yes)?$/mg) {
   push @edges,{from=>$1,to=>$2,slots=>0+$3,reason=>$4};
}
@edges==2 or die "expected two compiled call-graph edges, found ".scalar(@edges)."\n";
@edges=sort { $a->{from} cmp $b->{from} || $a->{to} cmp $b->{to} } @edges;
$map =~ /^\s+DEEPEST weighted-depth=(\d+) path=(.+)$/m
   or die "map missing deepest hardware-stack path\n";
my($deepest_depth,$deepest_path)=(0+$1,[split /\s+->\s+/,$2]);
my @hidden;
while ($map =~ /^\s+HIDDEN bytes=\$([0-9A-Fa-f]{4}) reason=(\S+) object=\S+$/mg) {
   push @hidden,{bytes=>hexnum($1),reason=>$2};
}
@hidden==1 && $hidden[0]{bytes}==0 && $hidden[0]{reason} eq '.callstackextra'
   or die "audited zero-byte hidden hardware-stack explanation changed\n";
$map =~ /^\s+TOTAL source-bytes=\$([0-9A-Fa-f]{4}) hidden-bytes=\$([0-9A-Fa-f]{4}) total-bytes=\$([0-9A-Fa-f]{4})$/m
   or die "map missing hardware-stack total explanation\n";
my %stack_totals=(source_bytes=>hexnum($1),hidden_bytes=>hexnum($2),total_bytes=>hexnum($3));

my @activation_members;
my $in_main_activation=0;
my @lines=split /\n/,$asm;
for (my $i=0;$i<@lines;$i++) {
   if ($lines[$i] =~ /^\.segment\s+"([^"]+)"/) {
      $in_main_activation=($1 eq 'BSS.__vcsc_activation$main');
      next;
   }
   next unless $in_main_activation;
   if ($lines[$i] =~ /^([A-Za-z_][A-Za-z0-9_\$]*):$/ && $i+1<@lines) {
      my $name=$1;
      if ($lines[$i+1] =~ /^\s*\.res\s+(\d+)\s*$/) {
         push @activation_members,{name=>$name,size=>0+$1};
         $i++;
      }
   }
}
my $member_total=0;
for my $member (@activation_members) {
   $member->{start}=$activation_start+$member_total;
   $member->{class}='activation_scratch';
   $member->{subclass}=($member->{name}=~/^__vcsc_scratch_/)
      ? 'expression_scratch' : 'inline_parameter';
   $member_total += $member->{size};
}
$member_total==$activation_size or die "activation members total $member_total, expected $activation_size\n";

my @objects;
sub add_object {
   my($name,$start,$size,$class,$subclass)=@_;
   push @objects,{name=>$name,start=>$start,size=>$size,class=>$class,subclass=>$subclass};
}
for my $spec (
   ['_vcsc_ptr0',2,'pointer'],['_vcsc_ptr1',2,'pointer'],
) {
   exists $globals{$spec->[0]} or die "map missing stock-startup workspace symbol $spec->[0]\n";
   add_object($spec->[0],$globals{$spec->[0]},$spec->[1],'runtime_scratch',$spec->[2]);
}
for my $name (qw(_vcsc_ptr2 _vcsc_arg0 _vcsc_arg1)) {
   exists $globals{$name} and die "stock gallery unexpectedly links demand-only runtime symbol $name\n";
}
for my $name (qw(game_player0_colors game_player1_colors)) {
   add_object($name,$layouts{$name}{start},$layouts{$name}{size},'renderer_state','mutable_row_colors');
}
add_object('game_player_x',$layouts{game_object_x}{start},2,'renderer_state','public_state');
add_object('game_nusiz',$layouts{game_object_x}{start}+2,2,'renderer_state','private_workspace');
add_object('game_ball_x',$layouts{game_object_x}{start}+4,1,'renderer_state','public_state');
for my $name (qw(game_player0_y game_player1_y game_ball_y game_player0_graphics game_player1_graphics game_player0_height game_player1_height game_ball_height)) {
   add_object($name,$layouts{$name}{start},$layouts{$name}{size},'renderer_state','public_state');
}
for my $name (qw(game_workspace game_playfield_position)) {
   add_object($name,$layouts{$name}{start},$layouts{$name}{size},'renderer_state','private_workspace');
}
for my $name (qw(sprite0 sprite1 animation_state control_flags)) {
   add_object($name,$layouts{$name}{start},$layouts{$name}{size},'persistent_state','gallery_control');
}
for my $member (@activation_members) {
   add_object($member->{name},$member->{start},$member->{size},$member->{class},$member->{subclass});
}
my $free_start=0x80;
for my $obj (@objects) {
   my $end=$obj->{start}+$obj->{size};
   $free_start=$end if $end>$free_start;
}
my $free_size=$stack{start}-$free_start;
$free_size==77 or die "free RAM gap is $free_size bytes, expected 77\n";
add_object('free_ram',$free_start,$free_size,'free_ram','unallocated');
add_object('hardware_stack',$stack{start},$stack{size},'hardware_stack','return_addresses');
@objects=sort { $a->{start}<=>$b->{start} || $a->{name} cmp $b->{name} } @objects;

my @owner;
for my $obj (@objects) {
   for my $addr ($obj->{start}..$obj->{start}+$obj->{size}-1) {
      die sprintf("RAM address $%02X classified twice by %s and %s\n",$addr,$owner[$addr]//'<none>',$obj->{name})
         if defined $owner[$addr];
      $owner[$addr]=$obj->{name};
   }
}
for my $addr (0x80..0xff) {
   die sprintf("RAM address $%02X is unclassified\n",$addr) unless defined $owner[$addr];
}

my %category_totals;
my %subcategory_totals;
for my $obj (@objects) {
   $category_totals{$obj->{class}} += $obj->{size};
   $subcategory_totals{$obj->{subclass}} += $obj->{size};
}
my $sum=0; $sum+=$_ for values %category_totals;
$sum==128 or die "classified RAM total is $sum, expected 128\n";
$category_totals{runtime_scratch}==4 or die "stock startup workspace changed from four bytes\n";
$category_totals{renderer_state}==39 or die "direct-countdown renderer-state result changed\n";
$category_totals{persistent_state}==4 or die "persistent-state packing result changed\n";
($category_totals{activation_scratch}//0)==0 or die "main activation unexpectedly consumes RAM\n";
$category_totals{hardware_stack}==4 or die "hardware-stack reduction changed\n";
$category_totals{free_ram}==77 or die "post-startup-rewrite free-RAM result changed\n";
$subcategory_totals{public_state}==13 or die "renderer public-state baseline changed\n";
$subcategory_totals{private_workspace}==10 or die "renderer private-workspace result changed\n";
$subcategory_totals{mutable_row_colors}==16 or die "mutable color baseline changed\n";

exists $layouts{'__vcsc_scratch_0'} and die "fixed VSYNC unexpectedly links standalone compiler scratch\n";
defined($layouts{game_workspace}{phase}) && $layouts{game_workspace}{phase}==0x0e
   or die "game_workspace is not classified as VBLANK+visible+overscan\n";
exists $layouts{game_object_masks} and die "removed game_object_masks unexpectedly linked\n";

my @next_pair_expansions=($asm =~ /; begin inline expansion next_pair #(\d+)/g);
@next_pair_expansions==2 or die "expected two next_pair expansions, found ".scalar(@next_pair_expansions)."\n";
$asm =~ /; begin inline expansion next_pair #(\d+).*?; end inline expansion next_pair #\1.*?; begin inline expansion next_pair #(\d+).*?; end inline expansion next_pair #\2/s
   or die "next_pair expansions are not sequential in generated assembly\n";
$asm !~ /; begin inline expansion next_pair #\d+.*?__vcsc_scratch_.*?; end inline expansion next_pair #\d+/s
   or die "next_pair still uses compiler expression scratch\n";

my $report={
   schema=>16,
   program=>'examples/03_player_color_192/02_animated_sprites/player_color_192_animated_sprites.c26',
   totals=>{
      rom_bytes=>3244, rom_free_bytes=>846,
      ram_bytes=>51, free_ram_bytes=>77, object_bytes=>47, hardware_stack_bytes=>4,
      category_bytes=>\%category_totals, subcategory_bytes=>\%subcategory_totals,
   },
   objects=>\@objects,
   activation=>{
      owner=>'main', start=>undef, size=>0,
      members=>\@activation_members,
      repeated_inline=>{
         function=>'next_pair', expansions=>[map { "__inline\$$_\$next_pair" } @next_pair_expansions],
         bytes_each=>0, physical_bytes=>0, previous_physical_bytes=>6,
         saved_bytes_this_item=>6, total_saved_from_unshared_baseline=>12,
         lifetime_groups=>[],
         current_reason=>'direct-byte-lowering-needs-no-expression-scratch',
         generated_execution=>'sequential',
      },
      item3_delta=>{
         previous_activation_bytes=>7, activation_bytes=>2,
         ram_saved_bytes=>5, free_ram_gained_bytes=>5,
         previous_rom_bytes=>3993, rom_bytes=>3662, rom_saved_bytes=>331,
      },
      high_level_install_frames=>{
         handwritten_assembly_bytes=>236,
         pre_optimizer_high_level_code_bytes=>462, high_level_code_bytes=>232,
         code_bytes_saved_by_optimizer_followup=>230, code_bytes_vs_handwritten=>-4,
         handwritten_gallery_rom_bytes=>3662, pre_optimizer_gallery_rom_bytes=>3854,
         rom_bytes=>3624, rom_saved_by_optimizer_followup=>230,
         gallery_rom_bytes_vs_handwritten=>-38,
         previous_ram_bytes=>110, ram_bytes=>110, ram_added_bytes=>0,
         previous_free_ram_bytes=>18, free_ram_bytes=>18,
         activation_bytes=>0, rom_free_bytes=>466,
      },
   },
   phase_overlay=>{
      historical_baseline_ram_bytes=>57, historical_ram_bytes=>56, historical_ram_saved_bytes=>1,
      current_ram_bytes=>51, current_free_ram_bytes=>77, current_main_activation_bytes=>0,
      current_scratch_slots=>scalar(@scratch),
      host=>{
         symbol=>'game_workspace', start=>$layouts{game_workspace}{start},
         size=>$layouts{game_workspace}{size}, phase_mask=>14,
         phases=>['VBLANK','visible','overscan'],
      },
      proof=>'the earlier VSYNC-only scratch overlay remains a historical optimization; fixed three-line VSYNC now materializes no scratch at all',
   },
   alignment_padding_cleanup=>{
      previous_rom_bytes=>3624, rom_bytes=>3560, rom_saved_bytes=>64,
      previous_sprite_frames_3_bytes=>256, sprite_frames_3_bytes=>192,
      removed_literal_zero_padding_bytes=>64, alignment=>256,
      proof=>'sprite_frames_3 contains exactly six four-frame eight-byte sets; explicit align(256) preserves the page-base contract without storing alignment bytes as application data',
   },
   persistent_bookkeeping=>{
      baseline_persistent_bytes=>7, persistent_bytes=>4, ram_saved_bytes=>3,
      baseline_ram_bytes=>109, ram_bytes=>106, baseline_free_ram_bytes=>19, free_ram_bytes=>22,
      baseline_rom_bytes=>3560, rom_bytes=>3545, rom_saved_bytes=>15,
      control_flags=>{bytes=>1, select_ready_mask=>1, paused_mask=>2, fire_ready_mask=>4},
      animation_state=>{bytes=>1, phase_mask=>15, clock_shift=>4, frame_hold=>8},
      sprite_pair=>{stored_bytes=>2, relation=>'sprite1=sprite0+1'},
      sprite1_derivation_trial=>{rom_bytes=>3595, ram_bytes=>105, install_frames_bytes=>303,
         rom_delta_vs_stored=>50, ram_delta_vs_stored=>-1,
         decision=>'keep sprite1 because the roadmap permits storage when it is measurably smaller in ROM'},
      proof=>'phase and hold clock share one byte; Select/fire edge latches and pause share one flags byte; source-set-03 keeps independent modulo-3 bits',
   },
   hardware_stack_reduction=>{
      previous_ram_bytes=>106, ram_bytes=>102, ram_saved_bytes=>4,
      previous_free_ram_bytes=>22, free_ram_bytes=>26,
      previous_stack_bytes=>8, stack_bytes=>4, stack_saved_bytes=>4,
      rom_bytes=>3545, rom_delta_bytes=>0,
      source_stack_bytes=>4, hidden_stack_bytes=>0,
      proof=>'historical item-7 mask-renderer proof: single-use prepare_object_masks and prepare_one wrappers were flattened; the remaining set_range JSR was never deeper than startup -> main plus one ordinary source callee, so explicit .callstackextra 0 was sufficient; item 9 subsequently removes the mask builder entirely while retaining the four-byte stack floor',
      floor=>'with stock startup JSR main and a real main -> install_frames/deadline source call, four hardware-stack bytes are the conservative minimum without a separate startup/ABI change',
   },
   post_optimization_remeasurement=>{
      renderer_profile=>'player_color_192 P0/P1/Ball',
      ball_capability_retained=>JSON::PP::true,
      gallery_ball_height=>0,
      baseline=>{rom_bytes=>3993, ram_bytes=>128, activation_bytes=>20, stack_bytes=>8, free_ram_bytes=>0},
      current=>{rom_bytes=>3244, ram_bytes=>51, activation_bytes=>0, stack_bytes=>4, free_ram_bytes=>77},
      total_delta=>{rom_bytes=>-749, ram_bytes=>-77, activation_bytes=>-20, stack_bytes=>-4, free_ram_bytes=>77},
      free_ram_percent=>60.15625,
      useful_game_state_margin=>JSON::PP::true,
      decision=>'retain-general-p0-p1-ball-renderer',
      rationale=>'the official-opcode direct-countdown renderer removes the 48-byte object schedule while retaining P0/P1/Ball capability and expands the gallery margin to 72 bytes',
      checkpoint_source=>'historical rows through startup-main-cleanup are recorded measurements; absolute-align-link-placement is the current linker result after relocatable .align became an absolute final-address contract',
      checkpoints=>[
         {step=>'baseline', rom_bytes=>3993, ram_bytes=>128, activation_bytes=>20, stack_bytes=>8, free_ram_bytes=>0, delta_rom_bytes=>0, delta_ram_bytes=>0, delta_activation_bytes=>0, delta_stack_bytes=>0},
         {step=>'item1', rom_bytes=>3993, ram_bytes=>115, activation_bytes=>7, stack_bytes=>8, free_ram_bytes=>13, delta_rom_bytes=>0, delta_ram_bytes=>-13, delta_activation_bytes=>-13, delta_stack_bytes=>0},
         {step=>'item2', rom_bytes=>3993, ram_bytes=>115, activation_bytes=>7, stack_bytes=>8, free_ram_bytes=>13, delta_rom_bytes=>0, delta_ram_bytes=>0, delta_activation_bytes=>0, delta_stack_bytes=>0},
         {step=>'item3', rom_bytes=>3662, ram_bytes=>110, activation_bytes=>2, stack_bytes=>8, free_ram_bytes=>18, delta_rom_bytes=>-331, delta_ram_bytes=>-5, delta_activation_bytes=>-5, delta_stack_bytes=>0},
         {step=>'item4', rom_bytes=>3854, ram_bytes=>110, activation_bytes=>2, stack_bytes=>8, free_ram_bytes=>18, delta_rom_bytes=>192, delta_ram_bytes=>0, delta_activation_bytes=>0, delta_stack_bytes=>0},
         {step=>'item4a', rom_bytes=>3624, ram_bytes=>110, activation_bytes=>2, stack_bytes=>8, free_ram_bytes=>18, delta_rom_bytes=>-230, delta_ram_bytes=>0, delta_activation_bytes=>0, delta_stack_bytes=>0},
         {step=>'item5', rom_bytes=>3624, ram_bytes=>109, activation_bytes=>1, stack_bytes=>8, free_ram_bytes=>19, delta_rom_bytes=>0, delta_ram_bytes=>-1, delta_activation_bytes=>-1, delta_stack_bytes=>0},
         {step=>'item5a', rom_bytes=>3560, ram_bytes=>109, activation_bytes=>1, stack_bytes=>8, free_ram_bytes=>19, delta_rom_bytes=>-64, delta_ram_bytes=>0, delta_activation_bytes=>0, delta_stack_bytes=>0},
         {step=>'item6', rom_bytes=>3545, ram_bytes=>106, activation_bytes=>1, stack_bytes=>8, free_ram_bytes=>22, delta_rom_bytes=>-15, delta_ram_bytes=>-3, delta_activation_bytes=>0, delta_stack_bytes=>0},
         {step=>'item7', rom_bytes=>3545, ram_bytes=>102, activation_bytes=>1, stack_bytes=>4, free_ram_bytes=>26, delta_rom_bytes=>0, delta_ram_bytes=>-4, delta_activation_bytes=>0, delta_stack_bytes=>-4},
         {step=>'item9', rom_bytes=>3290, ram_bytes=>56, activation_bytes=>1, stack_bytes=>4, free_ram_bytes=>72, delta_rom_bytes=>-255, delta_ram_bytes=>-46, delta_activation_bytes=>0, delta_stack_bytes=>0},
         {step=>'item9a', rom_bytes=>3297, ram_bytes=>56, activation_bytes=>1, stack_bytes=>4, free_ram_bytes=>72, delta_rom_bytes=>7, delta_ram_bytes=>0, delta_activation_bytes=>0, delta_stack_bytes=>0},
         {step=>'item10a-playfield', rom_bytes=>3289, ram_bytes=>56, activation_bytes=>1, stack_bytes=>4, free_ram_bytes=>72, delta_rom_bytes=>-8, delta_ram_bytes=>0, delta_activation_bytes=>0, delta_stack_bytes=>0},
         {step=>'item10a-stella', rom_bytes=>3292, ram_bytes=>56, activation_bytes=>1, stack_bytes=>4, free_ram_bytes=>72, delta_rom_bytes=>3, delta_ram_bytes=>0, delta_activation_bytes=>0, delta_stack_bytes=>0},
         {step=>'frame-ntsc-262', rom_bytes=>3296, ram_bytes=>56, activation_bytes=>1, stack_bytes=>4, free_ram_bytes=>72, delta_rom_bytes=>4, delta_ram_bytes=>0, delta_activation_bytes=>0, delta_stack_bytes=>0},
         {step=>'startup-main-cleanup', rom_bytes=>3377, ram_bytes=>51, activation_bytes=>0, stack_bytes=>4, free_ram_bytes=>77, delta_rom_bytes=>81, delta_ram_bytes=>-5, delta_activation_bytes=>-1, delta_stack_bytes=>0},
         {step=>'absolute-align-link-placement', rom_bytes=>3244, ram_bytes=>51, activation_bytes=>0, stack_bytes=>4, free_ram_bytes=>77, delta_rom_bytes=>-133, delta_ram_bytes=>0, delta_activation_bytes=>0, delta_stack_bytes=>0},
      ],
   },
   completion_gates=>{
      retained_architecture=>[
         'player_color_192:p0-p1-ball',
         'player_color_181:p0-p1-ball',
         'player_color_181_unofficial:p0-p1-ball',
         'all_five_192:p0-p1-m0-m1-ball',
         'all_five_181:p0-p1-m0-m1-ball',
         'all_five_181_unofficial:p0-p1-m0-m1-ball',
      ],
      optional_two_sprite_profiles=>{item11_192=>'closed-unnecessary',item12_181=>'closed-unnecessary'},
      baseline=>{rom_bytes=>3993,ram_bytes=>128,free_ram_bytes=>0,activation_bytes=>20,stack_bytes=>8},
      final=>{rom_bytes=>3244,ram_bytes=>51,free_ram_bytes=>77,activation_bytes=>0,stack_bytes=>4},
      ram_savings=>{
         total=>77, activation_total=>20, runtime_startup=>4, persistent_state=>3, hardware_stack=>4, renderer=>46,
         repeated_inline_within_item1=>12, other_item1_lifetime_overlay=>1,
         compact_lowering=>5, phase_overlay=>1, item2_incremental=>0,
      },
      rom_savings=>{
         total=>749, compact_lowering=>331, high_level_install_frames_net=>38,
         alignment_padding=>64, absolute_alignment_link_placement=>133, persistent_state=>15, renderer_final=>253, frame_scheduler_262_cost=>4,
         lifetime_and_inline_overlay=>0, phase_overlay=>0, hardware_stack=>0,
      },
      meaningful_free_ram=>JSON::PP::true, free_ram_percent=>60.15625,
      ball_capability_retained=>JSON::PP::true,
      item14_remains=>JSON::PP::true,
      decision=>'retain-general-renderers-no-two-sprite-split',
   },
   direct_countdown_renderer=>{
      official_opcodes=>JSON::PP::true,
      ball_capability_retained=>JSON::PP::true,
      object_schedule_bytes_before=>48, object_schedule_bytes_after=>0,
      renderer_private_bytes_before=>56, renderer_private_bytes_after=>10,
      renderer_module_bytes_before=>69, renderer_module_bytes_after=>23,
      gallery_before=>{rom_bytes=>3545, ram_bytes=>102, free_ram_bytes=>26, object_bytes=>98, stack_bytes=>4},
      gallery_after_renderer_fix=>{rom_bytes=>3292, ram_bytes=>56, free_ram_bytes=>72, object_bytes=>52, stack_bytes=>4},
      gallery_current=>{rom_bytes=>3244, ram_bytes=>51, free_ram_bytes=>77, object_bytes=>47, stack_bytes=>4},
      postcloseout_runtime_main_delta=>{rom_bytes=>81, ram_bytes=>-5, free_ram_bytes=>5, object_bytes=>-5},
      absolute_alignment_link_delta=>{rom_bytes=>-133, ram_bytes=>0},
      frame_scheduler_262_rom_cost=>4,
      delta=>{rom_bytes=>-253, ram_bytes=>-46, free_ram_bytes=>46, object_bytes=>-46, stack_bytes=>0},
      smoke_before=>{rom_bytes=>1623, ram_bytes=>82, free_ram_bytes=>46},
      smoke_after=>{rom_bytes=>1370, ram_bytes=>36, free_ram_bytes=>92},
      vblank_marker_span=>{before_cycles=>920, after_cycles=>468, saved_cycles=>452,
         method=>'frame-2 cycles from the first saved-Y workspace write through the final pre-visible PF2 staging write in the static renderer fixture'},
      visible_schedule=>{pair_cycles=>152, steady_pf_cycles=>[10,17,40,47],
         transition_p1_pf_cycles_before=>[10,17,40,47],
         transition_p1_pf_cycles_after=>[9,16,40,47],
         row_end_pf_cycles_after=>[10,17,40,47], terminal_row_end_pf_cycles_after=>[10,17,43,50],
         exact_visible_lines=>192, exact_frame_lines=>262},
      edge_fix=>'the removed mask schedule and early direct-count revisions mishandled the delayed Ball latch/PF row-boundary interaction; the final schedule computes the Ball decision in carry without moving the proven PF writes, then materializes ENABL on the following half, preserving the Stella-correct playfield raster',
   },
   hardware_stack=>{
      %stack, edges=>\@edges, deepest=>{weighted_depth=>$deepest_depth,path=>$deepest_path},
      hidden=>\@hidden, totals=>\%stack_totals,
   },
   protected_oracles=>[
      'test/vcs_player_color_192_animation.pl',
      'test/vcs_player_color_192_animation.cpp',
      'test/vcs_playfield_phase.cpp',
      'test/vcs_player_color_192_stella.pl',
   ],
};
my $json=JSON::PP->new->canonical(1)->pretty(1)->encode($report);
write_file($actual_file,$json);
if ($ENV{VCSC_UPDATE_RAM_GOLDEN}) {
   write_file($golden_file,$json);
}
my $golden=read_file($golden_file);
$json eq $golden or die "animated-gallery RAM accounting changed; compare $actual_file with $golden_file\n";

print "vcs_animated_gallery_ram_accounting ok: all 128 RIOT bytes, zero main-activation bytes, 77 free bytes, four-byte startup workspace, direct-countdown renderer state, packed persistent gallery state, high-level frame installation, and measured four-byte hardware-stack causes match the authoritative schema-16 JSON baseline\n";
