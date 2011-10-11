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
PGUSER, PGHOST, PGPORT will be used when
connecting to a live database (for install
and fakeinstall).  PGDATABASE will be ignored:
the name of the database should be given in Build.PL.

=cut

package Module::Build::Database::PostgreSQL;
use base 'Module::Build::Database';
use File::Temp qw/tempdir/;
use File::Path qw/rmtree/;
use File::Basename qw/dirname/;
use File::Copy::Recursive qw/fcopy dirmove/;
use IO::File;

use Module::Build::Database::PostgreSQL::Templates;
use Module::Build::Database::Helpers qw/do_system verify_bin info debug/;
use strict;
use warnings;

__PACKAGE__->add_property(database_options    => default => { name => "foo", schema => "bar" });
__PACKAGE__->add_property(database_extensions => default => { postgis => 0 } );
__PACKAGE__->add_property(postgis_base        => default => "/usr/local/share/postgis" );
__PACKAGE__->add_property(_tmp_db_dir         => default => "" );
__PACKAGE__->add_property(leave_running       => default => 0 ); # leave running after dbtest?

# Binaries used by this module.  They should be in $ENV{PATH}.
our %Bin = (
    Psql       => 'psql',
    Postgres   => 'postgres',
    Initdb     => 'initdb',
    Createdb   => 'createdb',
    Pgdump     => 'pg_dump',
    Pgdoc      => [ qw/pg_autodoc postgresql_autodoc/ ],
);
verify_bin(\%Bin);

sub _do_psql {
    my $self = shift;
    my $sql = shift;
    my $database_name  = $self->database_options('name');
    my $tmp = File::Temp->new();
    print $tmp $sql;
    $tmp->close;
    # -q: quiet, ON_ERROR_STOP: throw exceptions
    do_system( $Bin{Psql}, "-q", "-v'ON_ERROR_STOP=1'", "-f", "$tmp", $database_name );
}
sub _do_psql_out {
    my $self = shift;
    my $sql = shift;
    my $database_name  = $self->database_options('name');
    # -F field separator, -x extended output, -A: unaligned
    do_system( $Bin{Psql}, "-q", "-v'ON_ERROR_STOP=1'", "-A", "-F ' : '", "-x", "-c", qq["$sql"], $database_name );
}
sub _do_psql_file {
    my $self = shift;
    my $filename = shift;
    unless (-e $filename) {
        warn "could not open file $filename";
        return 0;
    }
    unless (-s $filename) {
        warn "file $filename is empty";
        return 0;
    }
    my $database_name  = $self->database_options('name');
    # -q: quiet, ON_ERROR_STOP: throw exceptions
    do_system($Bin{Psql},"-q","-v'ON_ERROR_STOP=1'","-f",$filename, $database_name);
}
sub _do_psql_into_file {
    my $self = shift;
    my $filename = shift;
    my $sql      = shift;
    my $database_name  = $self->database_options('name');
    # -A: unaligned, -F: field separator, -t: tuples only, ON_ERROR_STOP: throw exceptions
    do_system( $Bin{Psql}, "-q", "-v'ON_ERROR_STOP=1'", "-A", "-F '\t'", "-t", "-c", qq["$sql"], $database_name, ">", "$filename" );
}
sub _do_psql_capture {
    my $self = shift;
    my $sql = shift;
    my $database_name  = $self->database_options('name');
    return qx[$Bin{Psql} -c "$sql" $database_name];
}

sub _cleanup_old_dbs {
    my $self = shift;
    my %args = @_; # pass all => 1 to clean up the current one too

    my $glob;
    {
        my $tmpdir = tempdir("mbdtest_XXXXXX", TMPDIR => 1);
        $glob = "$tmpdir";
        rmtree($tmpdir);
    }
    $glob =~ s/mbdtest_.*$/mbdtest_*/;
    for my $thisdir (glob $glob) {
        next unless -d $thisdir && -w $thisdir;
        debug "cleaning up old tmp instance : $thisdir";
        $self->_stop_db("$thisdir/db");
        rmtree($thisdir);
    }
}

sub _start_new_db {
    my $self = shift;
    # Start a new database and return the host on which it was started.

    $self->_cleanup_old_dbs();

    my $database_name   = $self->database_options('name');
    my $database_schema = $self->database_options('schema');
    my $tmpdir          = tempdir("mbdtest_XXXXXX", TMPDIR => 1);
    my $dbdir           = $tmpdir."/db";
    my $initlog         = "$tmpdir/postgres.log";
    $self->_tmp_db_dir($dbdir);

    $ENV{PGHOST}     = "$dbdir"; # makes psql use a socket, not a tcp port
    $ENV{PGDATABASE} = $database_name;
    delete $ENV{PGUSER};
    delete $ENV{PGPORT};

    debug "initializing database (log: $initlog)";

    do_system($Bin{Initdb}, "-D", "$dbdir", ">>", "$initlog", "2>&1") or die "could not initdb";

    do_system($Bin{Postgres}, "-D", "$dbdir", "-k", "$dbdir", "-h ''", "-c silent_mode=on")
        or die "could not start postgres";

    my $pmlog = "$dbdir/postmaster.log";
    my $i = 0;
    # NB: This technique is from Test::Postgres, but maybe easier is "pg_ctl -w start"
    while (! -e "$pmlog" or not grep /ready/, IO::File->new("<$pmlog")->getlines ) {
        debug "waiting for postgres to start..(log: $pmlog)";
        sleep 1;
        last if $ENV{MBD_FAKE};
        die "postgres did not start, see $pmlog" if ++$i > 30;
    }

    $self->_create_database();
    return $self->_dbhost;
}

sub _remove_db {
    my $self = shift;
    return if $ENV{MBD_DONT_STOP_TEST_DB};
    my $dbdir = shift || $self->_tmp_db_dir();
    $dbdir =~ s/\/db$//;
    rmtree $dbdir;
}

sub _stop_db {
    my $self = shift;
    return if $ENV{MBD_DONT_STOP_TEST_DB};
    my $dbdir = shift || $self->_tmp_db_dir();
    my $pid_file = "$dbdir/postmaster.pid";
    unless (-e $pid_file) {
        debug "no pid file ($pid_file), not stopping db";
        return;
    }
    my ($pid) = IO::File->new("<$pid_file")->getlines;
    chomp $pid;
    kill "TERM", $pid;
    my $i = 2;
    while ($i < 10 ) {
        sleep $i++;
        return unless kill 0, $pid;
        info "waiting for pid $pid to stop";
    }
    info "db didn't stop, forcing shutdown";
    kill 9, $pid or info "could not send signal to $pid";
}

sub _apply_base_sql {
    my $self = shift;
    my $filename = shift || $self->base_dir."/db/dist/base.sql";
    return unless -e $filename;
    info "applying base.sql";
    $self->_do_psql_file($filename);
}

sub _apply_base_data {
    my $self = shift;
    my $filename = shift || $self->base_dir."/db/dist/base_data.sql";
    return 1 unless -e $filename;
    info "applying base_data.sql";
    $self->_do_psql_file($filename);
}

sub _dump_base_sql {
    # Optional parameter "outfile" gives the name of the file into which to dump the schema.
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
    my $database_name   = $self->database_options('name');
    do_system( $Bin{Pgdump}, "-xOs", "-E", "utf8", "-n", $database_schema, $database_name,
         "|", "egrep -v '^--'",
         "|", "egrep -v '^CREATE SCHEMA $database_schema;\$'",
         "|", "egrep -v '^SET search_path'",
        ">", "$tmpfile" )
      or return 0;
    rename "$tmpfile", $outfile or die "rename failed: $!";
}

sub _dump_base_data {
    # Optional parameter "outfile, defaults to db/dist/base_data.sql
    my $self = shift;
    my %args = @_;
    my $outfile = $args{outfile} || $self->base_dir. "/db/dist/base_data.sql";

    my $tmpfile = File::Temp->new(
        TEMPLATE => (dirname $outfile)."/dump_XXXXXX",
        UNLINK   => 0
    );
    $tmpfile->close;

    # -x : no privileges, -O : no owner, -s : schema only, -n : only this schema
    my $database_schema = $self->database_options('schema');
    my $database_name   = $self->database_options('name');
    do_system( $Bin{Pgdump}, "--data-only", "-xO", "-E", "utf8", "-n", $database_schema, $database_name,
        "|", "egrep -v '^SET search_path'",
        ">", "$tmpfile" )
      or return 0;
    rename "$tmpfile", $outfile or die "rename failed: $!";
}

sub _apply_patch {
    my $self = shift;
    my $patch_file = shift;

    return $self->_do_psql_file($self->base_dir."/db/patches/$patch_file");
}

sub _is_fresh_install {
    my $self = shift;

    my $database_name = $self->database_options('name');
    unless ($self->_database_exists) {
        info "database $database_name does not exist";
        return 1;
    }

    my $file = File::Temp->new(); $file->close;
    my $database_schema = $self->database_options('schema');
    $self->_do_psql_into_file("$file","\\dn $database_schema");
    return !do_system("_silent","grep -q $database_schema $file");
}

sub _show_live_db {
    # Display the connection information
    my $self = shift;

    info "PGUSER : " . ( $ENV{PGUSER}     || "<undef>" );
    info "PGHOST : " . ( $ENV{PGHOST}     || "<undef>" );
    info "PGPORT : " . ( $ENV{PGPORT}     || "<undef>" );

    my $database_name = shift || $self->database_options('name');
    info "database : $database_name";

    return unless $self->_database_exists;
    $self->_do_psql_out("select current_database(),session_user,version();");
}

sub _patch_table_exists {
    # returns true or false
    my $self = shift;
    my $file = File::Temp->new(); $file->close;
    $self->_do_psql_into_file("$file","select tablename from pg_tables where tablename='patches_applied'");
    return do_system("_silent","grep -q patches_applied $file");
}

sub _dump_patch_table {
    # Dump the patch table in an existing db into a flat file, that
    # will be in the same format as patches_applied.txt.
    my $self = shift;
    my %args = @_;
    my $filename = $args{outfile} or Carp::confess "need a filename";
    $self->_do_psql_into_file($filename,"select patch_name,patch_md5 from patches_applied order by patch_name");
}

sub _create_patch_table {
    my $self = shift;
    # create a new patch table
    my $sql = <<EOSQL;
    CREATE TABLE patches_applied (
        patch_name   varchar(255) primary key,
        patch_md5    varchar(255),
        when_applied timestamp );
EOSQL
    $self->_do_psql($sql);
}

sub _insert_patch_record {
    my $self = shift;
    my $record = shift;
    my ($name,$md5) = @$record;
    $self->_do_psql("insert into patches_applied (patch_name, patch_md5, when_applied) ".
             " values ('$name','$md5',now()) ");
}

sub _database_exists {
    my $self  =  shift;
    my $database_name = shift || $self->database_options('name');
    do_system("_silent","psql -Alt -F ':' | egrep -q '^$database_name:'");
}

sub _create_database {
    my $self = shift;

    my $database_name   = $self->database_options('name');
    my $database_schema = $self->database_options('schema');

    # create the database if necessary
    unless ($self->_database_exists($database_name)) {
        do_system($Bin{Createdb}, $database_name) or die "could not createdb";
    }

    # Create a fresh schema in the database.
    $self->_do_psql("create schema $database_schema") unless $database_schema eq 'public';

    $self->_do_psql("alter database $database_name set client_min_messages to ERROR");

    $self->_do_psql("alter database $database_name set search_path to $database_schema;");

    # stolen from http://wiki.postgresql.org/wiki/CREATE_OR_REPLACE_LANGUAGE
    $self->_do_psql(<<'SAFE_MAKE_PLPGSQL');
CREATE OR REPLACE FUNCTION make_plpgsql()
RETURNS VOID
LANGUAGE SQL
AS $$
CREATE LANGUAGE plpgsql;
$$;

SELECT
    CASE
    WHEN EXISTS(
        SELECT 1
        FROM pg_catalog.pg_language
        WHERE lanname='plpgsql'
    )
    THEN NULL
    ELSE make_plpgsql() END;

DROP FUNCTION make_plpgsql();
SAFE_MAKE_PLPGSQL

    if (my $postgis = $self->database_extensions('postgis')) {
        info "applying postgis extension";
        my $postgis_schema = $postgis->{schema} or die "No schema given for postgis";
        $self->_do_psql("create schema $postgis_schema") unless $postgis_schema eq 'public';
        $self->_do_psql("alter database $database_name set search_path to $postgis_schema;");
        # We need to run "createlang plpgsql" first.
        $self->_do_psql_file($self->postgis_base. "/postgis.sql") or die "could not do postgis.sql";
        $self->_do_psql_file($self->postgis_base. "/spatial_ref_sys.sql") or die "could not do spatial_ref_sys.sql";
        $self->_do_psql("alter database $database_name set search_path to $database_schema, $postgis_schema");
    }
    1;
}

sub _remove_patches_applied_table {
    shift->_do_psql("drop table if exists patches_applied;");
}

sub _generate_docs {
    my $self            = shift;
    my %args            = @_;
    my $dir             = $args{dir} or die "missing dir";
    my $tmpdir          = tempdir;
    my $tc              = "Module::Build::Database::PostgreSQL::Templates";
    my $database_name   = $self->database_options('name');
    my $database_schema = $self->database_options('schema');

    $self->_start_new_db();
    $self->_apply_base_sql();

    chdir $tmpdir;
    for my $filename ($tc->filenames) {
        open my $fp, ">$filename" or die $!;
        print ${fp} $tc->file_contents($filename);
        close $fp;
    }

    # http://perlmonks.org/?node_id=821413
    do_system( $Bin{Pgdoc}, "-d", $database_name, "-s", $database_schema, "-l .", "-t pod" );
    do_system( $Bin{Pgdoc}, "-d", $database_name, "-s", $database_schema, "-l .", "-t html" );
    do_system( $Bin{Pgdoc}, "-d", $database_name, "-s", $database_schema, "-l .", "-t dot" );

    for my $type qw(pod html) {
        my $fp = IO::File->new("<$database_name.$type") or die $!;
        mkdir $type or die $!;
        my $outfp;
        while (<$fp>) {
            s/^_CUT: (.*)$// and do { $outfp = IO::File->new(">$type/$1") or die $!; };
            s/^_DB: (.*)$//  and do { $_ = $self->_do_psql_capture($1);   s/^/ /gm;  };
            print ${outfp} $_ if defined($outfp);
        }
    }
    dirmove "$tmpdir/pod", "$dir/pod";
    info "Generated $dir/pod";
    dirmove "$tmpdir/html", "$dir/html";
    info "Generated $dir/html";
    fcopy "$tmpdir/$database_name.dot", "$dir";
    info "Generated $dir/$database_name.dot";
}

sub ACTION_dbtest        { shift->SUPER::ACTION_dbtest(@_);        }
sub ACTION_dbclean       { shift->SUPER::ACTION_dbclean(@_);       }
sub ACTION_dbdist        { shift->SUPER::ACTION_dbdist(@_);        }
sub ACTION_dbdocs        { shift->SUPER::ACTION_dbdocs(@_);        }
sub ACTION_dbinstall     { shift->SUPER::ACTION_dbinstall(@_);     }
sub ACTION_dbfakeinstall { shift->SUPER::ACTION_dbfakeinstall(@_); }

sub _dbhost {
    return $ENV{PGHOST};
}

1;

