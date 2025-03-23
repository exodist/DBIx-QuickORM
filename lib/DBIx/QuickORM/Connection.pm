package DBIx::QuickORM::Connection;
use strict;
use warnings;

our $VERSION = '0.000005';

use Carp qw/confess croak/;

use DBIx::QuickORM::Util::HashBase qw{
    <db
    +dbh
    <pid
};

#################
# INIT and MISC #
#################

sub init {
    my $self = shift;

    croak "A database is required" unless $self->{+DB};

    $self->{+PID} //= $$;
}

1;
