package misc;
use File::Copy qw/copy/;
require Test::More;

sub import {
    *{ caller() . '::sysok' } = \&sysok;
}
sub diag($) { goto \&Test::More::diag; }
sub ok($$) { goto \&Test::More::ok; }

use strict;

sub sysok {
    my $cmd = shift;
    my $log = File::Temp->new();
    ok system($cmd . " > $log 2>&1")==0, "$cmd" or do {
        diag "$cmd failed : $? ".(${^CHILD_ERROR_NATIVE} || '');
        diag $_ for $log->getlines;
    };
}

1;

