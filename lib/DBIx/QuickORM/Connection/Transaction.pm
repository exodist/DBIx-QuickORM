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

    <result
    <error

    <rolled_back
    <committed
};

sub is_savepoint { $_[0]->{+SAVEPOINT} ? 1 : 0 }

sub init {
    my $self = shift;

    croak "A transaction ID is required" unless $self->{+ID};

    $self->{+RESULT} = undef;
}

{
    no warnings 'once';
    *abort = \&rollback;
}
sub rollback {
    my $self = shift;
    my ($why) = @_;

    unless ($why) {
        my @caller = caller;
        $why = "$caller[1] line $caller[2]";
    }

    $self->{+ROLLED_BACK} = $why;

    no warnings 'exiting';
    last QORM_TRANSACTION;
};

sub commit {
    my $self = shift;

    my ($why) = @_;

    unless ($why) {
        my @caller = caller;
        $why = "$caller[1] line $caller[2]";
    }

    $self->{+COMMITTED} = $why;

    no warnings 'exiting';
    last QORM_TRANSACTION;
}

sub terminate {
    my $self = shift;
    my ($res, $err) = @_;

    $self->{+RESULT} = $res ? 1 : 0;
    $self->{+ERROR} = $res ? undef : $err;

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
