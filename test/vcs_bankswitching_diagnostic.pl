#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 240
# expectstdout: bank switching diagnostic matrix passed
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use POSIX qw(:sys_wait_h);
use Symbol qw(gensym);

sub slurp_fh { my($fh)=@_; local $/; return <$fh> // ''; }
sub run_capture {
   my(@cmd)=@_; my $err=gensym; my $pid=open3(my $in,my $out,$err,@cmd); close($in);
   my $so=slurp_fh($out); my $se=slurp_fh($err); waitpid($pid,0);
   return ($? >> 8,$? & 127,$so,$se);
}
sub require_ok {
   my($label,@cmd)=@_; my($rc,$sig,$out,$err)=run_capture(@cmd);
   $rc==0 && !$sig or die "$label failed rc=$rc sig=$sig\n@cmd\nstdout:\n$out\nstderr:\n$err";
   return ($out,$err);
}
sub read_file {
   my($p)=@_; open(my $fh,'<:raw',$p) or die "read $p: $!\n"; local $/; my $d=<$fh>; close($fh); return $d // '';
}
sub map_symbol {
   my($map,$name)=@_; $map =~ /^\s*\$([0-9A-Fa-f]{4})\s+\Q$name\E\b/m
      or die "map is missing $name\n"; return hex($1);
}
sub parse_dump {
   my($text)=@_; my @mem=(0) x 65536;
   for my $line (split /\n/,$text) {
      next unless $line =~ /^:([0-9A-Fa-f]{2})([0-9A-Fa-f]{4})00([0-9A-Fa-f]*)([0-9A-Fa-f]{2})$/;
      my($n,$a,$data)=(hex($1),hex($2),$3);
      length($data)==$n*2 or die "bad Intel HEX dump record\n";
      for my $i (0..$n-1) { $mem[$a+$i]=hex(substr($data,$i*2,2)); }
   }
   return \@mem;
}

sub find_executable {
   my($name)=@_;
   return abs_path($name) if $name =~ m{/} && -x $name;
   for my $dir (split(/:/,$ENV{PATH} // '')) {
      my $candidate=File::Spec->catfile($dir,$name);
      return abs_path($candidate) if -x $candidate;
   }
   return undef;
}
sub terminate_child {
   my($pid)=@_;
   return if !defined($pid) || $pid <= 0;
   kill 'TERM',$pid;
   for (1..20) {
      my $done=waitpid($pid,WNOHANG);
      return if $done==$pid || $done==-1;
      select(undef,undef,undef,0.05);
   }
   kill 'KILL',$pid;
   waitpid($pid,0);
}
sub wait_for_exit {
   my($pid,$seconds)=@_;
   my $ticks=int($seconds*20);
   for (1..$ticks) {
      my $done=waitpid($pid,WNOHANG);
      return $? >> 8 if $done==$pid;
      select(undef,undef,undef,0.05);
   }
   kill 'TERM',$pid;
   select(undef,undef,undef,0.2);
   my $done=waitpid($pid,WNOHANG);
   if ($done!=$pid) { kill 'KILL',$pid; waitpid($pid,0); }
   die "Stella did not exit after snapshot hotkeys\n";
}
sub run_stella_certification {
   my($repo,$tmp,$source,$profiles)=@_;
   my $stella=$ENV{VCSC_STELLA} || $ENV{STELLA} || find_executable('stella');
   defined($stella) && -x $stella
      or die "Stella certification requires STELLA=/path/to/stella or Stella in PATH\n";
   my $xvfb=find_executable('Xvfb')
      or die "Stella certification requires Xvfb\n";
   my $python=find_executable('python3')
      or die "Stella certification requires python3 with python-xlib and Pillow\n";
   require_ok('check Stella Python modules',$python,'-c','import Xlib, PIL');

   my $keys=File::Spec->catfile($repo,'test','stella_snapshot_keys.py');
   my $grade=File::Spec->catfile($repo,'test','stella_grade_bank_snapshot.py');
   -f $keys && -f $grade or die "Stella snapshot helpers are missing\n";
   my $stella_tmp=File::Spec->catdir($tmp,'stella');
   my $snap_root=File::Spec->catdir($stella_tmp,'snapshots');
   my $user_dir=File::Spec->catdir($stella_tmp,'user');
   make_path($snap_root,$user_dir);

   my $display_num=90 + ($$ % 100);

   my $run_one=sub {
      my(%arg)=@_;
      my $label=$arg{label};
      return if $ENV{VCSC_STELLA_FILTER} && $label !~ /$ENV{VCSC_STELLA_FILTER}/;
      $display_num++ while -e "/tmp/.X11-unix/X$display_num";
      my $display=":$display_num";
      $display_num++;
      my $xlog=File::Spec->catfile($stella_tmp,"$label.xvfb.log");
      my $xpid=fork();
      defined($xpid) or die "fork Xvfb: $!\n";
      if ($xpid==0) {
         open(STDOUT,'>:raw',$xlog) or die "open $xlog: $!\n";
         open(STDERR,'>&STDOUT') or die "dup Xvfb stderr: $!\n";
         exec($xvfb,$display,'-ac','-screen','0','1024x768x24');
         die "exec Xvfb: $!\n";
      }
      select(undef,undef,undef,0.20);
      local $ENV{DISPLAY}=$display;
      local $ENV{XAUTHORITY}='/dev/null';
      local $ENV{HOME}=$stella_tmp;
      local $ENV{SDL_AUDIODRIVER}='dummy';
      my $snapdir=File::Spec->catdir($snap_root,$label);
      make_path($snapdir);
      unlink glob(File::Spec->catfile($snapdir,'*.png'));
      my $log=File::Spec->catfile($stella_tmp,"$label.log");
      my $run_user_dir=File::Spec->catdir($user_dir,$label);
      make_path($run_user_dir);
      my @cmd=($stella,'-video','software','-turbo','1','-audio.enabled','0',
               '-bs',$arg{mapper},'-snapsavedir',$snapdir,'-snapname','rom',
               '-sssingle','1','-ss1x','1','-exitlauncher','0','-confirmexit','0',
               '-userdir',$run_user_dir);
      push @cmd,'-startbank',$arg{start} if defined $arg{start};
      push @cmd,'-dev.settings','1','-dev.bankrandom','1' if $arg{random};
      push @cmd,$arg{rom};
      my $pid=fork();
      defined($pid) or die "fork Stella: $!\n";
      if ($pid==0) {
         open(STDOUT,'>:raw',$log) or die "open $log: $!\n";
         open(STDERR,'>&STDOUT') or die "dup Stella stderr: $!\n";
         exec(@cmd);
         die "exec Stella: $!\n";
      }
      print STDERR "Stella $label\n" if $ENV{VCSC_STELLA_VERBOSE};
      require_ok("snapshot $label",$python,$keys);
      my @png;
      for (1..40) {
         @png=grep { -s $_ } glob(File::Spec->catfile($snapdir,'*.png'));
         last if @png==1;
         select(undef,undef,undef,0.05);
      }
      terminate_child($pid);
      @png==1 or die "Stella $label produced ".scalar(@png)." snapshots\n".read_file($log);
      my($grade_out,$grade_err)=require_ok("grade Stella frame $label",$python,$grade,$png[0]);
      $grade_err eq '' or die "snapshot grader wrote stderr for $label: $grade_err\n";
      terminate_child($xpid);
   };

   eval {
      my $driver=File::Spec->catfile($repo,'driver','vcsc');
      my $vcs=File::Spec->catdir($repo,'libraries','vcs');
      my %representative;
      for my $profile (@$profiles) {
         my($mapper,$banks,$cfg_name)=@$profile;
         my $cfg=File::Spec->catfile($vcs,$cfg_name);
         for my $source_bank (0..$banks-1) {
            for my $dest_bank (0..$banks-1) {
               my $stem=lc($mapper)."_${source_bank}_${dest_bank}_stella";
               my $rom=File::Spec->catfile($stella_tmp,"$stem.bin");
               require_ok("build Stella $mapper source $source_bank JMP $dest_bank",
                  $driver,'-I',$vcs,"-DMAPPER_BANKS=$banks","-DSOURCE_BANK=$source_bank",
                  "-DJUMP_DEST=$dest_bank",'-T',$cfg,$source,'-o',$rom);
               $run_one->(label=>$stem,mapper=>$mapper,start=>0,rom=>$rom);
               $representative{$mapper}=$rom if $source_bank==0 && $dest_bank==0;
            }
         }
         for my $physical_start (0..$banks-1) {
            $run_one->(label=>lc($mapper)."_forced_start_$physical_start",
                      mapper=>$mapper,start=>$physical_start,rom=>$representative{$mapper});
         }
         for my $trial (0..$banks-1) {
            $run_one->(label=>lc($mapper)."_random_start_$trial",
                      mapper=>$mapper,random=>1,rom=>$representative{$mapper});
         }
      }
      1;
   } or do {
      my $error=$@ || 'unknown Stella certification failure';
      die $error;
   };
   print "Stella bank switching certification passed\n";
}

my $repo=abs_path(shift @ARGV // die "usage: $0 REPO TMP [--stella]\n");
my $tmp=shift @ARGV // die "usage: $0 REPO TMP [--stella]\n";
my $stella_mode = @ARGV && $ARGV[0] eq '--stella' ? shift(@ARGV) : '';
@ARGV and die "usage: $0 REPO TMP [--stella]\n";
make_path($tmp); $tmp=abs_path($tmp) // die "resolve temp\n";

my $driver=File::Spec->catfile($repo,'driver','vcsc');
my $sim=File::Spec->catfile($repo,'simulator','vcsc-sim');
my $vcs=File::Spec->catdir($repo,'libraries','vcs');
my $source=File::Spec->catfile($vcs,'bankswitching_diagnostic_suite.c26');
my @profiles=(
   [F8=>2=>'vcs_8k_f8.cfg'],
   [F6=>4=>'vcs_16k_f6.cfg'],
   [F4=>8=>'vcs_32k_f4.cfg'],
);
my %built;

for my $profile (@profiles) {
   my($mapper,$banks,$cfg_name)=@$profile;
   my $cfg=File::Spec->catfile($vcs,$cfg_name);
   for my $source_bank (0..$banks-1) {
      for my $dest_bank (0..$banks-1) {
         my $stem=lc($mapper)."_${source_bank}_${dest_bank}";
         my $bin=File::Spec->catfile($tmp,"$stem.bin");
         my $map_path=File::Spec->catfile($tmp,"$stem.map");
         require_ok("build $mapper source $source_bank JMP $dest_bank",
            $driver,'-I',$vcs,
            "-DMAPPER_BANKS=$banks","-DSOURCE_BANK=$source_bank",
            "-DJUMP_DEST=$dest_bank",'-DSIMULATOR_TEST',
            '-T',$cfg,'-Map',$map_path,$source,'-o',$bin);
         my $map=read_file($map_path);
         my %sym=map { $_ => map_symbol($map,$_) }
            qw(simulator_done failure source_seen transition_count stack_before stack_after);
         my($out,$err)=require_ok("simulate $mapper source $source_bank JMP $dest_bank",
            $sim,'-T',$cfg,'--start-bank=0',sprintf('--stop-pc=0x%04X',$sym{simulator_done}),
            '--dump-on-stop',$bin);
         $err eq '' or die "$mapper simulator wrote stderr:\n$err";
         my $mem=parse_dump($out);
         $mem->[$sym{failure}]==0
            or die sprintf("%s %u->%u failure byte is %02X\n",$mapper,$source_bank,$dest_bank,$mem->[$sym{failure}]);
         $mem->[$sym{source_seen}]==$source_bank
            or die "$mapper source signature is wrong for BANK$source_bank\n";
         $mem->[$sym{transition_count}]==$banks+1
            or die "$mapper transition count is wrong for BANK$source_bank->$dest_bank\n";
         $mem->[$sym{stack_before}]==$mem->[$sym{stack_after}]
            or die "$mapper direct JMP path changed the hardware stack\n";
         $built{"$mapper:0:0"}=[$bin,$map_path,\%sym] if $source_bank==0 && $dest_bank==0;
      }
   }

   my($bin,$map_path,$sym) = @{$built{"$mapper:0:0"}};
   for my $physical_start (0..$banks-1) {
      my($out,$err)=require_ok("simulate $mapper reset from physical bank $physical_start",
         $sim,'-T',$cfg,"--start-bank=$physical_start",
         sprintf('--stop-pc=0x%04X',$sym->{simulator_done}),'--dump-on-stop',$bin);
      my $mem=parse_dump($out);
      $mem->[$sym->{failure}]==0
         or die "$mapper reset bridge failed from physical bank $physical_start\n";
   }
}

if ($stella_mode) {
   run_stella_certification($repo,$tmp,$source,\@profiles);
}
print "bank switching diagnostic matrix passed\n";
