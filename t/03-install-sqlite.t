#!perl

use Test::More tests => 7;
use File::Temp qw/tempdir/;
use File::Path qw/mkpath/;
use File::Copy qw/copy/;
use FindBin;

my $debug = 0;

sub _sysok {
    my $cmd = shift;
    my $log = File::Temp->new();  $log->close;
    ok system($cmd . " > $log 2>&1")==0, "$cmd" or do {
        copy "$log", "$log.$$" or die "copy failed: $!";
        diag "$cmd failed : $? ".(${^CHILD_ERROR_NATIVE} || '')." see $log.$$";
    };
}

my $dir = tempdir( CLEANUP => !$debug);
my $src_dir = "$FindBin::Bin/../eg/SqliteApp";
mkpath "$dir/db/patches";
copy "$src_dir/Build.PL", $dir;
copy "$src_dir/db/patches/0010_one.sql","$dir/db/patches";
chdir $dir;

delete $ENV{MODULEBUILDRC};
$ENV{PERL5LIB} = join ':', @INC;

_sysok("perl Build.PL");

_sysok("./Build dbtest");

_sysok("./Build dbdist");

ok -e "$dir/db/dist/base.sql", "created base.sql";
ok -e "$dir/db/dist/patches_applied.txt", "created patches_applied.txt";

# Now test dbfakeinstall and dbinstall.  Configure the database to be
# installed to a tempdir.

my $tmpdir = tempdir(CLEANUP => 0);
my $dbdir  = "$tmpdir/dbtest";

_sysok("./Build dbfakeinstall");

TODO: {
    local $TODO = "fix sqlite";
    _sysok("./Build dbinstall");
}

#
# TODO: sqlite support needs work.
#
# my $out = `echo ".schema one" | sqlite3 sqlite_app.db`;
#
# diag $out;
chdir "$dir/..";

1;

