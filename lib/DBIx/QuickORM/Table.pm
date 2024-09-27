package DBIx::QuickORM::Table;
use strict;
use warnings;

use Carp qw/croak/;
use Storable qw/dclone/;
use Scalar::Util qw/blessed/;

use DBIx::QuickORM::Util qw/merge_hash_of_objs/;

use DBIx::QuickORM::Util::HashBase qw{
    <name
    <columns
    <relations
    <indexes
    <unique
    <primary_key
    <is_view
    <is_temp
};

use DBIx::QuickORM::Util::Has qw/Plugins Created SQLSpec/;

sub init {
    my $self = shift;

    croak "The 'name' attribute is required" unless $self->{+NAME};

    my $cols = $self->{+COLUMNS} or croak "The 'columns' attribute is required";
    croak "The 'columns' attribute must be a hashref" unless ref($cols) eq 'HASH';
    croak "The 'columns' hash may not be empty" unless keys %$cols;

    for my $cname (sort keys %$cols) {
        my $cval = $cols->{$cname} or croak "Column '$cname' is empty";
        croak "Columns '$cname' is not an instance of 'DBIx::QuickORM::Table::Column', got: '$cval'" unless blessed($cval) && $cval->isa('DBIx::QuickORM::Table::Column');
    }

    $self->{+RELATIONS} //= {};
    $self->{+INDEXES}   //= {};

    $self->{+IS_VIEW} //= 0;
    $self->{+IS_TEMP} //= 0;
}

sub add_relation {
    my $self = shift;
    my ($accessor, $relation) = @_;

    if (my $ex = $self->{+RELATIONS}->{$accessor}) {
        return if $ex eq $relation;
        croak "Relation '$accessor' already defined";
    }

    croak "'$relation' is not an instance of 'DBIx::QuickORM::Relation'" unless $relation->isa('DBIx::QuickORM::Relation');

    $self->{+RELATIONS}->{$accessor} = $relation;
}

sub relation {
    my $self = shift;
    my ($accessor) = @_;

    return $self->{+RELATIONS}->{$accessor} // undef;
}

sub column_names { keys %{$_[0]->{+COLUMNS}} }

sub column {
    my $self = shift;
    my ($cname) = @_;

    return $self->{+COLUMNS}->{$cname} // undef;
}

sub merge {
    my $self = shift;
    my ($other, %params) = @_;

    $params{+SQL_SPEC}    //= $self->{+SQL_SPEC}->merge($other->{+SQL_SPEC});
    $params{+PLUGINS}     //= $self->{+PLUGINS}->merge($other->{+PLUGINS});
    $params{+COLUMNS}     //= merge_hash_of_objs($self->{+COLUMNS}, $other->{+COLUMNS});
    $params{+UNIQUE}      //= {map { ($_ => [@{$self->{+UNIQUE}->{$_}}]) } keys %{$self->{+UNIQUE}}};
    $params{+RELATIONS}   //= {%{$other->{+RELATIONS}}, %{$self->{+RELATIONS}}};
    $params{+INDEXES}     //= {%{$other->{+INDEXES}},   %{$self->{+INDEXES}}};
    $params{+PRIMARY_KEY} //= [@{$self->{+PRIMARY_KEY} // $other->{+PRIMARY_KEY}}] if $self->{+PRIMARY_KEY} || $other->{+PRIMARY_KEY};

    my $new = ref($self)->new(%$self, %params);
}

sub clone {
    my $self   = shift;
    my %params = @_;

    $params{+SQL_SPEC}    //= $self->{+SQL_SPEC}->clone();
    $params{+PLUGINS}     //= $self->{+PLUGINS}->clone();
    $params{+RELATIONS}   //= {%{$self->{+RELATIONS}}};
    $params{+INDEXES}     //= {%{$self->{+INDEXES}}};
    $params{+PRIMARY_KEY} //= [@{$self->{+PRIMARY_KEY}}] if $self->{+PRIMARY_KEY};
    $params{+COLUMNS}     //= {map { ($_ => $self->{+COLUMNS}->{$_}->clone) } keys %{$self->{+COLUMNS}}};
    $params{+UNIQUE}      //= {map { ($_ => [@{$self->{+UNIQUE}->{$_}}]) } keys %{$self->{+UNIQUE}}};

    my $new = ref($self)->new(%$self, %params);
}

1;
