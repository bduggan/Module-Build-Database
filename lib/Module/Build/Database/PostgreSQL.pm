package Module::Build::Database::PostgreSQL;

use base 'Module::Build::Database';
__PACKAGE__->add_property(use_postgis => 0);

sub _make_new_db {
    my $self = shift;
    warn "ready to make a new empty database";
}

sub ACTION_dbtest        { shift->SUPER::ACTION_dbtest(@_);        }
sub ACTION_dbdist        { shift->SUPER::ACTION_dbdist(@_);        }
sub ACTION_dbdocs        { shift->SUPER::ACTION_dbdocs(@_);        }
sub ACTION_dbinstall     { shift->SUPER::ACTION_dbinstall(@_);     }
sub ACTION_dbfakeinstall { shift->SUPER::ACTION_dbfakeinstall(@_); }

1;

