package DBIx::QuickORM::Type::UUID;
use strict;
use warnings;

use Role::Tiny::With qw/with/;
with 'DBIx::QuickORM::Role::Type';

use Scalar::Util qw/blessed/;
use UUID qw/uuid7 parse unparse/;

use DBIx::QuickORM::Util::HashBase qw{
    +string
    +binary
};

sub init {
    my $self = shift;

    unless ($self->{+STRING} || $self->{+BINARY}) {
        $self->{+STRING} = uuid7();
    }
}

sub string {
    my $self = shift;
    my $s;
    unparse($self->{+BINARY}, $s) unless $self->{+STRING};
    return $self->{+STRING} //= $s;
}

sub binary {
    my $self = shift;
    my $b;
    parse($self->{+STRING}, $b) unless $self->{+BINARY};
    return $self->{+BINARY} //= $b;
}

sub qorm_inflate {
    my $in = pop;

    return $in if blessed($in) && $in->isa(__PACKAGE__);

    my $class = shift // __PACKAGE__;

    my %params;

    if ($class->looks_like_uuid($in)) {
        $params{+STRING} = $in;
    }
    else {
        $params{+BINARY} = $in;
    }

    return $class->new(%params);
}

sub qorm_deflate {
    my $affinity = pop;
    my $in = pop;

    unless (blessed($in) && $in->isa(__PACKAGE__)) {
        my $class = shift // __PACKAGE__;
        $in = $class->qorm_inflate($in);
    }

    return $in->$affinity;
}

sub qorm_compare {
    return 0;
}

sub qorm_affinity {
    my $class = shift;
    my %params = @_;

    my $dialect = $params{dialect};

    return 'string' if $dialect->supports_type('uuid');
}

sub looks_like_uuid {
    my $in = pop;
    return $in if $in && $in =~ m/^[A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12}$/i;
    return undef;
}

1;
