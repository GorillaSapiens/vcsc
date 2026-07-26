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

sub write_file { my ($p,$d)=@_; open(my $f,'>:raw',$p) or die "write $p: $!\n"; print {$f} $d; close($f) or die "close $p: $!\n"; }
sub slurp { my ($p)=@_; open(my $f,'<:raw',$p) or die "read $p: $!\n"; local $/; my $d=<$f>; close($f); return defined($d)?$d:''; }
sub run_capture { my (@c)=@_; my $e=gensym; my $pid=open3(my $in,my $out,$e,@c); close($in); local $/; my $o=<$out>//''; my $x=<$e>//''; waitpid($pid,0); return ($?>>8,$?&127,$o,$x); }
sub require_ok { my ($n,@c)=@_; my ($x,$s,$o,$e)=run_capture(@c); $x==0&&!$s or die "$n failed\n@c\n$o$e"; without_cartridge_usage($o) eq '' or die "$n stdout: $o"; $e eq '' or die "$n stderr: $e"; }
sub get_u16 { my ($d,$pr)=@_; my $p=$$pr; $p+2<=length($$d) or die "truncated o26\n"; my $v=unpack('v',substr($$d,$p,2)); $$pr=$p+2; return $v; }
sub skip_cstr { my ($d,$pr)=@_; my $z=index($$d,"\0",$$pr); $z>=0 or die "unterminated o26 string\n"; my $s=substr($$d,$$pr,$z-$$pr); $$pr=$z+1; return $s; }
sub mark_page_contained {
   my ($path,$want)=@_;
   my $data=slurp($path); length($data)>=27 or die "short o26\n";
   substr($data,0,5) eq "\x01\x00o26" or die "bad o26 magic\n";
   my $p=8;
   my @h=map { get_u16(\$data,\$p) } 1..9;
   my ($tlen,$dlen)=($h[1],$h[3]);
   while (1) { my $n=ord(substr($data,$p++,1)); last if !$n; $p += $n-1; }
   $p += $tlen+$dlen;
   my $n=get_u16(\$data,\$p); skip_cstr(\$data,\$p) for 1..$n;
   for (1..2) {
      while (1) {
         my $delta=ord(substr($data,$p++,1)); last if !$delta; next if $delta==255;
         my $type=ord(substr($data,$p++,1)); my $seg=ord(substr($data,$p++,1));
         $p+=2 if $seg==0; $p++ if $type&0x10;
      }
   }
   $n=get_u16(\$data,\$p);
   for (1..$n) { skip_cstr(\$data,\$p); $p+=3; }
   $n=get_u16(\$data,\$p);
   my $found=0;
   for (1..$n) {
      my $name=skip_cstr(\$data,\$p); $p++; get_u16(\$data,\$p); get_u16(\$data,\$p); $p++; get_u16(\$data,\$p);
      $p < length($data) or die "o26 lacks layout flags\n";
      if ($name eq $want) { substr($data,$p,1)=chr(ord(substr($data,$p,1))|1); $found++; }
      $p += 5; # flags plus indexed-range start/max in current layout records
   }
   if ($p<length($data)) {
      my $magic=substr($data,$p,4);
      ($magic eq "B26\1" || $magic eq "B26\2") or die "unexpected o26 layout tail\n";
      $p+=4;
      my $branches=get_u16(\$data,\$p);
      $p += $branches * ($magic eq "B26\2" ? 7 : 6);
   }
   $p==length($data) or die "unexpected o26 branch tail\n";
   $found==1 or die "layout $want found $found times\n";
   write_file($path,$data);
}

my $repo=abs_path(shift @ARGV // die "usage: $0 REPO TMP\n");
my $tmp=shift @ARGV // die "usage: $0 REPO TMP\n"; @ARGV and die "usage: $0 REPO TMP\n";
make_path($tmp); $tmp=abs_path($tmp);
my $as=File::Spec->catfile($repo,'assembler','vcsc-as');
my $ld=File::Spec->catfile($repo,'linker','vcsc-ld');
my $rt=File::Spec->catfile($repo,'libraries','runtime','libvcsc.l26');
my $cfg=File::Spec->catfile($tmp,'layout.cfg');
write_file($cfg,<<'CFG');
MEMORY {
 ZEROPAGE: start=$0000,size=$0100,type=rw;
 CPUSTACK: start=$0100,size=$0100,type=rw;
 RAM: start=$0200,size=$1E00,type=rw;
 ROM: start=$2000,size=$E000,type=ro;
}
SEGMENTS {
 ZEROPAGE: load=ROM,run=ZEROPAGE,type=zp;
 CODE: load=ROM,type=ro;
 HOT: load=ROM,type=ro;
 HUGE: load=ROM,type=ro;
 DATA: load=ROM,run=RAM,type=data;
 BSS: load=RAM,type=bss;
}
CFG
my $src=File::Spec->catfile($tmp,'fit.s26');
write_file($src,<<'ASM');
.segment "CODE"
.export main
.export __sbpmeta$F$main
__sbpmeta$F$main = 0
.proc main
 rts
.endproc
.res 3
.segment "HOT"
.export hot
hot:
.res 16
ASM
my $obj=File::Spec->catfile($tmp,'fit.o26');
require_ok('assemble fit',$as,'-o',$obj,$src); mark_page_contained($obj,'HOT');
my $map=File::Spec->catfile($tmp,'fit.map');
require_ok('link fit',$ld,'-T',$cfg,'-Map',$map,'-o',File::Spec->catfile($tmp,'fit.bin'),$obj,$rt);
my $m=slurp($map); $m =~ /^\s*\$([0-9A-Fa-f]{4})\s+hot\b/m or die "map lacks hot\n";
my $hot=hex($1); (($hot&255)+16)<=256 or die sprintf("HOT crosses page at %04X\n",$hot);
($hot&255)==0 or die sprintf("earliest deterministic fit was not selected: %04X\n",$hot);

my $badsrc=File::Spec->catfile($tmp,'bad.s26');
write_file($badsrc,<<'ASM');
.segment "CODE"
.export main
.export __sbpmeta$F$main
__sbpmeta$F$main = 0
.proc main
 rts
.endproc
.segment "HUGE"
.res 257
ASM
my $badobj=File::Spec->catfile($tmp,'bad.o26');
require_ok('assemble bad',$as,'-o',$badobj,$badsrc); mark_page_contained($badobj,'HUGE');
my ($exit,$sig,undef,$err)=run_capture($ld,'-T',$cfg,'-o',File::Spec->catfile($tmp,'bad.bin'),$badobj,$rt);
$exit!=0&&!$sig or die "oversized page-contained object unexpectedly linked\n";
$err =~ /hard page containment impossible for HUGE .* size \$0101 exceeds 256 bytes/
 or die "oversized diagnostic was unclear:\n$err";
print "linker hard page containment enforced\n";
