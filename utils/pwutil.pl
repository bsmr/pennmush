#!/usr/bin/env perl

# Script for manipulating passwords in Penn database files.

use strict;
use warnings;
use Getopt::Long;
use File::Copy;
use File::Temp qw/tempfile/;
use Digest::SHA;
use IO::Compress::Gzip qw/$GzipError/;
use IO::Uncompress::Gunzip qw/$GunzipError/;
use Pod::Text::Termcap;

our %sha_algos = ( 1 => 1, 224 => 2, 256 => 2, 384 => 2, 512 => 2 );
our $sha_bits = 256;

sub format_password {
  my $sha = Digest::SHA->new($sha_bits);
  # Shouldn't happen, but fail gracefully if the constructor doesn't.
  die "Invalid digest SHA-$sha_bits\n" unless defined $sha;

  $sha->add(shift);
  my $hashed = $sha->hexdigest;
  my $time = time;
  return "1:sha$sha_bits:$hashed:$time";
}

sub parse_dbref_spec {
  my $d = shift;
  return qr/^\s*!(\d+)/ if $d eq "all";
  return qr/^\s*!($d)/ if $d =~ /^\d+$/;
  die "Invalid dbref '$d'\n";
}

our $backup_extension = ".bak";
our $wipe = -1;
our $set = -1;
our $help = 0;
our $password = "";
our $outfile = "";
our $inplace = 0;
our $gzip = 0;

GetOptions("set|s=s" => \$set,
	   "wipe|w=s" => \$wipe,
	   "password|p=s" => \$password,
	   "ext|e=s" => \$backup_extension,
	   "out|o=s" => \$outfile,
	   "z" => \$gzip,
	   "sha=i" => \$sha_bits,
	   "help|h" => \$help);

if ($help) {
  # Display pretty documentation.
  my $parser = Pod::Text::Termcap->new;
  $parser->output_fh(*STDERR);
  $parser->parse_file(*DATA);
  exit 0;
}

if (($set == -1 && $wipe == -1)
    || ($set != -1 && $wipe != -1)) {
  die "Either --set or --wipe must be given.";
}

if ($set > -1 && $password eq "") {
  my $default_password = "youreallyshouldchangethis";
  warn "Using default password '$default_password'\n";
  $password = $default_password;
}

die "Invalid digest SHA-$sha_bits\n" unless defined $sha_algos{$sha_bits};

our $dbref;

if ($set != -1) {
  $dbref = parse_dbref_spec $set;
} else {
  $dbref = parse_dbref_spec $wipe;
}

our $infile = shift @ARGV;
die "Missing database filename.\n" unless defined $infile;

# Make a backup.
if ($outfile eq "") {
  $inplace = 1;
  copy $infile, "$infile$backup_extension" or
    die "Unable to back up $infile: $!\n";
}

our $ifh;
our ($ofh, $toutfile) = tempfile();

if ($gzip) {
  $ifh = new IO::Uncompress::Gunzip $infile or
    die "Unable to open compressed $infile for reading: $GunzipError\n";
  $ofh = new IO::Compress::Gzip $ofh, -AutoClose => 1 or
    die "Unable to compress database: $GzipError\n";
} else {
  open $ifh, "<", $infile or
    die "Unable to open $infile for reading: $!\n";
}

our $in_obj = 0;
our $passwd = format_password $password;

OBJECT:
while (my $line = <$ifh>) {
  $in_obj = $1 if $line =~ /$dbref/;
  if ($in_obj && $line =~/^\s*attrcount (\d+)/) {
    my $nattrs = $1;
    my @buffer;
    while ($line = <$ifh>) {
      if ($line =~ /^\s*name "XYXXY"/) {
	my $owner = <$ifh>;
	my $flags = <$ifh>;
	my $derefs = <$ifh>;
	my $value = <$ifh>;
	if ($set != -1) {
	  print "Changing password for object $in_obj.\n";
	  print $ofh "attrcount $nattrs\n", @buffer;
	  print $ofh $line, $owner, $flags, $derefs;
	  print $ofh "  value \"$passwd\"\n";
	} else {
	  print "Clearing password from object $in_obj.\n";
	  $nattrs -= 1;
	  print $ofh "attrcount $nattrs\n", @buffer;
	}
	$in_obj = 0;
	next OBJECT;
      } elsif ($line =~ /^\s*!\d+/) {
	if ($set != -1) {
	  # Object doesn't have a password attribute. Add one.
	  print "Adding password to object $in_obj.\n";
	  $nattrs += 1;
	  print $ofh "attrcount $nattrs\n", @buffer;
	  print $ofh
	    " name \"XYXXY\"\n",
	      "  owner #1\n",
		"  flags \"no_command wizard locked internal\"\n",
		  "  derefs 1\n",
		    "  value \"$passwd\"\n";
	} else {
	  print $ofh "attrcount $nattrs\n", @buffer;
	}
	$in_obj = 0;
	redo OBJECT;
      } else {
	push @buffer, $line;
      }
    }
  } else {
    print $ofh $line;
  }
}

close $ifh;
close $ofh;

$outfile = $infile if $inplace;
move $toutfile, $outfile or
  die "Unable to move $toutfile to $outfile: $!\n";

__DATA__

=head1 Usage

 pwutil.pl [ARGS ...] {--wipe X | --set X --password FOO} DATABASE

=head1 Description

pwutil is a tool for manipulating passwords in a B<PennMUSH>
database. It should only be used on a database for a game that's not
currently running; changes made to an active db will be lost at the
next save. Just use C<@newpassword> from inside the game for those
cases. It can erase player's passwords, or change them (For 1.8.4p9
and later). It can also add a password to a player without one already
set.

The mutually exclusive arguments B<--set> and B<--wipe> control what
objects to modify. You can use a numeric dbref, or I<all> to affect
all players. B<--set> also expects a new B<--password> to use.

=head2 Other options

The B<-o> argument is used to give a file name to store the modified
database as. If not provided, the database passed on the command line
is modified in-place, with a backup made first using the F<.bak>
extension. This extension can be changed with the B<-e> option.

If you're using a gzip compressed database, use the B<-z>
option. Other compression algorithms aren't supported; decompress the
database manually and recompress it afterwards.

You can specify which SHA digest algorithm to use with the B<--sha>
option.  Its argument must be one of I<1>, I<224>, I<256>, I<384> or
I<512>. The default is I<256>. Note that while Penn itself can
understand other digest algorithms, this script only works with the
SHA family.

=head1 Examples

=over

=item *

To clear God's password:

 % utils/pwutil.pl -z --wipe 1 game/data/outdb.gz

=item *

To set player #42's password to I<calvinball>:

 % utils/pwutil.pl -z --set 42 --password calvinball game/data/outdb.gz

=item * 

To set everybody's passwords to I<0wnz0red> in a new copy of the database:

 % utils/pwutil.pl --set all --password 0wnz0red -o stolendb game/data/outdb

=back

