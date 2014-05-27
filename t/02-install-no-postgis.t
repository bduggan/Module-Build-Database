#!perl

use Test::More;
use File::Temp qw/tempdir/;
use File::Path qw/mkpath/;
use File::Copy qw/copy/;
use IO::Socket::INET;
use FindBin;
use Module::Build::Database::PostgreSQL;

use lib $FindBin::Bin.'/tlib';
use misc qw/sysok/;

$ENV{LC_ALL} = 'C';

if($Module::Build::Database::PostgreSQL::Bin{Postgres} eq '/bin/false') {
    plan skip_all => "Cannot find postgres executable";
}

$> or do {
    plan skip_all => "Cannot test postgres as root";
};

my @pg_version = `$Module::Build::Database::PostgreSQL::Bin{Postgres} --version` =~ / (\d+)\.(\d+)\.(\d+)$/m;

diag "pg version : ".join '.', @pg_version;

unless ($pg_version[0] >= 8) {
    plan skip_all => "postgres version must be >= 8.0";
}

if ($pg_version[0]==8 && $pg_version[1] < 4) {
    plan skip_all => "postgres version must be >= 8.4"
}

plan qw/no_plan/;

my $debug = 0;

my $dir = tempdir( CLEANUP => !$debug);
my $src_dir = "$FindBin::Bin/../eg/PgappNoPostgis";
mkpath "$dir/db/patches";
ok copy "$src_dir/Build.PL", $dir;
ok copy "$src_dir/db/patches/0010_one.sql","$dir/db/patches";
ok copy "$src_dir/db/patches/0020_two.sql","$dir/db/patches";
ok copy "$src_dir/db/patches/0030_three.sql","$dir/db/patches";
ok copy "$src_dir/db/patches/0040_four.sql","$dir/db/patches";
ok copy "$src_dir/db/patches/0050_five.sql","$dir/db/patches";
ok chdir $dir;

sysok("$^X -Mblib=$FindBin::Bin/../blib Build.PL");

sysok("./Build dbtest");

sysok("./Build dbdist");

ok -e "$dir/db/dist/base.sql", "created base.sql";
ok -s "$dir/db/dist/base.sql", "$dir/db/dist/base.sql has a size > 0";
ok -e "$dir/db/dist/patches_applied.txt", "created patches_applied.txt";
ok -s "$dir/db/dist/patches_applied.txt", "$dir/db/dist/patches_applied.txt has a size > 0";

# Now test dbfakeinstall and dbinstall.  Configure the database to be
# installed to a tempdir.

my $tmpdir = tempdir(CLEANUP => 0);
my $dbdir  = "$tmpdir/dbtest";

$ENV{PGPORT} = 5432;
$ENV{PGHOST} = "$dbdir";
$ENV{PGDATA} = "$dbdir";
$ENV{PGDATABASE} = "scooby";

sysok("$Module::Build::Database::PostgreSQL::Bin{Initdb} -D $dbdir");

open my $fp, ">> $dbdir/postgresql.conf" or die $!;
if ($pg_version[1] > 2) {
    print {$fp} qq[unix_socket_directories = '$dbdir'\n];
} else  {
    print {$fp} qq[unix_socket_directory = '$dbdir'\n];
}
close $fp or die $!;

sysok(qq[$Module::Build::Database::PostgreSQL::Bin{Pgctl} -t 120 -o "-h ''" -w start]);

sysok("./Build dbfakeinstall");

sysok("./Build dbinstall");

my $out = do { local $ENV{PERL5LIB}; `psql -c "\\d one"` };

like $out, qr/table.*doo\.one/i, "made table one in schema doo";
like $out, qr/x.*integer/, "made column x type integer";

my $out2 = do { local $ENV{PERL5LIB}; `psql -c "\\d+ five"` };
like $out2, qr[± 1], "unicode character okay";

sysok("$Module::Build::Database::PostgreSQL::Bin{Pgctl} -D $dbdir -m immediate stop") unless $debug;

chdir '..'; # otherwise file::temp can't clean up

ok -d "$dir", "directory still there";

undef $dir;

1;

