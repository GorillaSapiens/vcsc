#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: inactive branch contracts ok
# expectexit: 0

use strict;
use warnings;
use IPC::Open3;
use Symbol qw(gensym);
my($repo,$tmp)=@ARGV;
for my$active(0,1){
   open(my$f,'>',"$tmp/branch_$active.s26")or die$!;
   print{$f} ".if $active\nbne.same far\nbcc.cross far\n.endif\n.byte \$42\n.res 256\nfar:\n.byte \$53\n";close$f;
   my$err=gensym;my$pid=open3(my$in,my$out,$err,"$repo/assembler/vcsc-as",'-o',"$tmp/branch_$active.o26","$tmp/branch_$active.s26");close$in;
   local$/;my$stdout=<$out>//'';my$stderr=<$err>//'';waitpid($pid,0);my$status=$?;
   if($active){$status&&$stderr=~/requires a short relative branch/ or die "active timing assertion lost: $stdout$stderr";}
   else{$status==0 or die "inactive timing assertion evaluated: $stdout$stderr";}
}
print "inactive branch contracts ok\n";
