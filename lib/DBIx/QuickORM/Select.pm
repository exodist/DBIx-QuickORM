package DBIx::QuickORM::Select;
use strict;
use warnings;
use feature qw/state/;

use Carp qw/confess/;
use Sub::Util qw/set_subname/;
use Scalar::Util qw/blessed/;
use DBIx::QuickORM::Source;

use DBIx::QuickORM::Query;

use DBIx::QuickORM::Util::HashBase qw{
    <connection
    <sqla_source

    +where
    +order_by
    +limit
    +fields
    +omit

    +async
    +aside
    +forked
};

use Role::Tiny::With qw/with/;
with 'DBIx::QuickORM::Role::Query';

sub init {
    my $self = shift;

    my $con = $self->connection or confess "'connection' is a required attribute";
    confess "Connection '$con' is not an instance of 'DBIx::QuickORM::Connection'"
        unless blessed($con) && $con->isa('DBIx::QuickORM::Connection');

    my $sqla_source = $self->sqla_source or confess "'sqla_source' is a required attribute";
    confess "Source '$sqla_source' does not implement the role 'DBIx::QuickORM::Role::SQLASource'"
        unless blessed($sqla_source) && $sqla_source->DOES('DBIx::QuickORM::Role::SQLASource');

    $self->normalize_query;
}

BEGIN {
    my @METHODS = qw{
        all      data_all
        iterator data_iterator
        iterate  data_iterate
        any      data_any
        first    data_first
        one      data_one

        count
        delete
        update
    };

    for my $meth (@METHODS) {
        my $name = $meth;
        no strict 'refs';
        *$name = set_subname $name => sub { my $self = shift; $self->{+CONNECTION}->$name($self->{+SQLA_SOURCE}, $self, @_) };
    }
}

sub clone {
    my $self = shift;
    bless({%$self, @_}, blessed($self));
}

sub source {
    my $self = shift;

    return DBIx::QuickORM::Source->new(
        CONNECTION()  => $self->{+CONNECTION},
        SQLA_SOURCE() => $self->{+SQLA_SOURCE},
    );
}

sub sync {
    my $self = shift;
    return $self unless $self->{+FORKED} || $self->{+ASYNC} || $self->{+ASIDE};
    return $self->clone(FORKED() => 0, ASYNC() => 0, ASIDE() => 0);
}

sub async {
    my $self = shift;
    return $self if $self->{+ASYNC};
    return $self->clone(FORKED() => 0, ASYNC() => 1, ASIDE() => 0);
}

sub aside {
    my $self = shift;
    return $self if $self->{+ASIDE};
    return $self->clone(FORKED() => 0, ASYNC() => 0, ASIDE() => 1);
}

sub forked {
    my $self = shift;
    return $self if $self->{+FORKED};
    return $self->clone(FORKED() => 1, ASYNC() => 0, ASIDE() => 0);
}

sub limit {
    my $self = shift;
    return $self->{+LIMIT} unless @_;
    return $self->clone(LIMIT() => $_[0]);
}

sub where {
    my $self = shift;
    return $self->{+WHERE} unless @_;
    return $self->clone(WHERE() => $_[0]);
}

sub order_by {
    my $self = shift;
    return $self->{+ORDER_BY} unless @_;
    return $self->clone(ORDER_BY() => $_[0]);
}

sub all_fields {
    my $self = shift;
    return $self->clone(FIELDS() => $self->{+SQLA_SOURCE}->fields_list_all);
}

sub fields {
    my $self = shift;
    return $self->{+FIELDS} unless @_;

    return $self->clone(FIELDS() => $_[0]) if @_ == 1 && ref($_[0]) eq 'ARRAY';

    my @fields = @{$self->{+FIELDS} // $self->{+SQLA_SOURCE}->fields_to_fetch};
    push @fields => @_;

    return $self->clone(FIELDS() => \@fields);
}

sub omit {
    my $self = shift;
    return $self->{+OMIT} unless @_;

    return $self->clone(OMIT() => $_[0]) if @_ == 1 && ref($_[0]) eq 'ARRAY';

    my @omit = @{$self->{+OMIT} // []};
    push @omit => @_;
    return $self->clone(OMIT() => \@omit)
}

# Do these last to avoid conflicts with the operators
{
    no warnings 'once';
    *and = set_subname 'and' => sub {
        my $self = shift;
        return $self->clone(WHERE() => {'-and' => [$self->{+WHERE}, @_]});
    };

    *or = set_subname 'or' => sub {
        my $self = shift;
        return $self->clone(WHERE() => {'-or' => [$self->{+WHERE}, @_]});
    };
}

1;
