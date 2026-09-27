#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_all_five_stripes2_drift ok
# expectexit: 0
use strict;use warnings;use Cwd qw(abs_path);use File::Spec;use IPC::Open3;use Symbol qw(gensym);
sub u{die"usage: $0 REPO TMP\n"}sub sf{my($f)=@_;local$/;<$f>//''}sub c{my@x=@_;my$e=gensym;my$p=open3(my$i,my$o,$e,@x);close$i;my$a=sf$o;my$b=sf$e;waitpid$p,0;return($?>>8,$?&127,$a,$b)}sub nu{my($o)=@_;$o=~s/\AMEMORY USAGE\n(?:  [^\n]+\n)+//;$o}
my$r=shift@ARGV//u;my$t=shift@ARGV//u;u if@ARGV;$r=abs_path$r;$t=abs_path$t;my$d=File::Spec->catfile($r,qw(driver vcsc));my$v=File::Spec->catdir($r,qw(libraries vcs));my$s=File::Spec->catfile($r,qw(test fixtures all_five_stripes2_192 drift.c26));my$b=File::Spec->catfile($t,'d.bin');my($rc,$sg,$o,$e)=c($d,'-I',$v,$s,'-o',$b);$rc==0&&!$sg or die"build failed\n$o$e";nu($o)eq''&&$e eq''or die"build output\n$o$e";-s$b==4096 or die"ROM not 4K\n";my$cxx=$ENV{CXX}||'c++';my$mos=File::Spec->catdir($r,qw(simulator mos6502));my$mo=File::Spec->catfile($mos,'mos6502.o');my@mi=-f$mo?($mo):(File::Spec->catfile($mos,'mos6502.cpp'));my$h=File::Spec->catfile($t,'h');($rc,$sg,$o,$e)=c($cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,File::Spec->catfile($r,qw(test vcs_all_five_composition.cpp)),@mi,'-o',$h);$rc==0&&!$sg or die"harness build failed\n$o$e";($rc,$sg,$o,$e)=c($h,$b,'none','drift');$rc==0&&!$sg or die"drift failed\n$o$e";$o eq"vcs_all_five_composition drift none ok\n"or die"drift output: $o";$e eq''or die"stderr: $e";print"vcs_all_five_stripes2_drift ok\n";
