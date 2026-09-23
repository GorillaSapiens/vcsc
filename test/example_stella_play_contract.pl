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
      my $logical=$line;
      my $j=$i;
      while($logical =~ /\\[ \t]*\r?\n\z/ && $j+1<@lines) {
         $logical.=$lines[++$j];
      }
      (my $flat=$logical) =~ s/\\[ \t]*\r?\n[ \t]*//g;
      ++$launches;
      ++$play_launches;
      index($flat,'-dev.tv.jitter 0')>=0
         or die "$path:".($i+1)." Stella play launch lacks -dev.tv.jitter 0\n";
      for my $flag ('-dev.settings 1','-dev.stats 1','-dev.detectedinfo 1','-dev.ramrandom 1','-dev.bankrandom 1') {
         index($flat,$flag)>=0
            or die "$path:".($i+1)." Stella play launch lacks $flag\n";
      }
      index($flat,'-basedir "$(CURDIR)"')>=0
         or die "$path:".($i+1)." Stella play launch lacks example-local -basedir\n";
      my$prev=$i ? $lines[$i-1] : '';
      $prev =~ /^\s*echo WARNING: ignoring user specific settings(?:;\s*\\)?\s*$/
         or die "$path:".($i+1)." Stella play launch lacks immediately preceding settings warning\n";

      # Preserve the established absolute-path/userdir contract for the normal
      # literal-stella examples.  $(STELLA) compatibility diagnostics have their
      # own historical launch shape and are covered above by the new common flags.
      if($flat =~ /^\s*stella\s/) {
         index($flat,'-userdir "$(CURDIR)"')>=0
            or die "$path:".($i+1)." Stella play launch lacks example-local -userdir\n";
         my$count=()=$flat =~ /\$\(CURDIR\)/g;
         $count>=3
            or die "$path:".($i+1)." Stella play launch does not pass an absolute example ROM path\n";
         $flat !~ /(?:^|\s)\*\.bin(?:\s|$)/
            or die "$path:".($i+1)." Stella play launch still passes a cwd-relative ROM glob\n";
         $flat !~ /\s\$\(TARGET\)(?:\s|;|$)/
            or die "$path:".($i+1)." Stella play launch still passes cwd-relative TARGET\n";
         $flat !~ /\s"\$\$bin"(?:\s|;)/
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
# S9 retired duplicate unofficial-renderer example matrices.  Keep the
# maintained post-retirement inventory as the minimum so accidental example
# loss still trips this contract while additions remain allowed.
$launches>=91 or die "unexpectedly found only $launches example Stella play launches\n";
print "example Stella play contract passed ($launches launches)\n";
