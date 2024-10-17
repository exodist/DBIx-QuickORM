package DBIx::QuickORM::Select::Async;
use strict;
use warnings;

use Carp qw/croak/;

use parent 'DBIx::QuickORM::Select';
use DBIx::QuickORM::Util::HashBase qw{
    +ready
    +started
    +result
};

sub start {
    my $self = shift;

    croak "Async query already started" if $self->{+STARTED};

    $self->{+STARTED} = $self->{+SOURCE}->do_select($self->params, async => 1);

    return $self;
}

sub started { $_[0]->{+STARTED} ? 1 : 0 }

sub ready {
    my $self = shift;
    return 1 if defined $self->{+READY};

    my $started = $self->{+STARTED} or croak 'Async query has not been started (did you forget to call $s->start)?';

    return 0 unless $started->{ready}->();

    return $self->{+READY} = 1;
}

sub cancel { $_[0]->discard }

sub result {
    my $self = shift;
    return $self->{+RESULT} if defined $self->{+RESULT};

    $self->wait();

    return $self->{+RESULT};
}

sub _rows {
    my $self = shift;
    return $self->{+ROWS} if $self->{+ROWS};

    $self->wait();

    return $self->{+ROWS};
}

sub wait {
    my $self = shift;

    return if exists $self->{+RESULT};
    return if exists $self->{+ROWS};

    my $started = $self->{+STARTED} or croak 'Async query has not been started (did you forget to call $s->start)?';

    $self->{+RESULT} = $started->{result}->();
    $self->{+ROWS}   = $started->{fetch}->();

    return $self;
}

sub count { @{$_[0]->_rows} }

sub discard {
    my $self = shift;

    my $done = 0;
    for my $field (ROWS(), READY(), RESULT()) {
        $done = 1 if delete $self->{$field};
    }

    if (my $started = delete $self->{+STARTED}) {
        $started->{cancel}->() unless $done;
    }

    return $self;
}

1;
