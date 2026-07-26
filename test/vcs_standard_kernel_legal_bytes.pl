#!/usr/bin/perl
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub without_cartridge_usage {
   my ($out) = @_;
   $out =~ s/\ACARTRIDGE ROM USAGE\n(?:  [^\n]+\n)+RAM USAGE\n(?:  [^\n]+\n)+//;
   return $out;
}

sub usage { die "usage: $0 REPO TMP\n"; }
sub read_file {
   my ($path)=@_;
   open(my $fh,'<:raw',$path) or die "read $path: $!\n";
   local $/; my $d=<$fh>; close($fh); return defined($d)?$d:'';
}
sub write_file {
   my ($path,$data)=@_;
   open(my $fh,'>:raw',$path) or die "write $path: $!\n";
   print {$fh} $data; close($fh);
}
sub capture {
   my (@cmd)=@_;
   my $err=gensym;
   my $pid=open3(my $in,my $out,$err,@cmd);
   close($in);
   local $/; my $so=<$out>//''; my $se=<$err>//'';
   waitpid($pid,0);
   return ($? >> 8,$? & 127,$so,$se);
}
sub map_symbol {
   my ($map,$name)=@_;
   $map =~ /^\$([0-9A-Fa-f]{8})\s+\Q$name\E\s*$/m
      or die "object map is missing $name\n";
   return hex($1);
}
sub official_opcodes {
   my ($cfg)=@_;
   my %mode_len=(
      imp=>1, acc=>1,
      imm=>2, zp=>2, zpx=>2, zpy=>2, indx=>2, indy=>2, rel=>2,
      abs=>3, absx=>3, absy=>3, ind=>3,
   );
   my %op;
   for my $line (split(/\n/,read_file($cfg))) {
      $line =~ s/#.*//;
      next unless $line =~ /^\s*([A-Za-z][A-Za-z0-9]*)\s+(\w+)\s+\$([0-9A-Fa-f]{2})\s*$/;
      my ($mnemonic,$mode,$hex)=($1,$2,$3);
      next if $mnemonic =~ /^op[0-9A-Fa-f]{2}$/i;
      exists($mode_len{$mode}) or die "unknown opcode mode $mode in $cfg\n";
      my $byte=hex($hex);
      exists($op{$byte}) and die sprintf("duplicate official opcode %02X\n",$byte);
      $op{$byte}=[$mnemonic,$mode,$mode_len{$mode}];
   }
   scalar(keys(%op))==151
      or die "default opcode table has ".scalar(keys(%op))." official NMOS opcodes, expected 151\n";
   return \%op;
}
sub executable_segments {
   my ($map)=@_;
   my @segments;
   for my $line (split(/\n/,$map)) {
      next unless $line =~ /^\s+(CODE(?:\.__\S+)?|KERNEL_CODE)\s+load=\$([0-9A-Fa-f]{4})\s+size=\$([0-9A-Fa-f]{4})\b/;
      my ($name,$load,$size)=($1,hex($2),hex($3));
      push @segments,[$name,$load,$size] if $size;
   }
   return @segments;
}
sub scan_segment {
   my ($rom,$rom_base,$segment,$official,$skips)=@_;
   my ($name,$load,$size)=@$segment;
   $load >= $rom_base && $load+$size <= $rom_base+length($rom)
      or return (0,sprintf("%s lies outside ROM: \$%04X+\$%04X",$name,$load,$size));
   my @skip=sort {$a->[0] <=> $b->[0]} @$skips;
   my $off=0;
   my $count=0;
   while ($off < $size) {
      if (@skip && $off == $skip[0][0]) {
         my ($start,$end)=@{shift @skip};
         return ($count,"invalid data skip in $name")
            unless $start >= 0 && $end > $start && $end <= $size;
         $off=$end;
         next;
      }
      if (@skip && $off > $skip[0][0]) {
         return ($count,sprintf("instruction stream entered data range at %s+\$%04X",$name,$off));
      }
      my $rom_off=$load-$rom_base+$off;
      my $opcode=ord(substr($rom,$rom_off,1));
      my $entry=$official->{$opcode};
      return ($count,sprintf("unofficial opcode \$%02X at \$%04X in %s",$opcode,$load+$off,$name))
         unless defined($entry);
      my $len=$entry->[2];
      return ($count,sprintf("truncated %s at \$%04X in %s",$entry->[0],$load+$off,$name))
         if $off+$len > $size;
      if (@skip && $off < $skip[0][0] && $off+$len > $skip[0][0]) {
         return ($count,sprintf("instruction at \$%04X crosses data range in %s",$load+$off,$name));
      }
      $off += $len;
      ++$count;
   }
   return ($count,undef);
}
sub scan_profile {
   my ($rom,$map,$official,$layout)=@_;
   my $rom_base=0x10000-length($rom);
   my @segments=executable_segments($map);
   @segments==7 or return (0,"linked profile has ".scalar(@segments)." executable segments, expected 7");
   my %seen;
   my $instructions=0;
   for my $segment (@segments) {
      my ($name)=@$segment;
      $seen{$name}++;
      my @skips;
      if ($name eq 'KERNEL_CODE') {
         @skips=([$layout->{repostable}-16,$layout->{repostable}]);
      } elsif ($name eq 'CODE.__vcsc_function$vcs_standard_prepare_object_masks') {
         @skips=([$layout->{start_bits},$layout->{helper_end}]);
      }
      my ($count,$error)=scan_segment($rom,$rom_base,$segment,$official,\@skips);
      return ($instructions+$count,$error) if defined($error);
      $instructions += $count;
   }
   for my $required ('CODE','KERNEL_CODE','CODE.__vcsc_function$vcs_standard_prepare_object_masks',
      'CODE.__vcsc_function$__weak_vcs_standard_overscan_hook') {
      $seen{$required} or return ($instructions,"linked profile is missing executable segment $required");
   }
   return ($instructions,undef);
}
sub build_profile {
   my ($driver,$vcs,$profile,$cfg,$source,$kernel,$bin,$map)=@_;
   my ($rc,$sig,$out,$err)=capture(
      $driver,'-I',$vcs,'-I',$profile,'-T',$cfg,'-Map',$map,
      $source,$kernel,'-o',$bin);
   $rc==0 && !$sig or die "profile build failed\nstdout:\n$out\nstderr:\n$err";
   without_cartridge_usage($out) eq '' or die "profile build wrote stdout:\n$out";
   $err eq '' or die "profile build wrote stderr:\n$err";
}

my $repo=shift @ARGV // usage();
my $tmp=shift @ARGV // usage();
usage() if @ARGV;
$repo=abs_path($repo) // die "resolve repository\n";
make_path($tmp);
$tmp=abs_path($tmp) // die "resolve temporary directory\n";

my $driver=File::Spec->catfile($repo,'driver','vcsc');
my $assembler=File::Spec->catfile($repo,'assembler','vcsc-as');
my $default_cfg=File::Spec->catfile($repo,'assembler','default.cfg');
my $vcs=File::Spec->catdir($repo,'libraries','vcs');
my $profile=File::Spec->catdir($vcs,'kernels','standard_4k_ntsc');
my $cfg=File::Spec->catfile($profile,'vcs_standard_4k_ntsc.cfg');
my $kernel=File::Spec->catfile($profile,'standard_4k_ntsc_kernel.s26');
my $source=File::Spec->catfile($repo,'test','fixtures','vcs_examples','05_static_kernel','golden.c26');
my $object=File::Spec->catfile($tmp,'standard_4k_ntsc_kernel.o26');
my $object_map=File::Spec->catfile($tmp,'standard_4k_ntsc_kernel.map');

my ($rc,$sig,$out,$err)=capture(
   $assembler,'-I',$profile,"--map=$object_map",'-o',$object,$kernel);
$rc==0 && !$sig or die "plain kernel assembly failed\nstdout:\n$out\nstderr:\n$err";
without_cartridge_usage($out) eq '' or die "plain kernel assembly wrote stdout:\n$out";
$err eq '' or die "plain kernel assembly wrote stderr:\n$err";
my $omap=read_file($object_map);
my %layout=(
   repostable=>map_symbol($omap,'vcs_standard_kernel_drawscreen::@repostable'),
   start_bits=>map_symbol($omap,'vcs_standard_prepare_object_masks::@start_bits'),
   end_bits=>map_symbol($omap,'vcs_standard_prepare_object_masks::@end_bits'),
   helper_end=>map_symbol($omap,'CODE.__vcsc_function$vcs_standard_prepare_object_masks_END'),
);
$layout{end_bits}==$layout{start_bits}+8
   or die "start-bit table is not eight bytes\n";
$layout{helper_end}==$layout{end_bits}+8
   or die "end-bit table is not eight bytes at the end of its function segment\n";
$layout{repostable}>=16 or die "reposition table location is invalid\n";

my $official=official_opcodes($default_cfg);
my $bin=File::Spec->catfile($tmp,'legal_profile.bin');
my $map=File::Spec->catfile($tmp,'legal_profile.map');
build_profile($driver,$vcs,$profile,$cfg,$source,$kernel,$bin,$map);
my $rom=read_file($bin);
length($rom)==4096 or die "legal profile is not a 4096-byte cartridge\n";
my ($count,$error)=scan_profile($rom,read_file($map),$official,\%layout);
defined($error) and die "legal linked profile failed opcode gate: $error\n";
$count>800 or die "linked opcode gate decoded only $count instructions\n";

# Raw opXX spellings intentionally remain available without --illegals. Prove
# that the linked-byte gate catches that escape hatch rather than relying only
# on mnemonic rejection in the assembler.
my $bad_kernel=File::Spec->catfile($tmp,'standard_4k_ntsc_illegal_probe.s26');
my $bad_text=read_file($kernel);
my $replaced=($bad_text =~ s/^\s*and\s+#\$F0\s*$/     op4B #\$F0/m);
$replaced==1 or die "could not inject the raw-opcode linked-byte probe\n";
write_file($bad_kernel,$bad_text);
my $bad_bin=File::Spec->catfile($tmp,'illegal_profile.bin');
my $bad_map=File::Spec->catfile($tmp,'illegal_profile.map');
build_profile($driver,$vcs,$profile,$cfg,$source,$bad_kernel,$bad_bin,$bad_map);
my ($bad_count,$bad_error)=scan_profile(read_file($bad_bin),read_file($bad_map),$official,\%layout);
defined($bad_error) or die "linked-byte gate accepted injected raw op4B\n";
$bad_error =~ /unofficial opcode \$4B\b/
   or die "linked-byte gate reported the wrong injected failure: $bad_error\n";
$bad_count>0 or die "linked-byte negative probe failed before decoding code\n";

print "vcs_standard_kernel_legal_bytes ok\n";
