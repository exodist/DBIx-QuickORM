package DBIx::QuickORM::Relation;
use strict;
use warnings;

use Carp qw/croak/;

use DBIx::QuickORM::Util::HashBase qw{
    +tables
    <index
    <identity
    <accessors
};

use DBIx::QuickORM::Util::Has qw/Plugins Created SQLSpec/;

sub init {
    my $self = shift;

    my $t = $self->{+TABLES} or croak "No tables specified";

    @$t = sort { $a->{table} cmp $b->{table} } @$t;

    croak "A relation may not be empty"                if @$t < 1;
    croak "A relation may not have more than 2 tables" if @$t > 2;

    my $index;
    my $identity;
    my @links = reverse @$t;

    my $accessors = $self->{+ACCESSORS} //= {};

    for my $table (@$t) {
        my $name = $table->{table} or croak "Table in relation did not have a table name";

        my $cols = $table->{columns} or croak "Table '$name' did not provide any columns for relation";
        croak "Table '$name' has an empty column list for the relation" unless @$cols;

        my $table_idx = "$name(" . join(',' => sort(@$cols)) . ")";

        # Fixme: This needs a better error message
        croak "Cannot list the same table + columns twice, Just list it once and no other tables if both members are identical"
            if $index && $table_idx eq $index;

        $index = $index ? "$index + $table_idx" : $table_idx;

        my $link = shift @links;

        # This should assign each table's accessor the name of the other table, unless it already has a name.
        # On 1-table relations it sets the accessor to the name of the table
        my $accessor = $table->{accessor} //= $link->{table};

        croak "Relation defines 2 accessors with the same name '$accessor' on table '$name'"
            if $accessors->{$name}->{$accessor};

        $accessors->{$name}->{$accessor} = [$cols, $link->{table}, $link->{columns}, $table->{reference} ? 1 : 0];

        $identity = $identity ? "$identity + $accessor($table_idx)" : "$accessor($table_idx)";
    }

    $self->{+INDEX}    = $index;
    $self->{+IDENTITY} = $identity;
}

sub members             { @{$_[0]->{+TABLES}} }
sub table_names         { sort keys %{$_[0]->{+ACCESSORS}} }
sub has_table           { $_[0]->{+ACCESSORS}->{$_[1]} ? 1 : 0 }
sub accessors_for_table { keys %{$_[0]->{+ACCESSORS}->{$_[1]} // croak("Table '$_[1]' has no accessors from this relation")} }

sub get_accessor {
    my $self = shift;
    my ($table, $accessor) = @_;

    my $t = $self->{+ACCESSORS}->{$table} or return undef;
    return $t->{$accessor} // undef;
}

1;
