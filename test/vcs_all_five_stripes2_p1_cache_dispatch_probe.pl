#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_all_five_stripes2_p1_cache_dispatch_probe ok
# expectexit: 0
use strict; use warnings; use Cwd qw(abs_path); use File::Spec; use IPC::Open3; use Symbol qw(gensym);
sub usage { die "usage: $0 REPO TMP\n"; }
sub slurp_fh { my($fh)=@_; local $/; my $d=<$fh>; return defined($d)?$d:''; }
sub capture { my(@cmd)=@_; my $err=gensym; my $pid=open3(my $in,my $out,$err,@cmd); close($in); my $so=slurp_fh($out); my $se=slurp_fh($err); waitpid($pid,0); return ($?>>8,$?&127,$so,$se); }
sub without_usage { my($out)=@_; $out =~ s/\AMEMORY USAGE\n(?:  [^\n]+\n)+//; return $out; }
sub read_file { my($p)=@_; open(my $f,'<:raw',$p) or die "read $p: $!\n"; local $/; my $d=<$f>; close($f); return defined($d)?$d:''; }
sub map_addr {
   my($map,$name)=@_;
   $map =~ /^\s*\$([0-9A-Fa-f]{4})\s+\Q$name\E\s/m or die "map lost symbol $name\n";
   return hex($1);
}
sub byte { sprintf('0x%02x',$_[0]&255) }
sub addr { sprintf('0x%04x',$_[0]&0xffff) }

my $repo=shift @ARGV // usage(); my $tmp=shift @ARGV // usage(); usage() if @ARGV;
$repo=abs_path($repo); $tmp=abs_path($tmp);
my $driver=$ENV{VCSC_DRIVER} || File::Spec->catfile($repo,qw(driver vcsc));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $source=File::Spec->catfile($repo,qw(test fixtures all_five_stripes2_192 refill_p1_cache.c26));
my $bin=File::Spec->catfile($tmp,'p1_cache_dispatch.bin');
my $mapfile=File::Spec->catfile($tmp,'p1_cache_dispatch.map');
my($rc,$sig,$o,$er)=capture($driver,'-I',$vcs,'-Map',$mapfile,
   '-DVCS_STRIPES2_CERT_TAIL7','-DVCS_STRIPES2_P1_CACHE_DISPATCH_PROBE',
   $source,'-o',$bin);
$rc==0&&!$sig or die "P1-cache dispatch build failed\n$o$er";
without_usage($o) eq ''&&$er eq '' or die "P1-cache dispatch build wrote output\n$o$er";
$o =~ /^  ram\s+used=98 bytes .* free=30 bytes/m or die "P1-cache dispatch allocated RAM\n$o";
$o =~ /^  rom\s+used=(\d+) bytes/m && $1<=4096 or die "P1-cache dispatch no longer fits 4K\n$o";
my $map=read_file($mapfile);
$map =~ /^\s+RODATA\.__vcsc_object\$game_stripe_p1cache_transition_alias\s+load=\$[0-9A-Fa-f]{4}\s+size=\$0008\b/m
   or die "P1-cache dispatch alias table is not 8 bytes\n";
$map =~ /^\s+RODATA\.__vcsc_object\$game_stripe_p1cache_first_free_start\s+load=\$[0-9A-Fa-f]{4}\s+size=\$0008\b/m
   or die "P1-cache dispatch selector table is not 8 bytes\n";
$map =~ /^\s+RODATA\.__vcsc_object\$game_stripe_service_zero\s+load=\$[0-9A-Fa-f]{4}\s+size=\$0003\b/m
   or die "P1-cache dispatch zero run is not three bytes\n";
$map !~ /stripe_sprite_cache/ or die "P1-cache dispatch introduced a sprite cache\n";

my %a=map { $_=>map_addr($map,$_) } qw(
   game_player0_y game_player1_y game_player0_height game_player1_height
   game_object_masks game_stripe_service_p1_ptr game_stripe_service_zero
   p0_graphics p1_graphics
);
my $dispatch_state=$a{game_object_masks}+7;
my @p0_cache_addr=map { $a{game_object_masks}+$_ } (35,39,43);
my @p0_graphics=(0x00,0x66,0x66,0x66,0x7e,0x66,0x66,0x3c);
my @alias=(1,1,2,2,4,4,0,0);
my @first=(0,2,0,4,0,2,0,0);
my %resume_x=(0=>0xe8,2=>0xe9,4=>0xeb);

my $cxx=$ENV{CXX}||'c++'; my $mos=File::Spec->catdir($repo,qw(simulator mos6502));
my $old_mos=$ENV{VCSC_MOS6502_OBJECT};
my @mi=$old_mos && -f $old_mos ? ($old_mos) : (-f File::Spec->catfile($mos,'mos6502.o')?(File::Spec->catfile($mos,'mos6502.o')):(File::Spec->catfile($mos,'mos6502.cpp')));
my $timing=File::Spec->catfile($tmp,'p1_cache_dispatch_timing');
($rc,$sig,$o,$er)=capture($cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,File::Spec->catfile($repo,qw(test vcs_frame_timing.cpp)),@mi,'-o',$timing);
$rc==0&&!$sig or die "timing harness build failed\n$o$er";
$o eq ''&&$er eq '' or die "timing harness build wrote output\n$o$er";

# Force each selector result in the same emitted ROM.  P0 crosses activity in
# these cases, so success also certifies the exact-byte cache path.  The byte
# that held selected_start in VBLANK becomes the generic-row X restored by the
# shared service; checking it distinguishes all three dynamic resume targets.
my @cases=(
   [start0=>52,2,50,2],
   [start2=>54,2,48,0],
   [start4=>56,2,48,4],
);
for my $case (@cases) {
   my($name,$y0,$rawh0,$y1,$rawh1)=@$case;
   my $h0=($rawh0+1)&255; my $h1=($rawh1+1)&255;
   my $mask=$alias[$y1&7] | $alias[(($y1-$h1)&255)&7];
   my $start=$first[$mask];
   $name eq "start$start" or die "$name selected $start mask=$mask\n";

   my $q1=($y1-48-$start)&255;
   my @p1live=map { (($q1-$_)&255)<$h1 ? 1:0 } 0..2;
   $p1live[0]==$p1live[1] && $p1live[1]==$p1live[2]
      or die "$name selected mixed P1 window\n";
   my $p1ptr=$p1live[0] ? $a{p1_graphics}+$q1-2 : $a{game_stripe_service_zero};
   (!$p1live[0] || $q1>=2) or die "$name active P1 pointer underflow\n";

   my $q0=($y0-49-$start)&255;
   my @want_p0;
   for my $i (0..2) {
      my $q=($q0-$i)&255;
      push @want_p0, $q<$h0 ? $p0_graphics[$q] : 0;
   }
   my @args=(
      $bin,50,'--no-audio','--raw-lines',264,
      '--set-zp',addr($a{game_player0_y}),byte($y0),
      '--set-zp',addr($a{game_player0_height}),byte($rawh0),
      '--set-zp',addr($a{game_player1_y}),byte($y1),
      '--set-zp',addr($a{game_player1_height}),byte($rawh1),
      '--expect-memory',addr($dispatch_state),byte($resume_x{$start}),
      '--expect-memory',addr($a{game_stripe_service_p1_ptr}),byte($p1ptr),
      '--expect-memory',addr($a{game_stripe_service_p1_ptr}+1),byte($p1ptr>>8),
   );
   for my $i (0..2) {
      push @args,'--expect-memory',addr($p0_cache_addr[$i]),byte($want_p0[$i]);
   }
   ($rc,$sig,$o,$er)=capture($timing,@args);
   $rc==0&&!$sig or die "$name runtime P1-cache dispatch failed\n$o$er";
   $o eq "vcs_frame_timing ok: 47 frames at 262 lines, 1 AUDV0 writes\n"
      or die "$name timing output changed: $o";
   $er eq '' or die "$name timing stderr: $er";
}
print "vcs_all_five_stripes2_p1_cache_dispatch_probe ok\n";
