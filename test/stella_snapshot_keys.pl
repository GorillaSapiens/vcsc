#!/usr/bin/perl
# Focus the largest mapped X11 window and send F12 to make Stella save a snapshot.
# This intentionally speaks the small X11 protocol subset directly so the test
# suite does not depend on Python, python-xlib, xdotool, or a non-core Perl X11
# binding merely to press one key in its private Xvfb server.

use strict;
use warnings;
use IO::Socket::UNIX;
use Socket qw(SOCK_STREAM);
use Time::HiRes qw(sleep);

sub read_exact {
   my($fh,$length)=@_;
   my $data='';
   while (length($data)<$length) {
      my $n=sysread($fh,my $chunk,$length-length($data));
      defined($n) or die "read X11 socket: $!\n";
      $n>0 or die "X11 server closed the connection\n";
      $data.=$chunk;
   }
   return $data;
}

sub send_request {
   my($fh,$opcode,$minor,$body,$reply_expected)=@_;
   $body //= '';
   $body.="\0" x ((4-length($body)%4)%4);
   my $request=pack('CCv',$opcode,$minor,(4+length($body))/4).$body;
   syswrite($fh,$request)==length($request) or die "write X11 request: $!\n";
   return undef unless $reply_expected;
   while (1) {
      my $head=read_exact($fh,32);
      my $type=ord(substr($head,0,1));
      if ($type==0) {
         my $code=ord(substr($head,1,1));
         my $major=ord(substr($head,10,1));
         die "X11 protocol error $code while processing opcode $major\n";
      }
      next if $type!=1; # Ignore asynchronous events.
      my $extra_length=unpack('V',substr($head,4,4))*4;
      return $head.($extra_length ? read_exact($fh,$extra_length) : '');
   }
}

sub x_connect {
   my $display=$ENV{DISPLAY} // die "DISPLAY is not set\n";
   $display =~ /(?:^|:)(\d+)(?:\.\d+)?$/
      or die "unsupported DISPLAY '$display'; expected a local X display\n";
   my $number=$1;
   my $socket=IO::Socket::UNIX->new(
      Type=>SOCK_STREAM,
      Peer=>"/tmp/.X11-unix/X$number",
   ) or die "connect to X display $display: $!\n";
   binmode($socket);

   my $hello=pack('CCvvvvv',ord('l'),0,11,0,0,0,0);
   syswrite($socket,$hello)==length($hello) or die "write X11 setup: $!\n";
   my $setup_head=read_exact($socket,8);
   my($status,$reason_length,undef,undef,$extra_units)=unpack('CCvvv',$setup_head);
   my $setup=read_exact($socket,$extra_units*4);
   if ($status!=1) {
      my $reason=substr($setup,0,$reason_length);
      die "X11 setup failed: $reason\n";
   }
   length($setup)>=32 or die "short X11 setup reply\n";
   my $vendor_length=unpack('v',substr($setup,16,2));
   my $root_count=ord(substr($setup,20,1));
   my $format_count=ord(substr($setup,21,1));
   my $min_keycode=ord(substr($setup,26,1));
   my $max_keycode=ord(substr($setup,27,1));
   $root_count>=1 or die "X11 display has no screens\n";
   my $root_offset=32+(($vendor_length+3)&~3)+$format_count*8;
   $root_offset+4<=length($setup) or die "short X11 screen description\n";
   my $root=unpack('V',substr($setup,$root_offset,4));
   return ($socket,$root,$min_keycode,$max_keycode);
}

sub query_tree {
   my($fh,$window)=@_;
   my $reply=send_request($fh,15,0,pack('V',$window),1);
   my $count=unpack('v',substr($reply,16,2));
   return $count ? unpack('V*',substr($reply,32,$count*4)) : ();
}

sub is_viewable {
   my($fh,$window)=@_;
   my $reply=eval { send_request($fh,3,0,pack('V',$window),1) };
   return 0 if !$reply;
   return ord(substr($reply,26,1))==2;
}

sub geometry_area {
   my($fh,$window)=@_;
   my $reply=eval { send_request($fh,14,0,pack('V',$window),1) };
   return 0 if !$reply;
   my $width=unpack('v',substr($reply,16,2));
   my $height=unpack('v',substr($reply,18,2));
   return $width*$height;
}

sub largest_mapped_descendant {
   my($fh,$root)=@_;
   my($best,$best_area);
   my @pending=query_tree($fh,$root);
   while (@pending) {
      my $window=shift @pending;
      if (is_viewable($fh,$window)) {
         my $area=geometry_area($fh,$window);
         ($best,$best_area)=($window,$area)
            if !defined($best) || $area>$best_area;
      }
      push @pending,eval { query_tree($fh,$window) };
   }
   return $best;
}

sub find_executable {
   my($name)=@_;
   return $name if $name =~ m{/} && -x $name;
   for my $dir (split(/:/,$ENV{PATH} // '')) {
      my $path="$dir/$name";
      return $path if -x $path;
   }
   return undef;
}

sub f12_keycode {
   my $xkbcomp=find_executable('xkbcomp')
      or die "xkbcomp is required to discover the F12 keycode\n";
   my $display=$ENV{DISPLAY} // die "DISPLAY is not set\n";
   open(my $fh,'-|',$xkbcomp,$display,'-')
      or die "run xkbcomp: $!\n";
   my $keycode;
   while (my $line=<$fh>) {
      $keycode=$1 if $line =~ /<FK12>\s*=\s*(\d+)\s*;/;
   }
   close($fh) or die "xkbcomp failed while reading the X11 keymap\n";
   defined($keycode) or die "X11 keyboard mapping has no F12 key\n";
   return $keycode;
}

sub key_event {
   my($type,$keycode,$root,$window)=@_;
   return pack('CCvVVVVssssvCC',
      $type,$keycode,0,0,$root,$window,0,
      1,1,1,1,0,1,0);
}

my($x,$root)=x_connect();
my $window;
for (1..100) {
   $window=largest_mapped_descendant($x,$root);
   last if defined($window);
   sleep(0.05);
}
defined($window) or die "no mapped Stella window appeared\n";
my $keycode=f12_keycode();

# SetInputFocus: RevertToParent=2, CurrentTime=0.
send_request($x,42,2,pack('VV',$window,0),0);
sleep(0.30);
for my $type (2,3) { # KeyPress, KeyRelease
   my $event=key_event($type,$keycode,$root,$window);
   send_request($x,25,1,pack('VV',$window,0).$event,0);
}
sleep(0.35);
