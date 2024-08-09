package DBIx::QuickORM::Table;
use strict;
use warnings;

use Carp qw/croak/;
use Scalar::Util qw/weaken/;
use DBIx::QuickORM::Util qw/delegate/;

use DBIx::QuickORM::Select;

use DBIx::QuickORM::HashBase qw{
    meta_table
    db
    schema
};

delegate name         => META_TABLE();
delegate column_names => META_TABLE();
delegate pk           => (META_TABLE(), "primary_key");
delegate primary_key  => (META_TABLE(), "primary_key");

sub init {
    my $self = shift;

    croak "'meta_table' is a required attribute" unless $self->{+META_TABLE};
    croak "'schema' is a required attribute"     unless $self->{+SCHEMA};
    croak "'db' is a required attribute"         unless $self->{+DB};

    weaken($self->{+SCHEMA});

    return $self;
}

sub search           { }    # Select
sub find             { }    # One row
sub insert           { }    # row
sub find_or_insert   { }    # row
sub update_or_insert { }    # row
sub fetch            { }    # raw hashref
sub fetch_all        { }    # iterator of hashrefs

1;
