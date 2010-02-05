package Module::Build::Database;

=head1 NAME

Module::Build::Database - Manage database patches with Module::Build.

=head1 SYNOPSIS

use Module::Build::Database;

my $builder = Module::Build::Database->new(
    database_type => "PostgreSQL",
    ...other module build options..
  );

 # Then..

 perl Build.PL
 ./Build
 ./Build dbtest
 ./Build dbdist
 ./Build dbinstall
 ./Build dbdocs

=head1 DESCRIPTION

This is a subclass of Module::Build which adds functionality
for maintaining patches to a database.  Patches may be applied
to either a live instance (when doing a "dbinstall") or to
a throwaway test instance (when doing a "dbdist"), to create
a schema dump which can be used to make a new instance of
the database.

When applying patches to a live database, the list of patches that
have been applied is stored in the database itself.  When creating
a schema, the list of patches that comprise the schema is stored
in a flat file.

A "patch" refers to a file which can be sent to a database's
command line client like this :

    psql < patchname.sql

(where "psql" may also be "mysql", "sqlite", etc.)

The following should be subdirectories of the top-level directory :

    db/patches/release/
    db/patches/auto/
    db/doc/auto (optional)

release/ should have patches that can be applied to the production database.

auto/ will have two automatically generated files :

    dump.sql -- a single file which will create an empty database
    applied.txt -- a list of the patches which have been applied to create dump.sql

Appling the patches in applied.txt one after the other will be
equivalent to applying "dump.sql".

Module::Build::Database provides the following actions for ./Build :

=over

=item dbtest

 1. Start a new empty database instance.
 2. Apply db/patches/auto/dump.sql.
 3. Apply any patches in db/patches/release that are
    not in db/patches/auto/applied.txt.
    For each of the above, the tests will fail if any of the
    patches do not apply cleanly.
 4. Shut down the database instance.

=item dbdist

 1. Start a new empty database instance.
 2. Apply db/patches/auto/dump.sql.
 3. Append the patches applied to auto/applied.txt.
 4. Dump the new schema out to auto/dump.sql
 5. Stop the database.

=item dbdocs

 1. Start a new empty database instance.
 2. Apply db/patches/auto/dump.sql.
 3. Dump the new schema docs out to db/doc/auto.
 4. Stop the database.

=item dbfakeinstall

 1. Look for a running database, based on environment variables.
 2. Display the connection information obtained from the above.
 3. Dump the schema from the live database to a temporary directory.
 4. Warn about any differences between the above and auto/dump.sql.
 3. Display a list of patches in release/ that are not in the patches_applied table.

=item dbinstall

 1. Look for a running database, based on environment variables
 2. Apply any patches in release/ that are not in the patches_applied table.
 3. Add an entry to the patches_applied table for each patch applied.

=back

=cut

use warnings;
use strict;
use base 'Module::Build';

our $VERSION = 0.01;

sub new {
    my $class = shift;
    my %args = @_;
    # recursive constructor, fun
    my $driver = delete $args{database_type}
      or return $class->SUPER::new(%args);
    my $subclass = "$class\::$driver";
    eval "use $subclass";
    die $@ if $@;
    return $subclass->new(%args);
}

sub ACTION_dbtest {
    my $self = shift;
    $self->_make_new_db();
}

sub ACTION_dbdist {
    my $self = shift;

}

sub ACTION_dbdocs {
    my $self = shift;

}

sub ACTION_dbinstall {
    my $self = shift;

}

sub ACTION_dbfakeinstall {
    my $self = shift;

}

1;

