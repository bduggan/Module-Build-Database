#!perl

use Test::More;
use File::Temp qw/tempdir/;
use File::Path qw/mkpath/;
use File::Copy qw/copy/;
use IO::Socket::INET;
use FindBin;

my $pg = `which postgres`;

$pg or do {
       plan skip_all => "Cannot find postgres executable";
   };

my $postg = $ENV{TEST_POSTGIS_BASE} || "/util/share/postgresql/contrib/postgis.sql";
unless (-d $postg) {
    plan skip_all => "No postgis.sql, set TEST_POSTGIS_BASE=/usr/local/wherever to give a location";
}

my @pg_version = `postgres --version` =~ / (\d+)\.(\d+)\.(\d+)$/m;

unless ($pg_version[0] >= 8) {
    plan skip_all => "postgres version must be >= 8.0";
}

if ($pg_version[0]==8 && $pg_version[1] < 4) {
    plan skip_all => "postgres version must be >= 8.4"
}

plan qw/no_plan/;

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
my $src_dir = "$FindBin::Bin/../eg/Pgapp";
mkpath "$dir/db/patches";
copy "$src_dir/Build.PL", $dir;
copy "$src_dir/db/patches/0010_one.sql","$dir/db/patches";
chdir $dir;

$ENV{PERL5LIB} = join ':', @INC;
delete $ENV{MODULEBUILDRC};

_sysok("perl Build.PL --postgis_base=$postg");

_sysok("./Build dbtest");

_sysok("./Build dbdist");

ok -e "$dir/db/dist/base.sql", "created base.sql";
ok -e "$dir/db/dist/patches_applied.txt", "created patches_applied.txt";

# Now test dbfakeinstall and dbinstall.  Configure the database to be
# installed to a tempdir.

my $tmpdir = tempdir(CLEANUP => 0);
my $dbdir  = "$tmpdir/dbtest";

# find a free port
my $port = 9999;

while ($port < 10100 and
       !IO::Socket::INET->new(Listen    => 5,
                 LocalAddr => 'localhost',
                 LocalPort => $port,
                 Proto     => 'tcp') ) {
    $port ++
}

diag "using local port $port";

$ENV{PGPORT} = $port;
$ENV{PGHOST} = "$dbdir";
$ENV{PGDATA} = "$dbdir";
$ENV{PGDATABASE} = "scooby";

_sysok("initdb -D $dbdir");

open my $fp, ">> $dbdir/postgresql.conf" or die $!;
print {$fp} qq[unix_socket_directory = '$dbdir'\n];
close $fp or die $!;

_sysok("pg_ctl -w start");

_sysok("./Build dbfakeinstall");

_sysok("./Build dbinstall");

my $out = `psql -c "\\d one"`;

like $out, qr/table.*doo\.one/i, "made table one in schema doo";
like $out, qr/x.*integer/, "made column x type integer";

_sysok("pg_ctl -D $dbdir stop") unless $debug;

chdir '..'; # otherwise file::temp can't clean up

1;

