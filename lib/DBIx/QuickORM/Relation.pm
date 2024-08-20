package DBIx::QuickORM::Relation;
use strict;
use warnings;

use Carp qw/croak/;

use DBIx::QuickORM::Util::HashBase qw{
    <members
    +index
};

use DBIx::QuickORM::Util::Has qw/Plugins Created SQLSpec/;

sub init {
    my $self = shift;

    $self->{+MEMBERS} //= [];

    croak "A relation may not be empty" if @{$self->{+MEMBERS}} < 1;
    croak "A relation may not have more than 2 members" if @{$self->{+MEMBERS}} > 2;
}

sub index {
    my $self = shift;
    return $self->{+INDEX} ||= join " ",
        map { "$_->{table}(" . join(',' => sort @{$_->{columns}}) . ")" }
        sort { $a->{table} cmp $b->{table} } @{$self->{+MEMBERS}};
}

1;
