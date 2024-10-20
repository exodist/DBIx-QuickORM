package DBIx::QuickORM::RowState;
use strict;
use warnings;

use Carp qw/croak confess/;
use Scalar::Util qw/refaddr/;
use DBIx::QuickORM::Util qw/equ/;

use DBIx::QuickORM::Util::HashBase qw{
    +from_db
    +dirty
    +inflated
    +uncached
    +tainted
    +types
};

my %VALID_KEYS = (
    FROM_DB()     => FROM_DB(),
    DIRTY()       => DIRTY(),
    INFLATED()    => INFLATED(),
    UNCACHED()    => UNCACHED(),
    TAINTED()     => TAINTED(),
    TYPES()       => TYPES(),
);

sub init {
    my $self = shift;

    if (my @bad = sort grep { !$VALID_KEYS{$_} } keys %$self) {
        croak "Invalid row data keys: " . join(', ' => @bad);
    }
}

sub is_tainted { $_[0]->{+TAINTED}  ? 1 : 0 }
sub is_stored  { $_[0]->{+FROM_DB}  ? 1 : 0 }
sub is_dirty   { $_[0]->{+DIRTY}    ? 1 : 0 }
sub uncached   { $_[0]->{+UNCACHED} ? 1 : 0 }

sub stored   { my $s = $_[0]->{+FROM_DB};  $s ? ($_[1] ? $s->{$_[1]} : $s) : undef }
sub dirty    { my $d = $_[0]->{+DIRTY};    $d ? ($_[1] ? $d->{$_[1]} : $d) : undef }
sub inflated { my $i = $_[0]->{+INFLATED}; $i ? ($_[1] ? $i->{$_[1]} : $i) : undef }
sub types    { my $t = $_[0]->{+TYPES};    $t ? ($_[1] ? $t->{$_[1]} : $t) : undef }

sub raw { $_[0]->dirty($_[1])    // $_[0]->stored($_[1]) // undef }
sub val { $_[0]->inflated($_[1]) // $_[0]->raw($_[1])    // undef }

sub inflate { $_[0]->{+INFLATED}->{$_[1]} = $_[2] }

sub uncache {
    my $self = shift;

    $self->{+UNCACHED} = 1;

    if (my $fdb = delete $self->{+FROM_DB}) {
        my $dirty = $self->{+DIRTY} //= {};
        $dirty->{$_} //= $fdb->{$_} for keys %$fdb;
    }

    return $self;
}

sub refresh {
    my $self   = shift;
    my %params = @_;

    my $new_db = $params{+FROM_DB};

    my $inf   = $self->{+INFLATED};
    my $db    = $self->{+FROM_DB} //= {};
    my $types = $self->{+TYPES}   //= {};

    for my $field (keys %$new_db) {
        next if equ($db->{$field}, $new_db->{$field}, $types->{$field});
        $db->{$field} = $new_db->{$field};
        delete $inf->{$field} if $inf;
    }

    return $self;
}

sub reset {
    my $self = shift;
    my ($name) = @_;

    if ($name) {
        delete $self->{+DIRTY}->{$name};
        delete $self->{+DIRTY} unless keys %{$self->{+DIRTY}};
        $self->clear_inflated($name);
    }
    else {
        delete $self->{+DIRTY};
        delete $self->{+TAINTED};
    }

    return $self;
}

sub set_inflated {
    my $self = shift;
    my ($name, $inf_val) = @_;

    my $inf = $self->{+INFLATED} //= {};
    $inf->{$name} = $inf_val;

    return $self;
}

sub unset_inflated {
    my $self = shift;
    my ($name) = @_;

    my $inf = $self->{+INFLATED} or return $self;

    delete $inf->{$name};

    return $self;
}

sub set {
    my $self = shift;
    my ($name, $raw, $inf) = @_;

    my $dirty = $self->{+DIRTY} //= {};
    $dirty->{$name} = $raw;

    defined($inf) ? $self->set_inflated($name, $inf) : $self->unset_inflated($name);

    return $self;
}

sub unset {
    my $self = shift;
    my ($name) = @_;

    my $dirty = $self->{+DIRTY} //= {};
    $dirty->{$name} = undef;
    $self->unset_inflated($name);

    return $self;
}

sub has_field {
    my $self = shift;
    my ($name) = @_;

    if (my $fdb = $self->{+FROM_DB}) {
        return 1 if exists $fdb->{$name};
    }

    if (my $dirty = $self->{+DIRTY}) {
        return 1 if exists $dirty->{$name};
    }

    return 0;
}

sub save {
    my $self = shift;

    my $dirty   = delete $self->{+DIRTY} or return;
    my $from_db = $self->{+FROM_DB} //= {};
    %{$from_db} = {%$from_db, %$dirty};

    return $self;
}

1;
