package DBIx::QuickORM::Source;
use strict;
use warnings;
use feature qw/state/;

use Carp qw/croak/;

use Role::Tiny::With qw/with/;
with 'DBIx::QuickORM::Role::Handle';

use DBIx::QuickORM::Util::HashBase qw{
    <connection
    <sqla_source
};

# sub init comes from DBIx::QuickORM::Role::Handle

sub all      { shift->search->all(@_) }
sub iterator { shift->search->iterator(@_) }
sub iterate  { shift->search->iterate(@_) }
sub any      { shift->search->any(@_) }
sub count    { shift->search->count(@_) }
sub first    { shift->search->first(@_) }
sub one      { shift->search->one(@_) }
sub delete   { shift->search->delete(@_) }
sub update   { shift->search->update(@_) }

sub search {
    my $self = shift;
    my ($where, $order_by, $limit) = @_;

    require DBIx::QuickORM::Select;
    return DBIx::QuickORM::Select->new(
        CONNECTION()  => $self->{+CONNECTION},
        SQLA_SOURCE() => $self->{+SQLA_SOURCE},
        where         => $where,
        order_by      => $order_by,
        limit         => $limit,
    );
}

sub insert {
    my $self = shift;
    my $data;

    if    (@_ > 1) { $data = {@_} }
    elsif (@_)     { $data = $_[0] }
    else           { croak "Not enough arguments" }

    croak "Refusing to insert an empty row" unless keys %$data;

    my $source = $self->sqla_source->sqla_source;

    my ($stmt, @bind) = $self->sqla->insert($source, $data);

    my $sth = $self->dbh->prepare($stmt);
    $sth->execute(@bind);

    state $warned = 0;
    warn "TODO fetch stored data, use returning when applicable" unless $warned++;
    return $self->build_row($data);
}

# TODO These should enforce a transaction
sub find_or_insert   { }
sub update_or_insert { }

1;
