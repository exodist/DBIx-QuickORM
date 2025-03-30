package DBIx::QuickORM::Select;
use strict;
use warnings;
use feature qw/state/;

use Carp qw/croak/;
use Scalar::Util qw/blessed/;

use DBIx::QuickORM::Iterator;

use Role::Tiny::With qw/with/;
with 'DBIx::QuickORM::Role::Handle';

use DBIx::QuickORM::Util::HashBase qw{
    <connection
    <sqla_source

    +where
    +order_by
    +limit
    <fields
    <field_renames

    +last_sth
};

sub init {
    my $self = shift;
    $self->DBIx::QuickORM::Role::Handle::init();

    unless ($self->{+FIELDS}) {
        $self->{+FIELDS}        = $self->{+SQLA_SOURCE}->sqla_fields;
        $self->{+FIELD_RENAMES} = $self->{+SQLA_SOURCE}->sqla_rename;
    }

    $self->{+WHERE} //= {};
    delete $self->{+LAST_STH};
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

sub clone {
    my $self   = shift;
    my %params = @_;

    my $class = blessed($self);

    $class->new(%$self, %params);
}

sub source {
    my $self = shift;

    require DBIx::QuickORM::Source;
    return DBIx::QuickORM::Source->new(
        CONNECTION()  => $self->{+CONNECTION},
        SQLA_SOURCE() => $self->{+SQLA_SOURCE},
    );
}

sub all { shift->iterator(@_)->list }

sub iterator {
    my $self = shift;
    my %params = @_;

    my $sth = $self->_execute_select();

    return DBIx::QuickORM::Iterator->new(sub {
        my $data = $sth->fetchrow_hashref or return;
        return $data if $params{data_only};
        return $self->build_row($data);
    });
}

sub iterate {
    my $self = shift;
    my ($cb, %params);
    if (@_ == 1) {
        ($cb) = @_;
    }
    else {
        %params = @_;
        $cb = delete $params{cb};
    }

    croak "No callback provided" unless $cb;

    my $sth = $self->_execute_select();

    while (my $data = $sth->fetchrow_hashref) {
        if ($params{data_only}) {
            $cb->($data);
        }
        else {
            my $row = $self->build_row($data);
            $cb->($row);
        }
    }

    return;
}

sub any {
    my $self = shift;
    my %params = @_;

    my $s    = $self->clone(order_by => undef, limit => 1);
    my $sth  = $s->_execute_select();
    my $data = $sth->fetchrow_hashref or return;

    return $data if $params{data_only};
    return $self->build_row($data);
}

sub count {
    my $self = shift;
    my $s    = $self->clone(order_by => undef, fields => 'COUNT(*) AS cnt');
    my $sth  = $s->_execute_select();
    my $data = $sth->fetchrow_hashref or return 0;
    return $data->{cnt};
}

sub first {
    my $self = shift;
    my %params = @_;

    my $s    = $self->clone(limit => 1);
    my $sth  = $s->_execute_select();
    my $data = $sth->fetchrow_hashref or return;

    return $data if $params{data_only};
    return $self->build_row($data);
}

sub one {
    my $self = shift;
    my %params = @_;

    my $s    = $self->clone(limit => 2);
    my $sth  = $s->_execute_select();
    my $data = $sth->fetchrow_hashref or return;
    croak "More than one matching row was found in the database" if $sth->fetchrow_hashref;

    return $data if $params{data_only};
    return $self->build_row($data);
}

sub update {
    my $self = shift;
    my ($changes) = @_;

    croak "No changes for update" unless $changes;
    croak "Changes must be a hashref" unless ref($changes) eq 'HASH';

    my $source = $self->{+SQLA_SOURCE}->sqla_source;

    my ($stmt, @bind) = $self->sqla->update($source, $changes, $self->{+WHERE});
    my $sth = $self->dbh->prepare($stmt);
    $sth->execute(@bind);
    $self->{+LAST_STH} = $sth;

    state $warned = 0;
    warn "TODO update cache" unless $warned++;

    return;
}

sub _execute_select {
    my $self = shift;

    my $source = $self->{+SQLA_SOURCE}->sqla_source;
    my $fields = $self->{+FIELDS};
    my $rename = $self->{+FIELD_RENAMES};

    my ($stmt, $bind, $bind_names) = $self->sqla->select($source, @{$self}{FIELDS(), WHERE(), ORDER_BY()});
    if (my $limit = $self->limit) {
        $stmt .= " LIMIT ?";
        push @$bind => $limit;
    }

    my $sth = $self->dbh->prepare($stmt);
    $sth->execute(@$bind);

    state $warned = 0;
    warn "TODO rename fields" unless $warned++;

    return $self->{+LAST_STH} = $sth;
}

sub _and {
    my $self = shift;
    return $self->clone(WHERE() => {'-and' => [$self->{+WHERE}, @_]});
}

sub _or {
    my $self = shift;
    return $self->clone(WHERE() => {'-or' => [$self->{+WHERE}, @_]});
}

sub delete {
    my $self = shift;
    my $source = $self->{+SQLA_SOURCE}->sqla_source;

    my ($stmt, @bind) = $self->sqla->delete($source, $self->{+WHERE});
    my $sth = $self->dbh->prepare($stmt);
    $sth->execute(@bind);
    $self->{+LAST_STH} = $sth;

    return;
}

# Do these last to avoid conflicts with the operators
{
    no warnings 'once';
    *and = \&_and;
    *or  = \&_or;
}

1;
