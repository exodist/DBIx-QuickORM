package DBIx::QuickORM::Relation::Member;
use strict;
use warnings;

use Carp qw/confess/;

use DBIx::QuickORM::Util::HashBase qw{
    <name
    <table
    <columns
};

use DBIx::QuickORM::Util::Has qw/Created SQLSpec/;

sub init {
    my $self = shift;

    confess "'name' is a required attribute"         unless $self->{+NAME};
    confess "'table' is a required attribute"        unless $self->{+TABLE};
    confess "'columns' is a required attribute"      unless $self->{+COLUMNS};
    confess "'columns' must be an arrayref"          unless ref($self->{+COLUMNS}) eq 'ARRAY';
    confess "'columns' may not be an empty arrayref" unless @{$self->{+COLUMNS}};
}

1;
