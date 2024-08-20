package DBIx::QuickORM::Schema;
use strict;
use warnings;

use Carp qw/confess croak/;
use Scalar::Util qw/blessed/;

use DBIx::QuickORM::Schema::RelationSet;

use DBIx::QuickORM::Util::HashBase qw{
    <name
};

use DBIx::QuickORM::Util::Has qw/Created Plugins/;

sub init {
    my $self = shift;

    croak "'name' is a required attribute" unless $self->{+NAME};
}

1;
