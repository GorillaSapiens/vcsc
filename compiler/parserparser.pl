#!/usr/bin/env perl

$section = 0;

%out = ();
%map = ();

while (<>) {
   if (/\%\%/) {
      $section++;
   }

   if ($section == 1 && /^[a-z_]+:/) {
      $tmp = $_;
      $tmp =~ s/[\x0a\x0d]//g;
      $tmp =~ s/:.*//g;
      $rule = $tmp;
   }
   elsif ($section == 1) {
      if (/MAKE_NAMED_NODE/) {
         if (!defined($out{$rule})) {
            $out{$rule} = 1;
         }
         $tmp = $_;
         $tmp =~ s/MAKE_NAMED_NODE\(\"([^\"]*)\"/$mapping = $1/ge;
         $map{$mapping} = $rule;
      }
      elsif (/MAKE_NODE/) {
         if (!defined($out{$rule})) {
            $out{$rule} = 1;
         }
      }
   }
}

foreach $key (sort(keys(%out))) {
   print "void compile_$key(void);\n";
}

print "\n";

foreach $key (sort(keys(%mapping))) {
   print "   { \"$key\", compile_$map{$key} },\n";
}

print "\n";

foreach $key (sort(keys(%out))) {
   print "void compile_$key(void) {\n";
   print "}\n";
   print "\n";
}
