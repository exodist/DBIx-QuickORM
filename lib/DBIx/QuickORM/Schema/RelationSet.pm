package DBIx::QuickORM::Schema::RelationSet;
use strict;
use warnings;

use Carp qw/croak/;
use Scalar::Util qw/blessed/;

sub new;

use DBIx::QuickORM::Util::HashBase qw{
    +by_index
    +by_identity
    +by_table_and_accessor
};

sub new {
    my $class = shift;
    my (@rels) = @_;

    my $self = bless({BY_INDEX() => {}, BY_IDENTITY() => {}, BY_TABLE_AND_ACCESSOR() => {}}, $class);

    $self->add_relation($_) for @rels;

    return $self;
}

sub add_relation {
    my $self = shift;
    my ($rel) = @_;

    # Exact duplicate can be skipped
    my $identity = $rel->identity;
    return if $self->{+BY_IDENTITY}->{$identity};

    $self->{+BY_IDENTITY}->{$identity} = $rel;

    my $index = $rel->index;
    push @{$self->{+BY_INDEX}->{$index} //= []} => $rel;

    for my $m ($rel->members) {
        my $table    = $m->{table};
        my $accessor = $m->{accessor};

        if (my $have = $self->{+BY_TABLE_AND_ACCESSOR}->{$table}->{$accessor}) {
            croak "Two relations have the same table-name combination ($table -> $accessor):\n"
                . "  relation 1 '" . $rel->index  . "' " . ($rel->created // "")  . "\n"
                . "  relation 2 '" . $have->index . "' " . ($have->created // "") . "\n";
        }

        $self->{+BY_TABLE_AND_ACCESSOR}->{$table}->{$accessor} = $rel;
    }

    return $rel;
}

sub by_index {
    my $self = shift;
    my ($index) = @_;
    return $self->{+BY_INDEX}->{$index} // undef;
}

sub equivelent {
    my $self = shift;
    my ($rel) = @_;
    return $self->{+BY_INDEX}->{$rel->index} // undef;
}

sub by_table_and_accessor {
    my $self = shift;
    my ($table_name, $accessor) = @_;
    my $table = $self->{+BY_TABLE_AND_ACCESSOR}->{$table_name} or return undef;
    return $table->{$accessor} // undef;
}

sub merge {
    my $self = shift;
    my ($them) = @_;

    return blessed($self)->new(
        $self->all,
        $them->all,
    );
}

sub merge_in {
    my $self = shift;
    my ($them) = @_;
    $self->add_relation($_) for $them->all;
}

sub all {
    my $self = shift;
    return values %{$self->{+BY_IDENTITY}};
}

sub names_for_table {
    my $self = shift;
    my ($table) = @_;
    return keys %{$self->{+BY_TABLE_AND_ACCESSOR}->{$table} // {}};
}

sub table_relations {
    my $self = shift;
    my ($table) = @_;
    return values %{$self->{+BY_TABLE_AND_ACCESSOR}->{$table} // {}};
}

sub clone {
    my $self = shift;
    return blessed($self)->new($self->all);
}

1;
