=head1 NAME

Module::Build::Database::PostgreSQL

=head1 SYNOPSIS

In Build.PL :

my $builder = Module::Build::Database->new(
    database_type => "PostgreSQL",
    database_options => {
        name   => "my_database_name",
        schema => "my_schema_name",
    },
    database_extensions => {
        postgis   => {
            schema => "public",
            # postgis.sql and spatial_ref_sys.sql should be under postgis_base (below)
        },
    },
);

 perl Build.PL --postgis_base=/util/share/postgresql/contrib

=head1 DESCRIPTION

Postgres driver for Module::Build::Database.

=head1 NOTES

Many of the command-line utilities provided with postgres
have SQL equivalents.  Using the SQL versions in one of the
patch files avoids reliance on these utilities, e.g.
a 0000_base.sql might have things like

  CREATE PROCEDURAL LANGUAGE plpgsql;

=cut

package Module::Build::Database::PostgreSQL;
use base 'Module::Build::Database';
use File::Temp qw/tempdir/;
use File::Path qw/rmtree/;
use IO::File;
use strict;
use warnings;

__PACKAGE__->add_property(database_options    => default => { name => "foo", schema => "bar" });
__PACKAGE__->add_property(database_extensions => default => { postgis => 0 } );
__PACKAGE__->add_property(postgis_base        => default => "/usr/local/share/postgis" );
__PACKAGE__->add_property(_tmp_db_dir         => default => "" );

# Binaries used by this module.  They should be in $ENV{PATH}.
our $Psql       = 'psql';
our $Postgres   = 'postgres';
our $Initdb     = 'initdb';
our $Createdb   = 'createdb';
our $Pgdump     = 'pg_dump';

sub _info($) { print STDERR shift(). "\n"; }
sub _do_system {
    if ($ENV{MBD_FAKE}) {
        _info "fake: system call : @_";
        return;
    }
    #warn "doing------- @_\n";
    system("@_") == 0
      or do {
        warn "Error with '@_' : $? " . ( ${^CHILD_ERROR_NATIVE} || '' ) . "\n";
        return 0;
      };
    return 1;
}
sub _do_psql {
    my $sql = shift;
    # -q: quiet, ON_ERROR_STOP: throw exceptions
    _do_system( $Psql, "-q", "-v'ON_ERROR_STOP=1'", "-c", "'$sql'" );
}
sub _do_psql_file {
    my $filename = shift;
    # -q: quiet, ON_ERROR_STOP: throw exceptions
    _do_system($Psql,"-q","-v'ON_ERROR_STOP=1'","-f",$filename);
}

sub _cleanup_old_dbs {
    my $self = shift;
    my $tmpdir = tempdir("mbdtest_XXXXXX", TMPDIR => 1);
    my $glob = $tmpdir;
    $glob =~ s/mbdtest_.*$/mbdtest_*/;
    for my $thisdir (glob $glob) {
        next if $thisdir eq $tmpdir;
        _info "cleaning up old tmp instance : $thisdir";
        $self->_stop_db("$thisdir/db");
        rmtree($thisdir);
    }
    rmtree $tmpdir;
}

sub _start_new_db {
    my $self = shift;

    $self->_cleanup_old_dbs();

    my $database_name   = $self->database_options('name');
    my $database_schema = $self->database_options('schema');
    my $tmpdir          = tempdir("mbdtest_XXXXXX", TMPDIR => 1);
    my $dbdir           = $tmpdir."/db";
    my $initlog         = "$tmpdir/postgres.log";
    $self->_tmp_db_dir($dbdir);

    $ENV{PGHOST}     = "$dbdir"; # makes psql use a socket, not a tcp port0
    $ENV{PGDATABASE} = $database_name;

    _info "creating database (log: $initlog)";

    _do_system($Initdb, "-D", "$dbdir", ">>", "$initlog", "2>&1") or die "could not initdb";

    _do_system($Postgres, "-D", "$dbdir", "-k", "$dbdir", "-h ''", "-c silent_mode=on")
        or die "could not start postgres";

    my $pmlog = "$dbdir/postmaster.log";
    while (! -e "$pmlog" or not grep /ready/, IO::File->new("<$pmlog")->getlines ) {
        _info "waiting for postgres to start..(log: $pmlog)";
        sleep 1;
        last if $ENV{MBD_FAKE};
    }

    _do_system($Createdb, $database_name) or die "could not createdb";
    _do_psql("create schema $database_schema");

    _do_psql("alter database $database_name set client_min_messages to ERROR");

    if (my $postgis = $self->database_extensions('postgis')) {
        _info "applying postgis extension";
        my $postgis_schema = $postgis->{schema} or die "No schema given for postgis";
        _do_psql("create schema $postgis_schema") unless $postgis_schema eq 'public';
        _do_psql("alter database $database_name set search_path to $postgis_schema;");
        _do_psql("create procedural language plpgsql");
        # We need to run "createlang plpgsql" first.
        _do_psql_file($self->postgis_base. "/postgis.sql") or die "could not do postgis.sql";
        _do_psql_file($self->postgis_base. "/spatial_ref_sys.sql") or die "could not do spatial_ref_sys.sql";
        _do_psql("alter database $database_name set search_path to $database_schema, $postgis_schema");
    }

}

sub _remove_db {
    my $self = shift;
    return if $ENV{MBD_DONT_STOP_TEST_DB};
    my $dbdir = $self->_tmp_db_dir();
    $dbdir =~ s/\/db$//;
    rmtree $dbdir;
}

sub _stop_db {
    my $self = shift;
    return if $ENV{MBD_DONT_STOP_TEST_DB};
    my $dbdir = shift || $self->_tmp_db_dir();
    my $pid_file = "$dbdir/postmaster.pid";
    unless (-e $pid_file) {
        _info "no pid file ($pid_file), not stopping db";
        return;
    }
    my ($pid) = IO::File->new("<$pid_file")->getlines;
    chomp $pid;
    kill "TERM", $pid;
    my $i = 2;
    while ($i < 10 ) {
        sleep $i++;
        return unless kill 0, $pid;
        _info "waiting for pid $pid to stop";
    }
    _info "db didn't stop, forcing shutdown";
    kill 9, $pid or _info "could not send signal to $pid";
}

sub _apply_base_sql {
    my $self = shift;

    return unless -e $self->base_dir."/db/dist/base.sql";
    _do_psql_file($self->base_dir. "/db/dist/base.sql");
}

sub _dump_base_sql {
    my $self = shift;
    my $tmpfile = File::Temp->new(
        TEMPLATE => $self->base_dir . "/db/dist/dump_XXXXXX",
        UNLINK   => 0
    );
    $tmpfile->close;

    # -x : no privileges, -O : no owner, -s : schema only, -n : only this schema
    my $database_schema = $self->database_options('schema');
    _do_system( $Pgdump, "-xOs", "-n", $database_schema, "|",
        "egrep -v '^CREATE SCHEMA $database_schema;\$'",
        ">", "$tmpfile" )
      or return 0;
    rename "$tmpfile", $self->base_dir . "/db/dist/base.sql"
      or die "rename failed: $!";
}

sub _apply_patch {
    my $self = shift;
    my $patch_file = shift;

    return _do_psql_file($self->base_dir."/db/patches/$patch_file");
}

sub ACTION_dbtest        { shift->SUPER::ACTION_dbtest(@_);        }
sub ACTION_dbclean       { shift->SUPER::ACTION_dbclean(@_);       }
sub ACTION_dbdist        { shift->SUPER::ACTION_dbdist(@_);        }
sub ACTION_dbdocs        { shift->SUPER::ACTION_dbdocs(@_);        }
sub ACTION_dbinstall     { shift->SUPER::ACTION_dbinstall(@_);     }
sub ACTION_dbfakeinstall { shift->SUPER::ACTION_dbfakeinstall(@_); }

1;

