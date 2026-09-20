#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: compile
# expectexit: 0
use strict;
use warnings;
use File::Find qw(find);
use File::Spec;

@ARGV==2 or die "usage: $0 REPO TMP\n";
my($repo,$tmp)=@ARGV;
my$examples=File::Spec->catdir($repo,'examples');
my@makefiles;
find(sub { push @makefiles,$File::Find::name if $_ eq 'Makefile' && -f $_; },$examples);
my($plays,$launches)=(0,0);
for my$path (sort @makefiles) {
   open(my$fh,'<',$path) or die "open $path: $!\n";
   my@lines=<$fh>;
   close$fh;
   my$in_play=0;
   my$play_launches=0;
   for(my$i=0;$i<@lines;++$i) {
      my$line=$lines[$i];
      if($line =~ /^play(?:\s*):/) { $in_play=1; ++$plays; next; }
      $in_play=0 if $in_play && $line =~ /^[^\t\s#].*:/;
      next unless $in_play;
      next unless $line =~ /(?:^|\s)(?:stella|\$\(STELLA\))\s/;
      ++$launches;
      ++$play_launches;
      index($line,'-dev.tv.jitter 0')>=0
         or die "$path:".($i+1)." Stella play launch lacks -dev.tv.jitter 0\n";
      index($line,'-basedir "$(CURDIR)"')>=0
         or die "$path:".($i+1)." Stella play launch lacks example-local -basedir\n";
      my$prev=$i ? $lines[$i-1] : '';
      $prev =~ /^\s*echo WARNING: ignoring user specific settings(?:;\s*\\)?\s*$/
         or die "$path:".($i+1)." Stella play launch lacks immediately preceding settings warning\n";

      # Preserve the established absolute-path/userdir contract for the normal
      # literal-stella examples.  $(STELLA) compatibility diagnostics have their
      # own historical launch shape and are covered above by the new common flags.
      if($line =~ /^\s*stella\s/) {
         index($line,'-userdir "$(CURDIR)"')>=0
            or die "$path:".($i+1)." Stella play launch lacks example-local -userdir\n";
         my$count=()=$line =~ /\$\(CURDIR\)/g;
         $count>=3
            or die "$path:".($i+1)." Stella play launch does not pass an absolute example ROM path\n";
         $line !~ /(?:^|\s)\*\.bin(?:\s|$)/
            or die "$path:".($i+1)." Stella play launch still passes a cwd-relative ROM glob\n";
         $line !~ /\s\$\(TARGET\)(?:\s|;|$)/
            or die "$path:".($i+1)." Stella play launch still passes cwd-relative TARGET\n";
         $line !~ /\s"\$\$bin"(?:\s|;)/
            or die "$path:".($i+1)." Stella play loop still passes a cwd-relative ROM path\n";
      }
   }
   if(grep(/^play(?:\s*):/,@lines)) {
      $play_launches==1
         or die "$path play target has $play_launches Stella launches, expected exactly one\n";
   }
}
$plays==$launches
   or die "example play/Stella launch count mismatch: $plays play targets, $launches launches\n";
$launches>=100 or die "unexpectedly found only $launches example Stella play launches\n";
print "example Stella play contract passed ($launches launches)\n";
