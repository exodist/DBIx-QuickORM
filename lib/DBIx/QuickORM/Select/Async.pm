package DBIx::QuickORM::Select::Async;
use strict;
use warnings;

use Carp qw/croak/;

use parent 'DBIx::QuickORM::Select';
use DBIx::QuickORM::Util::HashBase qw{
    +fetch_complete
    +pid
    +exception
};

# Use an Atomic::Pipe to send stderr, stdout, and objects back to parent

sub init {
    my $self = shift;

    $self->SUPER::init();

    $self->_start;
}

sub discard {
    my $self = shift;

    $self->cancel;
    delete $self->{+ROWS};
    delete $self->{+FETCH_COMPLETE};
    $self->_start;

    return;
}

sub count {
    my $self = shift;

    return scalar @{$self->{+ROWS}} if $self->{+FETCH_COMPLETE};

    return $self->{+SOURCE}->count_select($self->params);
}

sub _start {}

# Ignores exceptions
sub cancel {}

# Returns an exception (not throw)
sub broken {}

# Throw exceptions if we see any
sub ready {}

sub _rows { croak "unsupported" }

sub _fetch_row {
    # Throw exception
}

# Exceptions get thrown
sub all   {}
sub first {}
sub last  {}

# Exceptions get thrown
sub next {
    my $self = shift;
    my $i = $self->{+INDEX}++;
#    my $rows = $self->_rows;
#    return if $i > @$rows;
#    return $rows->[$i];
}

# Exceptions get thrown
sub previous {
    my $self = shift;
    my $i = $self->{+INDEX}--;

    if ($i < 0) {
        $self->{+INDEX} = 0;
        return;
    }

    my $rows = $self->{+ROWS};
    return if $i > @$rows;
    return $rows->[$i];
}

sub DESTROY {
    my $self = shift;
    $self->cancel;
}

1;
