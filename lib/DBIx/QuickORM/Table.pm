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
    <row_class

    +deps
};

use DBIx::QuickORM::Util::Has qw/Plugins Created SQLSpec/;

sub sqla_columns { [$_[0]->column_names] }

sub sqla_source  { $_[0]->{+NAME} }

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

    $self->{+ROW_CLASS} //= 'DBIx::QuickORM::Row';

    $self->{+RELATIONS} //= {};
    $self->{+INDEXES}   //= {};

    $self->{+IS_VIEW} //= 0;
    $self->{+IS_TEMP} //= 0;
}

sub prefetch_relations {
    my $self = shift;
    my ($add) = @_;

    if ($add) {
        my $todo = ref($add) ? $add : [$add];
        $add = {};
        for my $name (@$todo) {
            $add->{$name} = $self->{+RELATIONS}->{$name} or croak "Relation '$name' does not exist, cannot prefetch";
        }
    }

    my $tname = $self->{+NAME};

    my @prefetch;
    for my $alias (keys %{$self->{+RELATIONS}}) {
        my $relation = $self->{+RELATIONS}->{$alias};
        next unless $relation->prefetch || ($add && $add->{$alias});
        push @prefetch => [$alias => $relation];
    }

    return \@prefetch;
}

sub add_relation {
    my $self = shift;
    my ($name, $relation) = @_;

    if (my $ex = $self->{+RELATIONS}->{$name}) {
        return if $ex->compare($relation);
        croak "Relation '$name' already defined";
    }

    croak "'$relation' is not an instance of 'DBIx::QuickORM::Table::Relation'" unless $relation->isa('DBIx::QuickORM::Table::Relation');

    $self->{+RELATIONS}->{$name} = $relation;
}

sub relation {
    my $self = shift;
    my ($name) = @_;

    return $self->{+RELATIONS}->{$name} // undef;
}

sub deps {
    my $self = shift;
    return $self->{+DEPS} //= { map {( $_->table() => 1 )} grep { $_->gets_one } values %{$self->{+RELATIONS} // {}} };
}

sub column_names { keys %{$_[0]->{+COLUMNS}} }

sub column {
    my $self = shift;
    my ($cname, $row) = @_;

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
    $params{+DEPS}        //= undef;

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
