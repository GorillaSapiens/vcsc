#!/usr/bin/perl
# runner: perl @FILE@ @REPO@
# phase: compile
# timeout: 30
# expectstdout: Inline profit metrics unit passed
# expectexit: 0

use strict;
use warnings;
use File::Spec;
use File::Temp qw(tempdir);
use Cwd qw(abs_path);

my $repo=abs_path($ARGV[0] // File::Spec->catdir(File::Spec->curdir(),'..'));
my $tmp=tempdir(CLEANUP=>1);
my $src=File::Spec->catfile($tmp,'inline_profit_unit.c');
my $exe=File::Spec->catfile($tmp,'inline_profit_unit');
open my$f,'>',$src or die "write $src: $!\n";
print {$f} <<'C';
#include <stdio.h>
#include <stdlib.h>
#include "inline_profit.h"

static void need(int ok,const char *msg){if(!ok){fprintf(stderr,"%s\n",msg);exit(1);}}
static void write_map(const char *p){FILE*f=fopen(p,"w");need(f!=NULL,"open map");fputs(
"HEADER\nMEMORY USAGE\n"
"  BANK0      used=80 bytes (0.00%) free=0 bytes (0.00%)\n"
"  BANK1      used=20 bytes (0.00%) free=0 bytes (0.00%)\n"
"  RAM        used=12 bytes (0.00%) free=0 bytes (0.00%) objects=8 bytes hardware-stack=4 bytes\n\n"
"CALL STACK\n",f);fclose(f);}
int main(int argc,char **argv){
 inline_link_metrics_t m,a; char err[128];
 need(argc==2,"map arg"); write_map(argv[1]);
 need(inline_link_metrics_read_map(argv[1],&m,err,sizeof(err)),err);
 need(m.rom_bytes==100 && m.ram_object_bytes==8 && m.hardware_stack_bytes==4,"parsed metrics mismatch");
 a=m; a.rom_bytes=99; need(inline_profit_decide(&m,&a)==INLINE_PROFIT_ACCEPT_ROM,"ROM win rejected");
 a=m; a.rom_bytes=101; need(inline_profit_decide(&m,&a)==INLINE_PROFIT_REJECT,"ROM loss accepted");
 a=m; a.hardware_stack_bytes=2; need(inline_profit_decide(&m,&a)==INLINE_PROFIT_ACCEPT_STACK,"equal-ROM stack win rejected");
 a=m; a.rom_bytes=90; a.ram_object_bytes=9; need(inline_profit_decide(&m,&a)==INLINE_PROFIT_REJECT_RAM_REGRESSION,"RAM regression accepted");
 puts("Inline profit metrics unit passed"); return 0;
}
C
close $f;
my @cc=('gcc','-std=c11','-Wall','-Wextra','-Werror','-pedantic','-I',File::Spec->catdir($repo,'driver'),$src,File::Spec->catfile($repo,'driver','inline_profit.c'),'-o',$exe);
system(@cc)==0 or die "compile failed: @cc\n";
system($exe,File::Spec->catfile($tmp,'sample.map'))==0 or die "unit executable failed\n";
