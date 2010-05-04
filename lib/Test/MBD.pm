package Test::MBD;

use strict;
use warnings;

use File::Slurp 'slurp';

sub import
{
    my $class = shift;

    foreach my $arg (@_)
    {
        start() if $arg eq '-autostart';
    }
}

sub start
{
    my $look_for = '_build/dbtest_host';

    unless (-r $look_for)
    {
        warn "# starting test database\n";
        system("MBD_QUIET=1 ./Build dbtest --leave_running=1") == 0
            or die "Could not start test database";
    }

    my $host = slurp($look_for);
    chomp $host;
    $ENV{TEST_PGHOST} = $host;
}

sub stop
{
    warn "# stopping and cleaning test database\n";
    $ENV{MBD_QUIET} = 1;
    system("./Build dbclean") == 0;
}

1;

__END__

=head1 NAME

Test::MBD - Helper for testing Module::Build::Database apps

=head1 SYNOPSIS

 use Test::MBD '-autostart';  # Pass in autostart to auto start

 Test::MBD->start; # Starts a test database if not already up
 Test::MBD->stop;  # Stop and clean up the test database

=head1 DESCRIPTION

For L<Module::Build::Database> application tests, use Test::MBD in
each test case that needs the database.  Runs './Build dbtest
--leave_running=1' to start up the test database if it isn't already
running and leaves it running.

Run Test::MBD->stop in your very last test case to shut down and clean
up after the test database with 'Build dbclean'.

Also, sets the environment variable TEST_PGHOST to the hostname for
the test instance.

=head1 SEE ALSO

L<Module::Build::Database>

=cut
