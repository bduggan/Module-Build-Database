=head1 NAME

Module::Build::Database - Manage database patches in the style of Module::Build.

=head1 SYNOPSIS

 perl Build.PL
 ./Build dbtest
 ./Build dbdist
 ./Build dbfakeinstall
 ./Build dbinstall

In more detail :

 # In Build.PL :

 use Module::Build::Database;

 my $builder = Module::Build::Database->new(
    database_type => "PostgreSQL",
    ...other module build options..
  );

 $builder->create_build_script();

 # Put database patches into db/patches/*.sql.
 # A schema will be autogenerated in db/dist/base.sql.
 # Any data generated by the patches will be put into db/dist/base_data.sql.
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

This (re-)generates the files db/dist/base.sql, db/dist/base_data.sql,
and db/dist/patches_applied.txt.

It does this by reading patches from db/patches/*.sql,
applying the ones that are not listed in db/dist/patches_applied.txt,
and then dumping out a new db/dist/base.sql and db/dist/base_data.sql.

In other words :

 1. Start a new empty database instance.
 2. Populate the schema using db/dist/base.sql.
 3. Import any data in db/dist/base_data.sql.
 4. For every patch in db/patches/*.sql :
    Is the patch is listed in db/dist/patches_applied.txt?
    Yes?  Skip it.
    No?  Apply it, and add it to db/dist/patches_applied.txt.
 5. Dump the new schema out to db/dist/base.sql
 6. Dump any data out into db/dist/base_data.sql.
 7. Stop the database.

=item dbtest

 1. Start a new empty database instance.
 2. Apply db/dist/base.sql.
 3. Apply db/dist/base_data.sql.
 4. Apply any patches in db/patches/*.sql that are
    not in db/dist/patches_applied.txt.
    For each of the above, the tests will fail if any of the
    patches do not apply cleanly.
 5. Shut down the database instance.

If --leave_running=1 is passed, step 4 will not be executed.
The "host" for the database can be found in

 Module::Build::Database->current->notes("dbtest_host");

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

Note that dbdist must be run to update base.sql before doing dbfakeinstall
or dbinstall.

=item dbinstall

 1. Look for a running database, based on environment variables
 2. Apply any patches in db/dist/patches_applied.txt that are not in the patches_applied table.
 3. Add an entry to the patches_applied table for each patch applied.

=back

=head1 NOTES

Patches will be applied in lexicographic order, so their names should start
with a sequence of digits, e.g.  0010_something.sql, 0020_something_else.sql, etc.

=head1 TODO

Allow dbclean to not interfere with other running mbd-test databases.  Currently it
errs on the side of cleaning up too much.

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

use Module::Build::Database::Helpers qw/debug info/;
use base 'Module::Build';

our $VERSION = '0.26';

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

sub _diff_files {
    my $self = shift;
    my ($one,$two) = @_;
    return system("diff -B $one $two")==0;
}

sub ACTION_dbtest {
    my $self = shift;

    # 1. Start a new empty database instance.
    warn "# starting test database\n";
    my $host = $self->_start_new_db() or die "could not start the db";
    $self->notes(dbtest_host => $host);

    # 2. Apply db/dist/base.sql.
    $self->_apply_base_sql();

    # 2.1 Apply db/dist/base_data.sql
    $self->_apply_base_data();

    # 3. Apply any patches in db/patches/*.sql that are
    #    not in db/dist/patches_applied.txt.
    #    For each of the above, the tests will fail if any of the
    #    patches do not apply cleanly.

    my @todo = $self->_find_patch_files(pending => 1);

    info "no unapplied patches" unless @todo;
    print "1..".@todo."\n" if (@todo && !$ENV{MBD_QUIET});
    my $i = 1;
    my $passes = 0;
    for my $filename (@todo) {
        if ($self->_apply_patch($filename)) {
            print "ok $i - applied $filename\n" unless $ENV{MBD_QUIET};
            $passes++;
        } else {
            print "not ok $i - applied $filename\n" unless $ENV{MBD_QUIET};
        }
        $i++;
    }

    return 1 if $self->runtime_params("leave_running") || $self->notes("leave_running");

    # 4. Shut down the database instance.
    $self->_stop_db();

    # and remove it
    $self->_remove_db();
    $self->notes(dbtest_host => "");

    return $passes==@todo;
}

sub ACTION_dbclean {
    my $self = shift;

    if (my $host = $self->notes("dbtest_host")) {
        $self->_stop_db($host);
        $self->_remove_db($host);
    }

    # Remove any test databases created, stop any daemons.
    $self->_cleanup_old_dbs; # NB: this may conflict with other running tests
    $self->notes(dbtest_host => "");
    $self->notes(already_started => 0);
}

sub ACTION_dbdist {
    my $self = shift;
    my $dbdist  = $self->base_dir . '/db/dist';

    if (! -e "$dbdist/base.sql" && -e "$dbdist/patches_applied.txt") {
        die "No base.sql : remove patches_applied.txt to apply all patches\n";
    };

    # 1. Start a new empty database instance.
    $self->_start_new_db();

    # 2. Populate the schema using db/dist/base.sql.
    # If there is no base.sql, we will create it from the patches.
    if ($self->_apply_base_sql()) {
        warn "updating base.sql\n";
    } else {
        warn "creating new base.sql\n";
    }

    # 3. For every pending patch, apply, and add to patches_applied.txt.
    my %applied = $self->_read_patches_applied_file();
    my @todo    = $self->_find_patch_files( pending => 1 );
    -d $dbdist or mkpath $dbdist;
    my $patches_file = "$dbdist/patches_applied.txt";
    my $fp = IO::File->new(">>$patches_file") or die "error: $!";
    for my $filename (@todo) {
        my $hash = Digest::MD5->new()->addfile(
                    IO::File->new( "<" .$self->base_dir . '/db/patches/' . $filename ) )
                  ->hexdigest;
        $self->_apply_patch($filename) or die "Failed to apply $filename";
        print ${fp} (join "\t", $filename, $hash)."\n";
        info "Applied patch $filename";
    }
    $fp->close;
    info "Wrote $patches_file" if @todo;

    # 4. Dump the new schema out to db/dist/base.sql
    $self->_dump_base_sql();
    info "Wrote $dbdist/base.sql";

    # 4.1 Dump any data out to db/dist/base_data.dump
    $self->_dump_base_data();
    info "Wrote $dbdist/base_data.sql";

    # 5. Stop the database.
    $self->_stop_db();

    # 6. Wipe it.
    $self->_remove_db();
    $self->notes(dbtest_host => "");
}

sub ACTION_dbdocs {
    my $self = shift;

    my $docdir = $self->base_dir."/db/dist/docs";
    mkpath $docdir;
    $self->_generate_docs(dir => $docdir);
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
        info "Ready to create the base database.";
        return;
    } else {
        $self->_dump_base_sql(outfile => "$existing_schema");
    }

    # 4. Dump the patch table.
    my $tmp = File::Temp->new(); $tmp->close;
    if ($self->_patch_table_exists()) {
        $self->_dump_patch_table(outfile => "$tmp");
    } else {
        info "There is no patch table, it will be created.";
        unlink "$tmp" or die "error unlinking $tmp: $!";
    }

    # 4. Apply patches listed in db/dist/patches_applied.txt that are not
    #    in the patches_applied table.
    # 4a. Determine list of patches to apply.
    my %db_patches = $self->_read_patches_applied_file(filename => "$tmp");
    my %base_patches  = $self->_read_patches_applied_file();
    my @todo = grep { !$db_patches{$_} } sort keys %base_patches;
    debug "patches todo : @todo";
    for my $patch (sort keys %db_patches) {
        unless (exists $base_patches{$patch}) {
            info "WARNING: patch $patch in db is not in patches_applied.txt";
            next;
        }
        next if "@{ $db_patches{$patch} }" eq "@{ $base_patches{$patch} }";
        info "WARNING: @{ $db_patches{$patch} } != @{ $base_patches{$patch} }";
    }
    for my $patch (@todo) {
        info "Will apply patch $patch";
    }

    # 5a. Start a temporary database, apply the live schema.
    # 5b. Apply the pending patches to that one.
    # 5c. Remove the patches_applied table.
    # 5d. Dump out the resulting schema.
    # 5e. Compare that to base.sql.

    $tmp = File::Temp->new();$tmp->close;
    $self->_start_new_db();
    $self->_apply_base_sql("$existing_schema") # NB: contains patches_applied table
        or die "error with existing schema";
    do { $self->_apply_patch($_) or die "patch $_ failed" } for @todo;
    $self->_remove_patches_applied_table();
    $self->_dump_base_sql(outfile => "$tmp");
    $self->_diff_files("$tmp", $self->base_dir. "/db/dist/base.sql")
        or warn "Applying patches will not result in a schema identical to base.sql\n";
}

sub ACTION_dbinstall {
    my $self = shift;

    if ($self->_is_fresh_install()) {
        info "Fresh install.";
        $self->_create_database() or die "could not create database\n";
        $self->_apply_base_sql() or die "could not apply base sql\n";
        $self->_apply_base_data() or die "could not apply base_data sql\n";
    }

    my %base_patches = $self->_read_patches_applied_file();
    unless ($self->_patch_table_exists()) {
        # add records for all patches which have been applied to the base
        info "Creating a new patch table";
        $self->_create_patch_table() or die "could not create patch table\n";
        for my $patch (sort keys %base_patches) {
            $self->_insert_patch_record($base_patches{$patch});
        }
    }
    #  1. Look for a running instance, based on environment variables
    #  2. Apply any patches in db/patches/ that are not in the patches_applied table.
    #  3. Add an entry to the patches_applied table for each patch applied.

    my $outfile = File::Temp->new(); $outfile->close;
    $self->_dump_patch_table(outfile => "$outfile");
    my %db_patches = $self->_read_patches_applied_file(filename => "$outfile");
    for my $patch (sort keys %base_patches) {
        if (exists($db_patches{$patch})) {
            next if "@{$base_patches{$patch}}" eq "@{$db_patches{$patch}}";
            warn "patch $patch: @{$base_patches{$patch}} != @{$db_patches{$patch}}\n";
            next;
        }
        warn "Applying $patch\n";
        $self->_apply_patch($patch) or die "error applying $patch";
        $self->_insert_patch_record($base_patches{$patch});
    }
}

1;

