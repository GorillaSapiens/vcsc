#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 120
# expectstdout: host_mingw_stdio ok
# expectexit: 0
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use IPC::Open3;
use Symbol qw(gensym);
use Text::ParseWords qw(shellwords);
my($repo,$tmp)=@ARGV;$repo=abs_path($repo);make_path($tmp);$tmp=abs_path($tmp);
sub slurp {open my$f,'<:raw',$_[0]or die$!;local$/;return <$f>;}
sub run {
   my$e=gensym;my$p=open3(my$i,my$o,$e,@_);close$i;local$/;
   my$s=<$o>//'';my$t=<$e>//'';waitpid($p,0);die"@_\n$s$t"if$?;return$s;
}
my@units=qw(linker/vcsc_ld.c linker/vcsc_ld_input.c linker/vcsc_ld_abi.c disassembler/vcsc_disas.c compiler/builtin_rgb.c driver/vcsc.c);
for my$unit(@units){
   my$text=slurp("$repo/$unit");
   $text=~/^\s*#\s*include\s+([^\n]+)/m && $1 eq '"../host_stdio.h"'
      or die "$unit must select C99 stdio before any system header\n";
}
my$probe=<<'C';
#include "host_stdio.h"
#include <inttypes.h>
#include <stdint.h>
#include <string.h>
#if defined(__MINGW32__) && __USE_MINGW_ANSI_STDIO != 1
#error Host tools require MinGW C99 stdio, including when the toolchain defaults to 0
#endif
int main(void) {
   const size_t n=(size_t)UINT64_C(4294967467);
   const char *expected=sizeof(size_t)>4?"4294967467/1000000ab/1000000AB":"171/ab/AB";
   char text[128];
   FILE *fp=tmpfile();
   if(!fp)return 1;
   if(snprintf(text,sizeof(text),"%zu/%zx/%02zX",n,n,n)<0 || strcmp(text,expected))return 2;
   if(fprintf(fp,"%zu/%zx/%02zX",n,n,n)<0)return 3;
   rewind(fp);
   if(!fgets(text,sizeof(text),fp) || strcmp(text,expected))return 4;
   if(fclose(fp))return 5;
   if(snprintf(text,sizeof(text),"%" PRIu64 "/%" PRIX64,
               UINT64_C(4294967467),UINT64_C(4294967467))<0 ||
      strcmp(text,"4294967467/1000000AB"))return 6;
   return 0;
}
C
open my$f,'>',"$tmp/probe.c"or die$!;print {$f}$probe;close$f or die$!;
my@flags=('-std=c11','-Wall','-Wextra','-Werror','-pedantic','-O2',"-I$repo");
run(shellwords($ENV{CC}||'cc'),@flags,"$tmp/probe.c",'-o',"$tmp/probe");
run("$tmp/probe");

# Cross compilation is an extra check when MinGW is installed, not a new
# dependency for ordinary native tests. The first-include contract and native
# full-width output probe above always run. Package CI installs MinGW explicitly.
my$mingw;
for my$dir(split/:/,$ENV{PATH}//''){
   my$p="$dir/x86_64-w64-mingw32-gcc";if(-x$p){$mingw=abs_path($p);last;}
}
if($mingw){
   for my$mode(0,1){
      run($mingw,@flags,"-D__USE_MINGW_ANSI_STDIO=$mode",'-fsyntax-only',"$tmp/probe.c");
      for my$unit(@units){
         run($mingw,@flags,"-D__USE_MINGW_ANSI_STDIO=$mode",'-fsyntax-only',"$repo/$unit");
      }
   }
}
print "host_mingw_stdio ok\n";
