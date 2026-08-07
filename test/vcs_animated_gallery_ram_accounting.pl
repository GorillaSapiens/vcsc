#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 90
# expectstdout: vcs_animated_gallery_ram_accounting ok: all 128 RIOT bytes, 2 main-activation bytes, 18 free bytes, high-level frame installation, and hardware-stack causes match the authoritative JSON baseline
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
@scratch==1 or die "scratch diagnostic reported ".scalar(@scratch)." slots; expected 1\n";

($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-Map',$mapfile,$build_source,'-o',$bin);
$rc==0 && !$sig or die "animated gallery build failed\n$out$err";
without_usage($out) eq '' && $err eq '' or die "animated gallery build wrote output\n$out$err";
-s $bin==4096 or die "animated gallery is not a 4K cartridge\n";
my $map=read_file($mapfile);
my $asm=read_file($assembly);
$map =~ /rom\s+used=3624 bytes .*free=466 bytes/
   or die "3624-byte optimized high-level frame-installation ROM result changed\n";
$map =~ /ram\s+used=110 bytes .*free=18 bytes .*objects=102 bytes hardware-stack=8 bytes/
   or die "110-byte compact-lowering RAM result changed\n";
$map =~ /^\s+CODE\.__vcsc_function\$install_frames\s+load=\$[0-9A-Fa-f]{4}\s+size=\$00E8/m
   or die "optimized high-level install_frames code size changed from 232 bytes\n";
$map !~ /^\s+BSS\.__vcsc_activation\$install_frames\b/m
   or die "high-level install_frames unexpectedly gained activation RAM\n";

my %layouts;
while ($map =~ /^\s+(?:BSS|DATA)\.__vcsc_object\$(\S+)\s+[^\n]*?run=\$([0-9A-Fa-f]{4})\s+size=\$([0-9A-Fa-f]{4})/mg) {
   $layouts{$1}={start=>hexnum($2),size=>hexnum($3)};
}
$map =~ /^\s+BSS\.__vcsc_activation\$main\s+run=\$([0-9A-Fa-f]{4})\s+size=\$([0-9A-Fa-f]{4})/m
   or die "map missing main activation\n";
my($activation_start,$activation_size)=(hexnum($1),hexnum($2));
$activation_size==2 or die "main activation changed from 2 bytes\n";
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
@hidden==1 && $hidden[0]{bytes}==4 && $hidden[0]{reason} eq '.callstackextra'
   or die "hidden hardware-stack explanation changed\n";
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
add_object('_vcsc_ptr0',0x80,2,'runtime_scratch','pointer');
add_object('_vcsc_ptr1',0x82,2,'runtime_scratch','pointer');
add_object('_vcsc_ptr2',0x84,2,'runtime_scratch','pointer');
add_object('_vcsc_arg0',0x86,1,'runtime_scratch','argument');
add_object('_vcsc_arg1',0x87,1,'runtime_scratch','argument');
for my $name (qw(game_player0_colors game_player1_colors)) {
   add_object($name,$layouts{$name}{start},$layouts{$name}{size},'renderer_state','mutable_row_colors');
}
add_object('game_player_x',$layouts{game_object_x}{start},2,'renderer_state','public_state');
add_object('game_nusiz',$layouts{game_object_x}{start}+2,2,'renderer_state','private_workspace');
add_object('game_ball_x',$layouts{game_object_x}{start}+4,1,'renderer_state','public_state');
for my $name (qw(game_player0_y game_player1_y game_ball_y game_player0_graphics game_player1_graphics game_player0_height game_player1_height game_ball_height)) {
   add_object($name,$layouts{$name}{start},$layouts{$name}{size},'renderer_state','public_state');
}
for my $name (qw(game_workspace game_playfield_position game_object_masks)) {
   add_object($name,$layouts{$name}{start},$layouts{$name}{size},'renderer_state','private_workspace');
}
for my $name (qw(sprite0 sprite1 animation_frame animation_clock select_ready pause_animation fire_ready)) {
   add_object($name,$layouts{$name}{start},$layouts{$name}{size},'persistent_state','gallery_control');
}
for my $member (@activation_members) {
   add_object($member->{name},$member->{start},$member->{size},$member->{class},$member->{subclass});
}
my $free_start=$activation_start+$activation_size;
my $free_size=$stack{start}-$free_start;
$free_size==18 or die "free RAM gap is $free_size bytes, expected 18\n";
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
$category_totals{runtime_scratch}==8 or die "runtime scratch baseline changed\n";
$category_totals{renderer_state}==85 or die "renderer-state baseline changed\n";
$category_totals{persistent_state}==7 or die "persistent-state baseline changed\n";
$category_totals{activation_scratch}==2 or die "activation compact-lowering result changed\n";
$category_totals{hardware_stack}==8 or die "hardware-stack baseline changed\n";
$category_totals{free_ram}==18 or die "free-RAM result changed\n";
$subcategory_totals{public_state}==13 or die "renderer public-state baseline changed\n";
$subcategory_totals{private_workspace}==56 or die "renderer private-workspace baseline changed\n";
$subcategory_totals{mutable_row_colors}==16 or die "mutable color baseline changed\n";

my @next_pair_expansions=($asm =~ /; begin inline expansion next_pair #(\d+)/g);
@next_pair_expansions==2 or die "expected two next_pair expansions, found ".scalar(@next_pair_expansions)."\n";
$asm =~ /; begin inline expansion next_pair #(\d+).*?; end inline expansion next_pair #\1.*?; begin inline expansion next_pair #(\d+).*?; end inline expansion next_pair #\2/s
   or die "next_pair expansions are not sequential in generated assembly\n";
$asm !~ /; begin inline expansion next_pair #\d+.*?__vcsc_scratch_.*?; end inline expansion next_pair #\d+/s
   or die "next_pair still uses compiler expression scratch\n";

my $report={
   schema=>5,
   program=>'examples/03_player_color_192/02_animated_sprites/player_color_192_animated_sprites.c26',
   totals=>{
      rom_bytes=>3624, rom_free_bytes=>466,
      ram_bytes=>110, free_ram_bytes=>18, object_bytes=>102, hardware_stack_bytes=>8,
      category_bytes=>\%category_totals, subcategory_bytes=>\%subcategory_totals,
   },
   objects=>\@objects,
   activation=>{
      owner=>'main', start=>$activation_start, size=>$activation_size,
      members=>\@activation_members,
      scratch_diagnostics=>\@scratch,
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
   hardware_stack=>{
      %stack, edges=>\@edges, deepest=>{weighted_depth=>$deepest_depth,path=>$deepest_path},
      hidden=>\@hidden, totals=>\%stack_totals,
   },
   protected_oracles=>[
      'test/vcs_player_color_192_animation.pl',
      'test/vcs_player_color_192_animation.cpp',
   ],
};
my $json=JSON::PP->new->canonical(1)->pretty(1)->encode($report);
write_file($actual_file,$json);
if ($ENV{VCSC_UPDATE_RAM_GOLDEN}) {
   write_file($golden_file,$json);
}
my $golden=read_file($golden_file);
$json eq $golden or die "animated-gallery RAM accounting changed; compare $actual_file with $golden_file\n";

print "vcs_animated_gallery_ram_accounting ok: all 128 RIOT bytes, 2 main-activation bytes, 18 free bytes, high-level frame installation, and hardware-stack causes match the authoritative JSON baseline\n";
