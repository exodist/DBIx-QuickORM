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

    if (my $sql_type = $params{sql_type}) {
        return 'string' if lc($sql_type) eq 'uuid';
        return 'binary' if $sql_type =~ m/(bin(ary)?|bytea?|blob)/i;
    }

    if (my $dialect = $params{dialect}) {
        return 'string' if $dialect->supports_type('uuid');
    }

    return 'string';
}

sub qorm_sql_type {
    my $self = shift;
    my ($dialect) = @_;

    if (my $stype = $dialect->supports_type('uuid')) {
        return $stype;
    }

    # FIXME: We need a binary subclass
    # We also need to go thorugh the supprots-type system
    return 'VARCHAR(36)';
}

sub looks_like_uuid {
    my $in = pop;
    return $in if $in && $in =~ m/^[A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12}$/i;
    return undef;
}

sub qorm_register_type {
    my $self = shift;
    my ($types, $affinities) = @_;

    my $class = ref($self) || $self;

    $types->{uuid} //= $class;

    push @{$affinities->{binary}} => sub {
        my %params = @_;
        return $class if $params{name}    =~ m/uuid/i;
        return $class if $params{db_name} =~ m/uuid/i;
        return;
    };

    push @{$affinities->{string}} => sub {
        my %params = @_;
        return $class if $params{name}    =~ m/uuid/i;
        return $class if $params{db_name} =~ m/uuid/i;
        return;
    };
}

1;
