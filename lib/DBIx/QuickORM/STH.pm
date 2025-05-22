package DBIx::QuickORM::STH;
use strict;
use warnings;

use Carp qw/croak/;

use Role::Tiny::With qw/with/;

with 'DBIx::QuickORM::Role::STH';

use DBIx::QuickORM::Util::HashBase qw{
    <connection
    <dbh
    <sth
    <sql
    <source

    only_one

    +dialect
    +ready
    <result
    <done

    <on_ready
    +fetch_cb
};

sub clear      { }
sub ready      { $_[0]->{+READY} //= 1 }
sub got_result { 1 }

sub dialect { $_[0]->{+DIALECT} //= $_[0]->{+CONNECTION}->dialect }

sub init {
    my $self = shift;

    croak "'connection' is a required attribute" unless $self->{+CONNECTION};
    croak "'source' is a required attribute"     unless $self->{+SOURCE};
    croak "'sth' is a required attribute"        unless $self->{+STH};
    croak "'dbh' is a required attribute"        unless $self->{+DBH};
    croak "'result' is a required attribute"     unless exists $self->{+RESULT};
}

sub next {
    my $self = shift;
    my $row_hr  = $self->_next;

    if ($self->{+ONLY_ONE}) {
        croak "Expected only 1 row_hr, but got more than one" if $self->_next;
        $self->set_done;
    }

    return $row_hr;
}

sub _next {
    my $self = shift;

    return if $self->{+DONE};

    my $fetch = $self->{+FETCH_CB} //= $self->{+ON_READY}->($self->{+DBH}, $self->{+STH}, $self->result, $self->{+SQL});

    my $row_hr = $fetch->();

    return $row_hr if $row_hr;

    $self->set_done;

    return;
}

sub set_done {
    my $self = shift;

    return if $self->{+DONE};

    $self->clear;

    $self->{+DONE} = 1;
}

sub DESTROY {
    my $self = shift;
    return if $self->{+DONE};
    $self->set_done();
    return;
}

1;
