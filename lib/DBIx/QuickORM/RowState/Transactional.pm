package DBIx::QuickORM::Row::DataStack;
use strict;
use warnings;

use Carp qw/croak confess/;
use Scalar::Util qw/refaddr/;
use DBIx::QuickORM::Util qw/equ/;

use constant FROM_DB     => 'from_db';
use constant DIRTY       => 'dirty';
use constant INFLATED    => 'inflated';
use constant TRANSACTION => 'transaction';
use constant TAINTED     => 'tainted';
use constant TYPES       => 'types';
use constant UNCACHED    => 'uncached';

use constant CURRENT => 0;

my %VALID_KEYS = (
    FROM_DB()     => FROM_DB(),
    DIRTY()       => DIRTY(),
    INFLATED()    => INFLATED(),
    TRANSACTION() => TRANSACTION(),
    TYPES()       => TYPES(),
    TAINTED()     => TAINTED(),
    UNCACHED()    => UNCACHED(),
);

sub new {
    my $class = shift;
    my ($data) = @_;

    if (my @bad = sort grep { !$VALID_KEYS{$_} } keys %$data) {
        croak "Invalid row data keys: " . join(', ' => @bad);
    }

    return bless([$data], $class);
}

sub current    { $_[0]->squash->[+CURRENT] //= {} }
sub is_tainted { $_[0]->current->{+TAINTED}  ? 1 : 0 }
sub is_stored  { $_[0]->current->{+FROM_DB}  ? 1 : 0 }
sub is_dirty   { $_[0]->current->{+DIRTY}    ? 1 : 0 }
sub uncached   { $_[0]->current->{+UNCACHED} ? 1 : 0 }

sub stored   { my $s = $_[0]->current->{+FROM_DB};  $s ? ($_[1] ? $s->{$_[1]} : $s) : undef }
sub dirty    { my $d = $_[0]->current->{+DIRTY};    $d ? ($_[1] ? $d->{$_[1]} : $d) : undef }
sub inflated { my $i = $_[0]->current->{+INFLATED}; $i ? ($_[1] ? $i->{$_[1]} : $i) : undef }
sub types    { my $t = $_[0]->current->{+TYPES};    $t ? ($_[1] ? $t->{$_[1]} : $t) : undef }

sub raw { $_[0]->dirty($_[1])    // $_[0]->stored($_[1]) // undef }
sub val { $_[0]->inflated($_[1]) // $_[0]->raw($_[1])    // undef }

sub inflate { $_[0]->current->{+INFLATED}->{$_[1]} = $_[2] }

my @SQUASH_LIST = (FROM_DB(), DIRTY(), INFLATED(), TYPES());

sub uncache {
    my $self = shift;

    my $cur = $self->current;
    @$self = ($cur);

    $cur->{+UNCACHED} = 1;
    delete $cur->{+TRANSACTION};

    if (my $fdb = delete $cur->{+FROM_DB}) {
        my $dirty = $cur->{+DIRTY} //= {};
        $dirty->{$_} //= $fdb->{$_} for keys %$fdb;
    }

    return $self;
}

sub squash {
    my $self = shift;

    # Optimization for super simple cases
    if (@$self == 1) {
        my $c = $self->[+CURRENT];
        my $txn = $c->{+TRANSACTION} or return $self;
        my $final = $txn->finalized or return $self;
        if ($final eq 'commit'){
            delete $c->{+TRANSACTION};
            return $self;
        }

        @$self = ({});
        return $self;
    }

    # Well, time for an expensive unwind

    my @todo = @$self;

    my $state;
    for my $cur (@todo) {
        if ($state) {
            @{$cur}{@SQUASH_LIST} = @{$state}{@SQUASH_LIST};
            delete $cur->{+TAINTED};
            $state = undef;
        }

        my $txn = $cur->{+TRANSACTION} or last;
        my $fin = $txn->finalized      or last;

        if ($fin eq 'commit') {
            if (@$self == 1) {
                delete $cur->{+TRANSACTION};
                return;
            }

            $state = $cur;
        }

        shift(@$self);
    }

    return $self;
}

sub refresh {
    my $self   = shift;
    my %params = @_;

    my $new_db  = $params{+FROM_DB};
    my $new_txn = $params{+TRANSACTION};

    my $cur     = $self->current;
    my $cur_txn = $cur->{+TRANSACTION};
    my $cur_inf = $cur->{+INFLATED};

    my $txn_change = ($cur_txn xor $new_txn) || ($new_txn && $cur_txn && $new_txn != $cur_txn);

    unless ($txn_change) {
        my $cur_db = $cur->{+FROM_DB} //= {};

        for my $field (keys %$new_db) {
            next if equ($cur_db->{$field}, $new_db->{$field}, $cur->{+TYPES}->{$field});
            $cur_db->{$field} = $new_db->{$field};
            delete $cur_inf->{$field} if $cur_inf;
        }

        return $self;
    }

    confess "Attempt to refresh data from outside of a transaction while row has an active transaction"
        if $cur_txn && !$new_txn;

    my $new = {FROM_DB() => $new_db, TRANSACTION() => $new_txn, TYPES => $cur->{+TYPES}};

    if (my $t = $cur->{+DIRTY} // $cur->{+TAINTED}) {
        $new->{+TAINTED} = $t;
        $new->{+DIRTY}   = {%{$self->{+DIRTY}}};
    }

    push @$self => $new;

    return $self;
}

sub reset {
    my $self = shift;
    my ($name) = @_;

    my $cur = $self->current;

    if ($name) {
        delete $cur->{+DIRTY}->{$name};
        delete $cur->{+DIRTY} unless keys %{$self->{+DIRTY}};
        $self->clear_inflated($name);
    }
    else {
        delete $cur->{+DIRTY};
        delete $cur->{+TAINTED};
    }

    return $self;
}

sub set_inflated {
    my $self = shift;
    my ($name, $inf) = @_;

    my $c = $self->current;

    $c->{+INFLATED}->{$name} = $inf;

    return $self;
}

sub unset_inflated {
    my $self = shift;
    my ($name) = @_;

    my $c = $self->current;

    delete $c->{+INFLATED}->{$name};

    return $self;
}

sub set {
    my $self = shift;
    my ($name, $raw, $inf) = @_;

    my $c = $self->current;

    $c->{+DIRTY}->{$name} = $raw;
    defined($inf) ? $self->set_inflated($name, $inf) : $self->unset_inflated($name);

    return $self;
}

sub unset {
    my $self = shift;
    my ($name) = @_;

    my $c = $self->current;

    $c->{+DIRTY}->{$name} = undef;
    $self->unset_inflated($name);

    return $self;
}

sub has_field {
    my $self = shift;
    my ($name) = @_;

    my $c = $self->current;

    return 1 if exists($c->{+FROM_DB}->{$name});
    return 1 if exists($c->{+DIRTY}->{$name});
    return 0;
}

sub save {
    my $self = shift;

    my $c = $self->current;

    my $dirty   = delete $c->{+DIRTY} or return;
    my $from_db = $c->{+FROM_DB} //= {};
    %{$from_db} = {%$from_db, %$dirty};

    return $self;
}

1;
