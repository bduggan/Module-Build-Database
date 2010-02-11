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
        languages => [qw/plpgsql/],
        postgis   => {
            schema => "public",
            # postgis.sql and spatial_ref_sys.sql should be under postgis_base (below)
        },
    },
);

 perl Build.PL --postgis_base=/util/share/postgresql/contrib

=head1 DESCRIPTION

Postgres driver for Module::Build::Database.

=cut

package Module::Build::Database::PostgreSQL;
use base 'Module::Build::Database';
use File::Temp qw/tempdir/;
use File::Path qw/rmtree/;
use IO::File;

__PACKAGE__->add_property(database_options    => default => { name => "foo", schema => "bar" });
__PACKAGE__->add_property(database_extensions => default => { languages => [], postgis => 0 } );
__PACKAGE__->add_property(postgis_base        => default => "/usr/local/share/postgis" );
__PACKAGE__->add_property(_tmp_db_dir         => default => "" );

# Binaries used by this module.  They should be in $ENV{PATH}.
our $Psql       = 'psql';
our $Postgres   = 'postgres';
our $Initdb     = 'initdb';
our $Createdb   = 'createdb';
our $Createlang = 'createlang';

sub _info($) { print STDERR shift(). "\n"; }
sub _do_system {
    if ($ENV{MBD_FAKE}) {
        _info "fake: system call : @_";
        return;
    }
    system("@_") == 0
      or do {
        warn "Error with '@_' : $? " . ( ${^CHILD_ERROR_NATIVE} || '' ) . "\n";
        return 0;
      };
    return 1;
}
sub _do_psql {
    my $sql = shift;
    _do_system($Psql,"-v'ON_ERROR_STOP=1'","-c",$sql);
}
sub _do_psql_file {
    my $filename = shift;
    _do_system($Psql,"-v'ON_ERROR_STOP=1'","-f",$filename);
}

sub _cleanup_old_dbs {
    my $tmpdir = tempdir("mbdtest_XXXXXX", TMPDIR => 1);
    my $glob = $tmpdir;
    $glob =~ s/mbdtest_.*$/mbdtest_*/;
    for my $this (glob $glob) {
        next if $this eq $tmpdir;
        _info "cleaning up old tmpdir : $this";
        rmtree($this);
    }
    rmtree $tmpdir;
}

sub _start_new_db {
    my $self = shift;

    my $database_name   = $self->database_options('name');
    my $database_schema = $self->database_options('schema');
    my $tmpdir          = tempdir("mbdtest_XXXXXX", TMPDIR => 1);
    my $dbdir           = $tmpdir."/db";
    my $logfile         = "$tmpdir/postgres.log";
    $self->_tmp_db_dir($dbdir);

    $ENV{PGHOST} = "$dbdir"; # makes psql use a socket, not a tcp port0
    $ENV{PGDATABASE} = $database_name;

    _info "creating database (in $dbdir)";

    _do_system($Initdb, "-D", "$dbdir", ">>", "$logfile", "2>&1") or die "could not initdb";

    _do_system($Postgres, "-D", "$dbdir", "-k", "$dbdir", "-h ''", ">>", "$logfile", '2>&1', '&')
        or die "could not start postgres";

    while (! -e "$logfile" or not grep /ready/, IO::File->new("<$logfile")->getlines ) {
        _info "waiting for postgres to start..($logfile)";
        sleep 1;
        last if $ENV{MBD_FAKE};
    }

    _do_system($Createdb, $database_name) or die "could not createdb";

    for my $lang (@{ $self->database_extensions("languages") }) {
        _do_system($Createlang, $lang) or die "could not create language $lang";
    }

    if (my $postgis = $self->database_extensions('postgis')) {
        my $postgis_schema = $postgis->{schema};
        _do_psql("alter database $database_name set search_path to $postgis_schema");
        _do_psql_file($self->postgis_base. "/postgis.sql");
        _do_psql_file($self->postgis_base. "/spatial_ref_sys.sql");
        _do_psql("alter database $database_name set search_path to $postgis_schema, $database_schema");
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
    return if $ENV{MBD_DONT_STOP_TEST_DB};
    my $self = shift;
    my $dbdir = $self->_tmp_db_dir();
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
        _info "waiting for $pid to stop";
    }
    _info "db didn't stop, forcing shutdown";
    kill 9, $pid or _info "could not send signal to $pid";
}

sub _apply_base_sql {
    my $self = shift;

    _do_psql_file($self->base_dir. "/db/dist/base.sql");
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

