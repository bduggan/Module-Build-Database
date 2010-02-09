package Module::Build::Database::PostgreSQL;

use base 'Module::Build::Database';
use File::Temp qw/tempdir/;
use IO::File;

__PACKAGE__->add_property(add_postgis => 0);
__PACKAGE__->add_property(add_lang_plpgsql => 0);

our $Psql       = 'psql';
our $Postgres   = 'postgres';
our $Initdb     = 'pg_initdb';
our $Createdb   = 'pg_createdb';
our $Createlang = 'createlang';

sub _info($) { print STDERR shift(). "\n"; }
sub _do_system {
    system(@_) == 0
      or die "Error with system call '@_' : $? "
      . ( ${^CHILD_ERROR_NATIVE} || '' );
}

sub _make_new_db {
    my $self = shift;

    my $tmpdir = tempdir();
    my $logfile = "$tmpdir/init.log";

    $ENV{PGHOST} = "$tmpdir"; # makes psql use a socket, not a tcp port0
    $ENV{PGDATABASE} = "metamine"; # XXX generalize

    # kill running instance?
    #pkill -f postgres.*-D\ $DBBASE && echo "killed postgres on $DBBASE"

    _info "creating database (in $tmpdir)";

    _do_system($Initdb, "-D", "$tmpdir", ">", "$logfile", "2>&1", "&");

    _do_system($Postgres, "-D", "$tmpdir", "-k", "$tmpdir", -h, '', ">", "$logfile", '2>&1', '&');

    while (! -e "$logfile" or not grep /ready/, IO::File->new("<$logfile")->getlines ) {
        _info "waiting for postgres to start..($logfile)";
        sleep 1
    }

    _do_system($Createdb, $ENV{PGDATABASE});

    _do_system($Createlang, "plpgsql") if $self->runtime_params("add_lang_plpgsql");

    # XXX TODO
    #ERRS=$DBBASE/psql.err.log
    #OUT=$DBBASE/psql.out.log
#
#    echo "adding public schema"
#    psql -c "alter database metamine set search_path to public;" >> $OUT
#    psql -f /util/share/postgresql/contrib/postgis.sql           >> $OUT 2>$ERRS
#    psql -f /util/share/postgresql/contrib/spatial_ref_sys.sql   >> $OUT 2>$ERRS
}

sub ACTION_dbtest        { shift->SUPER::ACTION_dbtest(@_);        }
sub ACTION_dbdist        { shift->SUPER::ACTION_dbdist(@_);        }
sub ACTION_dbdocs        { shift->SUPER::ACTION_dbdocs(@_);        }
sub ACTION_dbinstall     { shift->SUPER::ACTION_dbinstall(@_);     }
sub ACTION_dbfakeinstall { shift->SUPER::ACTION_dbfakeinstall(@_); }

1;

