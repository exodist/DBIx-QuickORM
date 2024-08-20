package DBIx::QuickORM::Mixer;
use strict;
use warnings;

use Carp qw/croak/;

use DBIx::QuickORM::Util::HashBase qw{
    <name
    <dbs
    <schemas
    <orms
};

use DBIx::QuickORM::Util::Has qw/Plugins Created/;

sub init {
    my $self = shift;

    croak "'name' is a required attribute" unless $self->{+NAME};

    $self->{+DBS}     //= {};
    $self->{+SCHEMAS} //= {};
    $self->{+ORMS}    //= {};
}

sub schema {
    my $self = shift;
    my ($name) = @_;
    return $self->{+SCHEMAS}->{$name};
}

sub database {
    my $self = shift;
    my ($name) = @_;
    return $self->{+DBS}->{$name};
}

sub orm {
    my $self = shift;
    my ($name) = @_;
    return $self->{+ORMS}->{$name};
}

1;
