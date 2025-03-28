package DBIx::QuickORM::ORM;
use strict;
use warnings;

our $VERSION = '0.000005';

use Carp qw/croak/;

use DBIx::QuickORM::Util::HashBase qw{
    <name
    <db
    <schema
    <autofill
    <row_class
    <created
    <compiled

    +connection
};

sub init {
    my $self = shift;

    delete $self->{+NAME} unless defined $self->{+NAME};

    my $db = $self->{+DB} or croak "'db' is a required attribute";

    croak "You must either provide the 'schema' attribute or enable 'autofill'"
        unless $self->{+SCHEMA} || $self->{+AUTOFILL};
}

sub connect {
    my $self = shift;

    require DBIx::QuickORM::Connection;
    return DBIx::QuickORM::Connection->new(orm => $self);
}

sub disconnect {
    my $self = shift;
    delete $self->{+CONNECTION};
}

sub connection {
    my $self = shift;
    return $self->{+CONNECTION} //= $self->connect;
}

1;
