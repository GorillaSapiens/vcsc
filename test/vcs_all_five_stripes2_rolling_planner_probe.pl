#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_all_five_stripes2_rolling_planner_probe ok
# expectexit: 0
use strict; use warnings; use Cwd qw(abs_path); use File::Spec; use IPC::Open3; use Symbol qw(gensym);
sub usage { die "usage: $0 REPO TMP\n"; }
sub slurp_fh { my($fh)=@_; local $/; my $d=<$fh>; return defined($d)?$d:''; }
sub capture { my(@cmd)=@_; my $err=gensym; my $pid=open3(my $in,my $out,$err,@cmd); close($in); my $so=slurp_fh($out); my $se=slurp_fh($err); waitpid($pid,0); return ($?>>8,$?&127,$so,$se); }
sub without_usage { my($out)=@_; $out =~ s/\AMEMORY USAGE\n(?:  [^\n]+\n)+//; return $out; }
sub read_file { my($p)=@_; open(my $f,'<:raw',$p) or die "read $p: $!\n"; local $/; my $d=<$f>; close($f); return defined($d)?$d:''; }
sub map_addr {
   my($map,$name)=@_;
   $map =~ /^\s*\$([0-9A-Fa-f]{4})\s+\Q$name\E\s/m
      or die "map lost symbol $name\n";
   return hex($1);
}
sub byte { sprintf('0x%02x',$_[0]&255) }
sub addr { sprintf('0x%04x',$_[0]&0xffff) }

my $repo=shift @ARGV // usage(); my $tmp=shift @ARGV // usage(); usage() if @ARGV;
$repo=abs_path($repo); $tmp=abs_path($tmp);
my $driver=$ENV{VCSC_DRIVER} || File::Spec->catfile($repo,qw(driver vcsc));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $source=File::Spec->catfile($repo,qw(test fixtures all_five_stripes2_192 refill_dual_pointer.c26));
my $bin=File::Spec->catfile($tmp,'rolling_planner.bin');
my $mapfile=File::Spec->catfile($tmp,'rolling_planner.map');
my($rc,$sig,$o,$er)=capture($driver,'-I',$vcs,'-Map',$mapfile,'-DVCS_STRIPES2_ROLLING_PLANNER_PROBE',$source,'-o',$bin);
$rc==0&&!$sig or die "rolling planner build failed\n$o$er";
without_usage($o) eq ''&&$er eq '' or die "rolling planner build wrote output\n$o$er";
$o =~ /^  ram\s+used=103 bytes .* free=25 bytes/m or die "rolling planner allocated RAM\n$o";
$o =~ /^  rom\s+used=(\d+) bytes/m && $1<=4096 or die "rolling planner no longer fits 4K\n$o";
my $map=read_file($mapfile);
$map =~ /^\s+RODATA\.__vcsc_object\$game_stripe_transition_alias\s+load=\$[0-9A-Fa-f]{4}\s+size=\$0010\b/m
   or die "rolling planner alias table is not 16 bytes\n";
$map =~ /^\s+RODATA\.__vcsc_object\$game_stripe_first_free_start\s+load=\$[0-9A-Fa-f]{4}\s+size=\$0020\b/m
   or die "rolling planner selector table is not 32 bytes\n";
$map =~ /^\s+RODATA\.__vcsc_object\$game_stripe_service_zero\s+load=\$[0-9A-Fa-f]{4}\s+size=\$0003\b/m
   or die "rolling planner zero run is not three bytes\n";

my %a=map { $_=>map_addr($map,$_) } qw(
   game_player0_y game_player1_y game_player0_height game_player1_height
   game_object_masks game_stripe_service_p1_ptr game_stripe_service_p0_ptr
   game_stripe_service_zero p0_graphics p1_graphics
);
my $selected_addr=$a{game_object_masks}+43;

my $cxx=$ENV{CXX}||'c++'; my $mos=File::Spec->catdir($repo,qw(simulator mos6502));
my $old_mos=$ENV{VCSC_MOS6502_OBJECT};
my @mi=$old_mos && -f $old_mos ? ($old_mos) : (-f File::Spec->catfile($mos,'mos6502.o')?(File::Spec->catfile($mos,'mos6502.o')):(File::Spec->catfile($mos,'mos6502.cpp')));
my $timing=File::Spec->catfile($tmp,'rolling_planner_timing');
($rc,$sig,$o,$er)=capture($cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,File::Spec->catfile($repo,qw(test vcs_frame_timing.cpp)),@mi,'-o',$timing);
$rc==0&&!$sig or die "timing harness build failed\n$o$er";
$o eq ''&&$er eq '' or die "timing harness build wrote output\n$o$er";

my @alias=(0,1,1,2,2,4,4,0,0,8,8,16,16,0,0,0);
my @candidates=(1,3,5,9,11);
my @cases=(
   [inactive=>0,0,0,0],
   [start1=>36,3,35,2],
   [start3=>38,3,37,2],
   [start5=>40,3,39,4],
   [start9=>3,0,43,4],
   [start11=>5,0,49,6],
);
for my $case (@cases) {
   my($name,$y0,$rawh0,$y1,$rawh1)=@$case;
   my $h0=($rawh0+1)&255; my $h1=($rawh1+1)&255;
   my $m0=$alias[$y0&15] | $alias[(($y0-$h0)&255)&15];
   my $m1=$alias[$y1&15] | $alias[(($y1-$h1)&255)&15];
   my $mask=$m0|$m1;
   my $start=0;
   for my $i (0..$#candidates) { if (!(($mask>>$i)&1)) { $start=$candidates[$i]; last; } }
   $start or die "$name has no selected candidate\n";
   for my $state ([$y0,$h0,33,'P0'],[$y1,$h1,32,'P1']) {
      my($y,$h,$origin,$who)=@$state;
      my @live=map { (($y-$origin-$start-$_)&255)<$h ? 1:0 } 0..2;
      $live[0]==$live[1] && $live[1]==$live[2]
         or die "$name selected mixed $who window start=$start\n";
   }
   my $q0=($y0-33-$start)&255; my $q1=($y1-32-$start)&255;
   my $p0=$q0<$h0 ? $a{p0_graphics}+$q0-2 : $a{game_stripe_service_zero};
   my $p1=$q1<$h1 ? $a{p1_graphics}+$q1-2 : $a{game_stripe_service_zero};
   ($q0>=$h0 || $q0>=2) or die "$name active P0 pointer underflow\n";
   ($q1>=$h1 || $q1>=2) or die "$name active P1 pointer underflow\n";
   my @args=(
      $bin,50,'--no-audio','--raw-lines',264,
      '--set-zp',addr($a{game_player0_y}),byte($y0),
      '--set-zp',addr($a{game_player0_height}),byte($rawh0),
      '--set-zp',addr($a{game_player1_y}),byte($y1),
      '--set-zp',addr($a{game_player1_height}),byte($rawh1),
      '--expect-memory',addr($selected_addr),byte($start),
      '--expect-memory',addr($a{game_stripe_service_p0_ptr}),byte($p0),
      '--expect-memory',addr($a{game_stripe_service_p0_ptr}+1),byte($p0>>8),
      '--expect-memory',addr($a{game_stripe_service_p1_ptr}),byte($p1),
      '--expect-memory',addr($a{game_stripe_service_p1_ptr}+1),byte($p1>>8),
   );
   ($rc,$sig,$o,$er)=capture($timing,@args);
   $rc==0&&!$sig or die "$name runtime planner failed start=$start\n$o$er";
   $o eq "vcs_frame_timing ok: 47 frames at 262 lines, 1 AUDV0 writes\n"
      or die "$name timing output changed: $o";
   $er eq '' or die "$name timing stderr: $er";
}
print "vcs_all_five_stripes2_rolling_planner_probe ok\n";
