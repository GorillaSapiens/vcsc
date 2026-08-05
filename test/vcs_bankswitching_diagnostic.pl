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
   my($p)=@_; open(my $fh,'<:raw',$p) or die "read $p: $!\n"; local $/;
   my $d=<$fh>; close($fh); return $d // '';
}
sub write_file {
   my($p,$data)=@_; open(my $fh,'>:raw',$p) or die "write $p: $!\n";
   print {$fh} $data or die "write $p: $!\n"; close($fh) or die "close $p: $!\n";
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
   my($pid)=@_; return if !defined($pid) || $pid <= 0;
   kill 'TERM',$pid;
   for (1..20) {
      my $done=waitpid($pid,WNOHANG);
      return if $done==$pid || $done==-1;
      select(undef,undef,undef,0.05);
   }
   kill 'KILL',$pid; waitpid($pid,0);
}

sub profiles {
   return (
      [F8=>2=>'vcs_8k_f8.cfg'=>0],
      [F6=>4=>'vcs_16k_f6.cfg'=>0],
      [F4=>8=>'vcs_32k_f4.cfg'=>0],
      [F8SC=>2=>'vcs_8k_f8sc.cfg'=>1],
      [F6SC=>4=>'vcs_16k_f6sc.cfg'=>1],
      [F4SC=>8=>'vcs_32k_f4sc.cfg'=>1],
   );
}

sub build_matrix_rom {
   my($driver,$vcs,$source,$tmp,$profile,$simulator,$poisoned)=@_;
   my($mapper,$banks,$cfg_name,$sc)=@$profile;
   my $stem=lc($mapper).'_matrix';
   my $bin=File::Spec->catfile($tmp,"$stem.bin");
   my $map_path=File::Spec->catfile($tmp,"$stem.map");
   my @defs=('-DVCS_NO_DEFAULT_ROM',"-DMAPPER_BANKS=$banks");
   push @defs,'-DSUPERCHIP_TEST' if $sc;
   push @defs,'-DSIMULATOR_TEST' if $simulator;
   push @defs,'-DPOISONED_RESULT' if $poisoned;
   require_ok("build $mapper complete matrix",
      $driver,'-I',$vcs,@defs,'-T',File::Spec->catfile($vcs,$cfg_name),
      '-Map',$map_path,$source,'-o',$bin);
   -s $bin == $banks*4096
      or die "$mapper did not emit an exact ".($banks*4096)."-byte image\n";
   return ($bin,$map_path);
}

sub check_matrix_dump {
   my($mapper,$banks,$sym,$mem,$sc)=@_;
   $mem->[$sym->{failure}]==0
      or die sprintf("%s failure byte is %02X\n",$mapper,$mem->[$sym->{failure}]);
   $mem->[$sym->{source_seen}]==$banks-1
      or die "$mapper did not execute the final logical source bank\n";
   $mem->[$sym->{current_source}]==$banks && $mem->[$sym->{current_destination}]==0
      or die "$mapper matrix indices did not reach the terminal state\n";
   $mem->[$sym->{call_count}]==$banks
      or die "$mapper same-bank call count is wrong\n";
   $mem->[$sym->{transition_count}]==$banks*$banks
      or die "$mapper did not execute the complete ordered direct-JMP matrix\n";
   $mem->[$sym->{nested_count}]==1
      or die "$mapper nested cross-bank call count is wrong\n";
   $mem->[$sym->{signature}]==0x80+$banks-1
      or die "$mapper final destination signature is wrong\n";
   $mem->[$sym->{stack_before}]==$mem->[$sym->{stack_after}]
      or die "$mapper direct-JMP path changed the hardware stack\n";
   if ($sc) {
      $mem->[$sym->{sc_bss_head}]==0xC3 &&
      $mem->[$sym->{sc_data_head}]==0x3C &&
      $mem->[$sym->{sc_count}]==0x96 &&
      $mem->[$sym->{sc_bss}]==0x69 &&
      $mem->[$sym->{sc_bss}+123]==0xA6 &&
      $mem->[$sym->{sc_data_tail}]==0x69
         or die "$mapper Superchip reset lifecycle did not finish in the expected poisoned state\n";
      for my $read ($sym->{sc_bss_head},$sym->{sc_count},$sym->{sc_bss},
                    $sym->{sc_bss}+123,$sym->{sc_data_head},$sym->{sc_data_tail}) {
         $mem->[$read-0x80]==$mem->[$read]
            or die sprintf("%s Superchip read/write aliases disagree at %04X/%04X\n",
                           $mapper,$read,$read-0x80);
      }
   }
}

sub run_simulator_matrix {
   my($repo,$tmp,$source)=@_;
   my $driver=File::Spec->catfile($repo,'driver','vcsc');
   my $sim=File::Spec->catfile($repo,'simulator','vcsc-sim');
   my $vcs=File::Spec->catdir($repo,'libraries','vcs');

   for my $profile (profiles()) {
      my($mapper,$banks,$cfg_name,$sc)=@$profile;
      my $cfg=File::Spec->catfile($vcs,$cfg_name);
      if ($sc) {
         my $cfg_text=read_file($cfg);
         $cfg_text =~ /mapper\s*=\s*\Q$mapper\E\s*;/
            or die "$cfg_name does not declare mapper $mapper\n";
         for my $logical_bank (0..$banks-1) {
            my $start=sprintf('%04X',0xF100-$logical_bank*0x2000);
            $cfg_text =~ /\bbank\Q$logical_bank\E\s*:\s*start\s*=\s*\$$start\s*,\s*size\s*=\s*\$0E00\s*,\s*type\s*=\s*ro\b/i
               or die "$cfg_name does not reserve the Superchip prefix in bank$logical_bank\n";
         }
         my $bad=$cfg_text;
         $bad =~ s/(\bbank0\s*:\s*start\s*=\s*)\$F100\s*,\s*size\s*=\s*\$0E00/$1\$F000, size = \$0F00/i
            or die "could not make malformed $mapper Superchip cfg fixture\n";
         my $bad_cfg=File::Spec->catfile($tmp,lc($mapper).'_bad_prefix.cfg');
         write_file($bad_cfg,$bad);
         my($rc,$sig,$out,$err)=run_capture(
            $driver,'-I',$vcs,'-T',$bad_cfg,
            File::Spec->catfile($repo,'examples','01_basic','01_blank_screen','blank_screen.c26'),
            '-o',File::Spec->catfile($tmp,lc($mapper).'_bad_prefix.bin'));
         $rc!=0 && !$sig or die "$mapper malformed Superchip cfg unexpectedly linked\n$out\n$err";
         $err =~ /overlaps the Superchip RAM-port prefix/i
            or die "$mapper malformed Superchip cfg did not diagnose the RAM-port overlap\n$err";
      }

      my($bin,$map_path)=build_matrix_rom($driver,$vcs,$source,$tmp,$profile,1);
      if ($sc) {
         my $rom=read_file($bin);
         for my $file_bank (0..$banks-1) {
            substr($rom,$file_bank*4096,256) eq ("\xFF" x 256)
               or die "$mapper physical/file bank $file_bank does not reserve the Superchip prefix\n";
         }
      }
      my $map=read_file($map_path);
      if ($sc) {
         $map =~ /^\s*superchip\s+used=128 bytes\b.*\bobjects=128 bytes\b/m
            or die "$mapper diagnostic does not own the complete Superchip region\n$map";
         $map =~ /^STARTUP INITIALIZATION\n\s+policy=every-reset bss=zero data=copy-through-write-alias$/m
            or die "$mapper map does not define the reset-time Superchip initialization policy\n$map";
         for my $required (
            qr/^\s+COPY DATA\.superchip\.__vcsc_object\$diagnostic_superchip_data_head\s+load=\$[0-9A-F]{4} read=\$F0FE write=\$F07E size=\$0001 split=yes$/m,
            qr/^\s+COPY DATA\.superchip\.__vcsc_object\$diagnostic_superchip_data_tail\s+load=\$[0-9A-F]{4} read=\$F0FF write=\$F07F size=\$0001 split=yes$/m,
            qr/^\s+ZERO BSS\.superchip\.__vcsc_object\$diagnostic_superchip_bss_head\s+read=\$F080 write=\$F000 size=\$0001 split=yes$/m,
            qr/^\s+ZERO BSS\.superchip\.__vcsc_object\$diagnostic_superchip_count\s+read=\$F081 write=\$F001 size=\$0001 split=yes$/m,
            qr/^\s+ZERO BSS\.superchip\.__vcsc_object\$diagnostic_superchip_bss\s+read=\$F082 write=\$F002 size=\$007C split=yes$/m,
         ) {
            $map =~ $required
               or die "$mapper map does not report complete Superchip DATA/BSS startup initialization\n$map";
         }
      }
      my %sym=map { $_ => map_symbol($map,$_) }
         qw(simulator_done failure signature source_seen current_source current_destination
            call_count transition_count nested_count stack_before stack_after);
      if ($sc) {
         $sym{sc_bss_head}=map_symbol($map,'diagnostic_superchip_bss_head');
         $sym{sc_data_head}=map_symbol($map,'diagnostic_superchip_data_head');
         $sym{sc_count}=map_symbol($map,'diagnostic_superchip_count');
         $sym{sc_bss}=map_symbol($map,'diagnostic_superchip_bss');
         $sym{sc_data_tail}=map_symbol($map,'diagnostic_superchip_data_tail');
      }
      for my $physical_start (0..$banks-1) {
         my @lifecycle=$sc ? ('--split-fill=0xA7',
                                    sprintf('--reset-on-pc=0x%04X',$sym{simulator_done})) : ();
         my($out,$err)=require_ok("simulate $mapper from physical bank $physical_start",
            $sim,'-T',$cfg,"--start-bank=$physical_start",@lifecycle,
            sprintf('--stop-pc=0x%04X',$sym{simulator_done}),'--dump-on-stop',$bin);
         $err eq '' or die "$mapper simulator wrote stderr:\n$err";
         check_matrix_dump($mapper,$banks,\%sym,parse_dump($out),$sc);
      }
   }
}

sub run_stella_certification {
   my($repo,$tmp,$source)=@_;
   my $stella=$ENV{VCSC_STELLA} || $ENV{STELLA} || find_executable('stella');
   defined($stella) && -x $stella
      or die "Stella certification requires STELLA=/path/to/stella or Stella in PATH\n";
   my $xvfb=find_executable('Xvfb') or die "Stella certification requires Xvfb\n";
   my $perl=find_executable('perl') or die "Stella certification requires Perl\n";
   my $keys=File::Spec->catfile($repo,'test','stella_snapshot_keys.pl');
   my $grade=File::Spec->catfile($repo,'test','stella_grade_bank_snapshot.pl');
   -f $keys && -f $grade or die "Stella snapshot helpers are missing\n";

   my $driver=File::Spec->catfile($repo,'driver','vcsc');
   my $vcs=File::Spec->catdir($repo,'libraries','vcs');
   my $stella_tmp=File::Spec->catdir($tmp,'stella');
   my $snap_root=File::Spec->catdir($stella_tmp,'snapshots');
   my $user_root=File::Spec->catdir($stella_tmp,'user');
   make_path($snap_root,$user_root);
   my $display_num=90+($$%100);
   my $selected=sub {
      my($label)=@_; return !$ENV{VCSC_STELLA_FILTER} || $label =~ /$ENV{VCSC_STELLA_FILTER}/;
   };

   my $run_one=sub {
      my(%arg)=@_; my $label=$arg{label}; return unless $selected->($label);
      $display_num++ while -e "/tmp/.X11-unix/X$display_num";
      my $display=':'.$display_num++;
      my $xpid=fork(); defined($xpid) or die "fork Xvfb: $!\n";
      if ($xpid==0) {
         open(STDOUT,'>:raw',File::Spec->catfile($stella_tmp,"$label.xvfb.log")) or die $!;
         open(STDERR,'>&STDOUT') or die $!;
         exec($xvfb,$display,'-ac','-screen','0','1024x768x24'); die "exec Xvfb: $!\n";
      }
      select(undef,undef,undef,0.20);
      local $ENV{DISPLAY}=$display; local $ENV{XAUTHORITY}='/dev/null';
      local $ENV{HOME}=$stella_tmp; local $ENV{SDL_AUDIODRIVER}='dummy';
      my $snapdir=File::Spec->catdir($snap_root,$label); make_path($snapdir);
      unlink glob(File::Spec->catfile($snapdir,'*.png'));
      my $run_user=File::Spec->catdir($user_root,$label); make_path($run_user);
      my @cmd=($stella,'-video','software','-turbo','1','-audio.enabled','0',
               '-bs',$arg{mapper},'-snapsavedir',$snapdir,'-snapname','rom',
               '-sssingle','1','-ss1x','1','-exitlauncher','0','-confirmexit','0',
               '-userdir',$run_user);
      push @cmd,'-startbank',$arg{start} if defined $arg{start};
      push @cmd,'-dev.settings','1','-dev.bankrandom','1' if $arg{random};
      push @cmd,$arg{rom};
      my $pid=fork(); defined($pid) or die "fork Stella: $!\n";
      if ($pid==0) {
         open(STDOUT,'>:raw',File::Spec->catfile($stella_tmp,"$label.log")) or die $!;
         open(STDERR,'>&STDOUT') or die $!; exec(@cmd); die "exec Stella: $!\n";
      }
      print STDERR "Stella $label\n" if $ENV{VCSC_STELLA_VERBOSE};
      my($graded,$last_grade_error)=(0,'');
      for my $attempt (1..3) {
         unlink glob(File::Spec->catfile($snapdir,'*.png'));
         my @key_args=$arg{reset} ? ('--reset') : ();
         require_ok("snapshot $label attempt $attempt",$perl,$keys,@key_args);
         my @png;
         for (1..40) {
            @png=grep { -s $_ } glob(File::Spec->catfile($snapdir,'*.png'));
            last if @png==1; select(undef,undef,undef,0.05);
         }
         if (@png!=1) {
            $last_grade_error="Stella $label produced ".scalar(@png).
                              " snapshots on attempt $attempt\n";
            next;
         }
         my($rc,$sig,$out,$err)=run_capture($perl,$grade,$png[0],$arg{result} // 'pass');
         if ($rc==0 && !$sig && $err eq '') {
            $graded=1;
            last;
         }
         $last_grade_error="grade Stella frame $label attempt $attempt failed " .
                           "rc=$rc sig=$sig\nstdout:\n$out\nstderr:\n$err";
      }
      terminate_child($pid);
      terminate_child($xpid);
      $graded or die $last_grade_error;
   };

   for my $profile (profiles()) {
      my($mapper,$banks,undef,$sc)=@$profile;
      my @runs;
      for my $physical_start (0..$banks-1) {
         push @runs,{label=>lc($mapper)."_forced_start_$physical_start",
                     mapper=>$mapper,start=>$physical_start,reset=>$sc};
      }
      for my $trial (0..$banks-1) {
         push @runs,{label=>lc($mapper)."_random_start_$trial",
                     mapper=>$mapper,random=>1,reset=>$sc};
      }
      @runs=grep { $selected->($_->{label}) } @runs;
      next unless @runs; # A focused filter must not build unrelated cartridges.
      my($rom)=build_matrix_rom($driver,$vcs,$source,$stella_tmp,$profile,0);
      for my $run (@runs) {
         $run->{rom}=$rom;
         $run_one->(%$run);
      }
   }
   if ($selected->('poisoned_failure')) {
      my $profile=[F8SC=>2=>'vcs_8k_f8sc.cfg'=>1];
      my($rom)=build_matrix_rom($driver,$vcs,$source,$stella_tmp,$profile,0,1);
      $run_one->(label=>'poisoned_failure',mapper=>'F8SC',start=>0,reset=>1,
                 rom=>$rom,result=>'fail');
   }
   print "Stella bank switching certification passed\n";
}

my $repo=abs_path(shift @ARGV // die "usage: $0 REPO TMP [--stella]\n");
my $tmp=shift @ARGV // die "usage: $0 REPO TMP [--stella]\n";
my $stella_mode=@ARGV && $ARGV[0] eq '--stella' ? shift(@ARGV) : '';
@ARGV and die "usage: $0 REPO TMP [--stella]\n";
make_path($tmp); $tmp=abs_path($tmp) // die "resolve temp\n";
my $source=File::Spec->catfile($repo,'libraries','vcs','bankswitching_diagnostic_suite.c26');
my $source_text=read_file($source);
$source_text =~ /superchip\s+uint8_t\s+diagnostic_superchip_bss_head\s*;/ &&
$source_text =~ /superchip\s+uint8_t\s+diagnostic_superchip_data_head\s*:=\s*0x5A\s*;/ &&
$source_text =~ /superchip\s+uint8_t\s+diagnostic_superchip_count\s*;/ &&
$source_text =~ /superchip\s+uint8_t\s+diagnostic_superchip_bss\s*\[124\]\s*;/ &&
$source_text =~ /superchip\s+uint8_t\s+diagnostic_superchip_data_tail\s*:=\s*0xA5\s*;/
   or die "diagnostic Superchip probe does not own the mixed 128-byte BSS/DATA region\n";
$source_text !~ /diagnostic_superchip_ram/
   or die "diagnostic still uses the obsolete raw Superchip probe\n";
$source_text =~ /void\s+validate_superchip_startup\s*\(void\)/ &&
$source_text =~ /void\s+poison_superchip_before_result\s*\(void\)/
   or die "diagnostic Superchip startup validation/reset poisoning helpers are missing\n";
$source_text =~ /BANK_DIAGNOSTIC_GLYPH\(\s*0b\.XXXXX\.\.,\s*0b\.XX\.\.XX\.,\s*0b\.XX\.\.XX\.,\s*0b\.XXXXX\.\.,\s*0b\.XX\.\.\.\.\.,\s*0b\.XX\.\.\.\.\.,\s*0b\.XX\.\.\.\.\.,\s*0b\.XX\.\.\.\.\.\s*\)/s
   or die "diagnostic PASS glyph is not the default-font P\n";
$source_text =~ /BANK_DIAGNOSTIC_GLYPH\(\s*0b\.XXXXXX\.,\s*0b\.XX\.\.\.\.\.,\s*0b\.XX\.\.\.\.\.,\s*0b\.XXXXX\.\.,\s*0b\.XX\.\.\.\.\.,\s*0b\.XX\.\.\.\.\.,\s*0b\.XX\.\.\.\.\.,\s*0b\.XX\.\.\.\.\.\s*\)/s
   or die "diagnostic FAIL glyph is not the default-font F\n";
$source_text =~ /lda\s+fail_glyph,x.*lda\s+pass_glyph,x.*sta\s+WSYNC.*sta\s+GRP0/s
   or die "diagnostic glyph loads must use ordinary indexed syntax and remain scanline-aligned\n";
$source_text !~ /lda\.ax\s+(?:fail|pass)_glyph,x/
   or die "diagnostic still papers over assembler relaxation with explicit .ax\n";
$source_text =~ /lda\s+#\$0E\s*;\s*asm\s+sta\s+COLUP0/s
   or die "diagnostic status glyph is not white\n";
$source_text =~ /\@status_frame_loop:.*ldx\s+#3.*ldx\s+#35.*ldx\s+#76.*ldx\s+#7.*ldx\s+#99.*ldx\s+#29.*jmp\s+\@status_frame_loop/s
   or die "diagnostic frame schedule does not produce Stella's exact 262-line NTSC frame\n";
$source_text =~ /#ifdef\s+POISONED_RESULT\s+failure\s*:=\s*1/s
   or die "diagnostic poisoned-result build hook is missing\n";
if ($stella_mode) { run_stella_certification($repo,$tmp,$source); }
else { run_simulator_matrix($repo,$tmp,$source); }
print "bank switching diagnostic matrix passed\n";
