package DBIx::QuickORM::Connection::Transaction;
use strict;
use warnings;

use Carp qw/croak/;

use DBIx::QuickORM::Util::HashBase qw{
    <id
    +savepoint

    +on_success
    +on_fail
    +on_completion

    verbose

    <result
    <errors

    <rolled_back
    <committed
};

sub is_savepoint { $_[0]->{+SAVEPOINT} ? 1 : 0 }

sub init {
    my $self = shift;

    croak "A transaction ID is required" unless $self->{+ID};

    $self->{+RESULT} = undef;

    $self->{+ON_SUCCESS}    = [$self->{+ON_SUCCESS}]    if ref($self->{+ON_SUCCESS}) eq 'CODE';
    $self->{+ON_FAIL}       = [$self->{+ON_FAIL}]       if ref($self->{+ON_FAIL}) eq 'CODE';
    $self->{+ON_COMPLETION} = [$self->{+ON_COMPLETION}] if ref($self->{+ON_COMPLETION}) eq 'CODE';
}

sub complete { defined $_[0]->{+RESULT} }

{
    no warnings 'once';
    *abort = \&rollback;
}
sub rollback {
    my $self = shift;
    my ($why) = @_;

    if ($self->{+VERBOSE} || !$why) {
        my @caller = caller;
        my $trace = "$caller[1] line $caller[2]";

        if (my $verbose = $self->{+VERBOSE}) {
            my $name = length($verbose) > 1 ? $verbose : $self->{+ID};
            warn "Transaction '$name' rolled back in $trace" . ($why ? " ($why)" : ".") . "\n";
        }

        if ($why) {
            $why .= " in $trace" unless $why =~ m/\n$/;
        }
        else {
            $why = $trace;
        }
    }

    $self->{+ROLLED_BACK} = $why;

    no warnings 'exiting';
    last QORM_TRANSACTION;
};

sub commit {
    my $self = shift;
    my ($why) = @_;

    if ($self->{+VERBOSE} || !$why) {
        my @caller = caller;
        my $trace = "$caller[1] line $caller[2]";

        if (my $verbose = $self->{+VERBOSE}) {
            my $name = length($verbose) > 1 ? $verbose : $self->{+ID};
            warn "Transaction '$name' committed in $trace" . ($why ? " ($why)" : ".") . "\n";
        }

        if ($why) {
            $why .= " in $trace" unless $why =~ m/\n$/;
        }
        else {
            $why = $trace;
        }
    }

    $self->{+COMMITTED} = $why;

    no warnings 'exiting';
    last QORM_TRANSACTION;
}

sub terminate {
    my $self = shift;
    my ($res, $err) = @_;

    $self->{+RESULT} = $res ? 1 : 0;
    $self->{+ERRORS} = $res ? undef : $err;

    my $todo = $res ? $self->{+ON_SUCCESS} : $self->{+ON_FAIL};
    $todo = [@{$todo // []}, @{$self->{+ON_COMPLETION} // []}];

    delete $self->{+ON_SUCCESS};
    delete $self->{+ON_FAIL};
    delete $self->{+ON_COMPLETION};
    delete $self->{+SAVEPOINT};

    return (1, undef) unless $todo && @$todo;

    my ($out, $out_err) = (1, undef);
    for my $cb (@$todo) {
        local $@;
        eval { $cb->($self); 1 } and next;
        push @{$out_err //= []} => $@;
        $out = 0;
    }

    return ($out, $out_err);
}

sub add_success_callback {
    my $self = shift;
    my ($cb) = @_;
    push @{$self->{+ON_SUCCESS} //= []} => $cb;
}

sub add_fail_callback {
    my $self = shift;
    my ($cb) = @_;
    push @{$self->{+ON_FAIL} //= []} => $cb;
}

sub add_completion_callback {
    my $self = shift;
    my ($cb) = @_;
    push @{$self->{+ON_COMPLETION} //= []} => $cb;
}

1;
