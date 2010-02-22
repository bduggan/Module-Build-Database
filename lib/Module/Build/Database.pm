=head1 NAME

Module::Build::Database - Manage database patches in the style of Module::Build.

=head1 SYNOPSIS

 # In Build.PL :

 use Module::Build::Database;

 my $builder = Module::Build::Database->new(
    database_type => "PostgreSQL",
    ...other module build options..
  );

 $builder->create_build_script();

 # Put database patches into db/patches/*.sql.
 # A schema will be autogenerated in db/dist/base.sql.
 # Documentation will be autogenerated in db/doc/.

 # That is, first do this :
 perl Build.PL

 # Then, test that patches in db/patches/ will apply successfully to
 # the schema in db/dist/ :
 ./Build dbtest

 # The, update the db information in db/dist/ by applying any
 # unapplied patches in db/patches/ to the schema in db/dist/ :
 ./Build dbdist

 # Update the docs in db/docs using the schema in db/dist :
 ./Build dbdocs

 # Install a new database or upgrade an existing one :
 ./Build dbfakeinstall
 ./Build dbinstall

Additionally, when doing

 ./Build install

The db/ directory will be installed into <install root>/etc/Module-Name/db.

=head1 DESCRIPTION

This is a subclass of Module::Build for modules which depend on a database,
which adds functionality for testing and distributing changes to the database.

Changes are represented as sql files ("patches") which will be fed into a
command line client for the database.

A complete schema is regenerated whenever "dbdist" is run.

A list of the patches which have been applied is stored in two places :
    (1) the file "db/dist/patches_applied.txt"
    (2) the table "patches_applied" within the target database.

When the dbinstall action is invoked, any patches in (1) but
not in (2) are applied.  In order to determine whether they will apply
successfully, "dbfakeinstall" may be run, which does the following :

    1. Dumps the schema for an existing instance.
    2. Applies any patches not found in the "patches_applied" table.
    3. Dumps the resulting schema and compares it to the schema in db/dist/base.sql.

If the comparison in step 3 is the same, then one may conclude that applying
the missing patches will produce the desired schema.

=head1 ACTIONS

=over

=item dbdist

This (re-)generates the files db/dist/base.sql and db/dist/patches_applied.txt.

It does this by reading patches from db/patches/*.sql,
applying the ones that are not listed in db/dist/patches_applied.txt,
and then dumping out a new db/dist/base.sql.

In other words :

 1. Start a new empty database instance.
 2. Populate the schema using db/dist/base.sql.
 3. For every patch in db/patches/*.sql :
    Is the patch is listed in db/dist/patches_applied.txt?
    Yes?  Skip it.
    No?  Apply it, and add it to db/dist/patches_applied.txt.
 4. Dump the new schema out to db/dist/base.sql
 5. Stop the database.

=item dbtest

 1. Start a new empty database instance.
 2. Apply db/dist/base.sql.
 3. Apply any patches in db/patches/*.sql that are
    not in db/dist/patches_applied.txt.
    For each of the above, the tests will fail if any of the
    patches do not apply cleanly.
 4. Shut down the database instance.

=item dbclean

Stop any test daemons that are running and remove any
test databases that have been created.

=item dbdocs

 1. Start a new empty database instance.
 2. Apply db/dist/base.sql.
 3. Dump the new schema docs out to db/doc.
 4. Stop the database.

=item dbfakeinstall

 1. Look for a running database, based on environment variables.
 2. Display the connection information obtained from the above.
 3. Dump the schema from the live database to a temporary directory.
 4. Make a temporary database using the above schema.
 5. Apply patches listed in db/dist/patches_applied.txt that are not
    in the patches_applied table.
 6. Dump out the resulting schema, and compare it to db/dist/base.sql.

=item dbinstall

 1. Look for a running database, based on environment variables
 2. Apply any patches in db/patches/ that are not in the patches_applied table.
 3. Add an entry to the patches_applied table for each patch applied.

=back

=head1 NOTES

If A database needs to be brought up to date post facto the command line tool
"mbd-tool" may be used to perform the fakeinstall and install actions.

Patches will be applied in lexicographic order, so their names should start
with a sequence of digits, e.g.  0010_something.sql, 0020_something_else.sql, etc.

=head1 SEE ALSO

mbd-tool -- a command line tool for locating and installing database patches
which are associated with Perl modules.

=cut

package Module::Build::Database;
use File::Basename qw/basename/;
use File::Path qw/mkpath/;
use Digest::MD5;
use warnings;
use strict;
use base 'Module::Build';

our $VERSION = 0.01;

sub _info($) { print STDERR shift(). "\n"; }

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

# Return an array of patch filenames.
# Send (pending => 1) to omit applied patches.
sub _find_patch_files {
    my $self = shift;
    my %args = @_;
    my $pending = $args{pending};

    my @filenames = sort map { basename $_ } glob $self->base_dir.'/db/patches/*.sql';
    my @bad = grep { $_ !~ /^\d{4}/ } @filenames;
    if (@bad) {
        die "\nBad patch files : @bad\nAll files must start with at least 4 digits.\n";
    }
    return @filenames unless $pending;
    my %applied = $self->_read_patches_applied_file();
    return grep { !exists( $applied{$_} ) } @filenames;
}

# Read patches_applied.txt or $args{filename}, return a hash whose
# keys are the filenames, and whose values are information about
# the patch.
sub _read_patches_applied_file {
    my $self = shift;
    my %args = @_;
    my %h;
    my $readme = $args{filename} || join '/', $self->base_dir, qw(db dist patches_applied.txt);
    return %h unless -e $readme;
    my @lines = IO::File->new("<$readme")->getlines;
    for my $line (@lines) {
        my @info = split /\s+/, $line;
        $h{$info[0]} = \@info;
    }
    return %h;
}

sub ACTION_dbtest {
    my $self = shift;

    # 1. Start a new empty database instance.
    $self->_start_new_db();

    # 2. Apply db/dist/base.sql.
    _info "applying base.sql";
    $self->_apply_base_sql();

    # 3. Apply any patches in db/patches/*.sql that are
    #    not in db/dist/patches_applied.txt.
    #    For each of the above, the tests will fail if any of the
    #    patches do not apply cleanly.

    my @todo = $self->_find_patch_files(pending => 1);

    _info "no unapplied patches" unless @todo;
    print "1..".@todo."\n" if @todo;
    my $i = 1;
    my $passes = 0;
    for my $filename (@todo) {
        if ($self->_apply_patch($filename)) {
            print "ok $i - applied $filename\n";
            $passes++;
        } else {
            print "not ok $i - applied $filename\n";
        }
        $i++;
    }

    # 4. Shut down the database instance.
    $self->_stop_db();

    # and remove it
    $self->_remove_db();
}

sub ACTION_dbclean {
    # Remove any test databases created, stop any daemons.
    die "NOT IMPLEMENTED";
}

sub ACTION_dbdist {
    my $self = shift;

    # 1. Start a new empty database instance.
    $self->_start_new_db();

    # 2. Populate the schema using db/dist/base.sql.
    _info "applying base.sql";
    $self->_apply_base_sql();

    # 3. For every pending patch, apply, and add to patches_applied.txt.
    my %applied = $self->_read_patches_applied_file();
    my @todo    = $self->_find_patch_files( pending => 1 );
    my $dbdist  = $self->base_dir . '/db/dist';
    -d $dbdist or mkpath $dbdist;
    my $patches_file = "$dbdist/patches_applied.txt";
    my $fp = IO::File->new(">>$patches_file") or die "error: $!";
    for my $filename (@todo) {
        my $hash = Digest::MD5->new()->addfile(
                    IO::File->new( "<" .$self->base_dir . '/db/patches/' . $filename ) )
                  ->hexdigest;
        $self->_apply_patch($filename) or die "Failed to apply $filename";
        print ${fp} (join "\t", $filename, $hash)."\n";
        _info "Applied patch $filename";
    }
    $fp->close;
    _info "Wrote $patches_file" if @todo;

    # 4. Dump the new schema out to db/dist/base.sql
    $self->_dump_base_sql();
    _info "Wrote $dbdist/base.sql";

    # 5. Stop the database.
    $self->_stop_db();

    # 6. Wipe it.
    $self->_remove_db();
}

sub ACTION_dbdocs {
    my $self = shift;

    die "not implemented";
}

sub ACTION_dbfakeinstall {
    my $self = shift;

    # 1. Look for a running database, based on environment variables.
    # 2. Display the connection information obtained from the above.

    $self->_show_live_db();

    # 3. Dump the schema from the live database to a temporary directory.
    my $existing_schema = File::Temp->new();
    $existing_schema->close;
    if ($self->_is_fresh_install()) {
        _info "Ready to create the base database.";
        return;
    } else {
        $self->_dump_base_sql(outfile => "$existing_schema");
    }

    # 4. Dump the patch table.
    my $patches_applied = File::Temp->new();
    $patches_applied->close;
    if ($self->_patch_table_exists()) {
        $self->_dump_patch_table(outfile => "$patches_applied");
    } else {
        _info "There is no patches_applied table, it will be created.";
        unlink "$patches_applied" or die "error unlinking $patches_applied: $!";
    }

    # 4. Apply patches listed in db/dist/patches_applied.txt that are not
    #    in the patches_applied table.
    # 4a. Determine list of patches to apply.
    my %done_patches = $self->_read_patches_applied_file(filename => "$patches_applied");
    my %all_patches  = $self->_read_patches_applied_file();
    my @todo = grep { !$done_patches{$_} } sort keys %all_patches;
    for my $patch (sort keys %done_patches) {
        next if "@{ $done_patches{$patch} }" eq "@{ $all_patches{$patch} }";
        _info "WARNING: @{ $done_patches{$patch} } != @{ $all_patches{$patch} }";
    }
    for my $patch (@todo) {
        _info "Will apply patch $patch";
    }

    # $self->_start_new_db();
    die "not implemented, compare resulting schemas";

    # 5. Dump out the resulting schema, and compare it to db/dist/base.sql.
}

sub ACTION_dbinstall {
    my $self = shift;

    if ($self->_is_fresh_install()) {
        _info "Fresh install; applying base.sql";
        $self->_init_database() or die "could not initialize database\n";
        $self->_apply_base_sql() or die "could not apply base sql\n";
    }

    my %applied2base = $self->_read_patches_applied_file();
    unless ($self->_patch_table_exists()) {
        # add records for all patches which have been applied to the base
        _info "Creating a new patch table";
        $self->_create_patch_table() or die "could not create patch table\n";
        for my $patch (sort keys %applied2base) {
            $self->_insert_patch_record($applied2base{$patch});
        }
    }
    #  1. Look for a running instance, based on environment variables
    #  2. Apply any patches in db/patches/ that are not in the patches_applied table.
    #  3. Add an entry to the patches_applied table for each patch applied.

    my $outfile = File::Temp->new(); $outfile->close;
    $self->_dump_patch_table(outfile => "$outfile");
    my %applied2db = $self->_read_patches_applied_file(filename => "$outfile");
    for my $patch (sort keys %applied2db) {
        if (exists($applied2base{$patch})) {
            next if "@{$applied2base{$patch}}" eq "@{$applied2db{$patch}}";
            warn "patch $patch: @{$applied2base{$patch}} != @{$applied2db{$patch}}\n";
            next;
        }
        $self->_apply_patch($patch) or die "error applying $patch";
        $self->_insert_patch_record($applied2base{$patch});
    }
}

1;

