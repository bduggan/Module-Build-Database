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

The environment variables used by psql will
be honored when connecting to an existing
instance (e.g. for fakeinstall and install).
These variables are PGUSER, PGHOST, PGPORT,
and PGDATABASE;

=cut

package Module::Build::Database::PostgreSQL;
use base 'Module::Build::Database';
use File::Temp qw/tempdir/;
use File::Path qw/rmtree/;
use File::Basename qw/dirname/;
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
    my $silent = ($_[0] eq '_silent' ? shift : 0);
    if ($ENV{MBD_FAKE}) {
        _info "fake: system call : @_";
        return;
    }
    #warn "doing------- @_\n";
    system("@_") == 0
      or do {
        warn "Error with '@_' : $? " . ( ${^CHILD_ERROR_NATIVE} || '' ) . "\n" unless $silent;
        return 0;
      };
    return 1;
}
sub _do_psql {
    my $sql = shift;
    # -q: quiet, ON_ERROR_STOP: throw exceptions
    _do_system( $Psql, "-q", "-v'ON_ERROR_STOP=1'", "-c", "'$sql'" );
}
sub _do_psql_out {
    my $sql = shift;
    # -F field separator, -x extended output, -A: unaligned
    _do_system( $Psql, "-q", "-v'ON_ERROR_STOP=1'", "-A", "-F ' : '", "-x", "-c", "'$sql'" );
}
sub _do_psql_file {
    my $filename = shift;
    # -q: quiet, ON_ERROR_STOP: throw exceptions
    _do_system($Psql,"-q","-v'ON_ERROR_STOP=1'","-f",$filename);
}
sub _do_psql_into_file {
    my $filename = shift;
    my $sql      = shift;
    # -A: unaligned, -F: field separator, -t: tuples only, ON_ERROR_STOP: throw exceptions
    _do_system( $Psql, "-q", "-v'ON_ERROR_STOP=1'", "-A", "-F '\t'", "-t", "-c", qq["$sql"], ">", "$filename" );
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
    delete $ENV{PGUSER};
    delete $ENV{PGPORT};

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
    # One optional parameter gives the name of the file into which to dump the schema.
    # If the parameter is omitted, dump and atomically rename to db/dist/base.sql.
    my $self = shift;
    my %args = @_;
    my $outfile = $args{outfile} || $self->base_dir. "/db/dist/base.sql";

    my $tmpfile = File::Temp->new(
        TEMPLATE => (dirname $outfile)."/dump_XXXXXX",
        UNLINK   => 0
    );
    $tmpfile->close;

    # -x : no privileges, -O : no owner, -s : schema only, -n : only this schema
    my $database_schema = $self->database_options('schema');
    _do_system( $Pgdump, "-xOs", "-n", $database_schema, "|",
        "egrep -v '^CREATE SCHEMA $database_schema;\$'",
        ">", "$tmpfile" )
      or return 0;
    rename "$tmpfile", $outfile or die "rename failed: $!";
}

sub _apply_patch {
    my $self = shift;
    my $patch_file = shift;

    return _do_psql_file($self->base_dir."/db/patches/$patch_file");
}

sub _is_fresh_install {
    my $self = shift;

    my $file = File::Temp->new(); $file->close;
    my $database_schema = $self->database_options('schema');
    _do_psql_into_file("$file","\\dn $database_schema");
    return !_do_system("_silent","grep -q $database_schema $file");
}

sub _show_live_db {
    # Display the database to which changes will be applied.
    my $self = shift;

    _info "PGUSER     : " . ( $ENV{PGUSER}     || "<undef>" );
    _info "PGHOST     : " . ( $ENV{PGHOST}     || "<undef>" );
    _info "PGPORT     : " . ( $ENV{PGPORT}     || "<undef>" );
    _info "PGDATABASE : " . ( $ENV{PGDATABASE} || "<undef>" );

    _do_psql_out("select current_database(),session_user,version();");

}

sub _patch_table_exists {
    # returns true or false
    my $self = shift;
    my $file = File::Temp->new(); $file->close;
    _do_psql_into_file("$file","select tablename from pg_tables where tablename='patches_applied'");
    return _do_system("_silent","grep -q patches_applied $file");
}

sub _dump_patch_table {
    # Dump the patch table in an existing db into a flat file, that
    # will be in the same format as patches_applied.txt.
    my $self = shift;
    my %args = @_;
    my $filename = $args{outfile} or die "need a filename";
    _do_psql_into_file($filename,"select patch_name,patch_md5 from patches_applied order by patch_name");
}

sub ACTION_dbtest        { shift->SUPER::ACTION_dbtest(@_);        }
sub ACTION_dbclean       { shift->SUPER::ACTION_dbclean(@_);       }
sub ACTION_dbdist        { shift->SUPER::ACTION_dbdist(@_);        }
sub ACTION_dbdocs        { shift->SUPER::ACTION_dbdocs(@_);        }
sub ACTION_dbinstall     { shift->SUPER::ACTION_dbinstall(@_);     }
sub ACTION_dbfakeinstall { shift->SUPER::ACTION_dbfakeinstall(@_); }

1;

