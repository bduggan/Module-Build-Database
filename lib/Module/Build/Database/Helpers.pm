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
    for my $label (keys %Bin) {
        my @look_for = (ref $Bin{$label} eq 'ARRAY' ? @{ $Bin{$label} } : $Bin{$label});
        my $found;
        for my $potential_cmd (@look_for) {
            last if ($found = qx[which $potential_cmd 2>/dev/null]);
        }
        unless ($found) {
            debug "could not find ".(join " or ",@look_for)." in current path\n";
        }
        chomp $found;
        $Bin{$label} = $found;
    }
}


1;


