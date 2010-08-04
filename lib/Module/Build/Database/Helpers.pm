package Module::Build::Database::Helpers;
use strict;
use warnings;

use Sub::Exporter -setup => {
    exports => [
        qw/do_system verify_bin info debug/
    ]
};

sub info($) { print STDERR shift(). "\n" unless $ENV{MBD_QUIET}; }
sub debug($) { print STDERR shift(). "\n" if $ENV{MBD_DEBUG}; }

sub do_system {
    my $silent = ($_[0] eq '_silent' ? shift : 0);
    my $cmd = $_[0];
    if ($ENV{MBD_FAKE} || $ENV{MBD_DEBUG}) {
        info "fake: system call : @_";
        return if $ENV{MBD_FAKE};
    }
    # Carp::cluck("doing------- @_\n");
    system("@_") == 0
      or do {
        return 0 if $silent;
        warn "Error with '@_' : $? " . ( ${^CHILD_ERROR_NATIVE} || '' ) . "\n";
        return 0;
      };
    return 1;
}

sub verify_bin {
    my %Bin = @_;
    my %BinR = reverse %Bin;
    my %BinV; # verify that binaries exist.
    for my $cmd (values %Bin) {
        my $found = qx[which $cmd] or die "could not find $cmd";
    }
}


1;


