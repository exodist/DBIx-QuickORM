package DBIx::QuickORM::Schema;
use strict;
use warnings;

use Carp qw/confess croak/;
use Scalar::Util qw/blessed/;

use DBIx::QuickORM::Util qw/merge_hash_of_objs/;

use DBIx::QuickORM::Util::HashBase qw{
    <name
    +tables
};

use DBIx::QuickORM::Util::Has qw/Created Plugins/;

sub init {
    my $self = shift;

    croak "'name' is a required attribute" unless $self->{+NAME};
}

sub verify_relations {
    my $self = shift;

    for my $table ($self->tables) {
        my $rels = $table->relations;
        for my $alias (keys %$rels) {
            my $rel = $rels->{$alias};
            my $t2 = $rel->table;
            next if $self->{+TABLES}->{$t2};

            my $t1 = $table->name;
            confess "Relation '$alias' in table '$t1' points to table '$t2' but that table does not exist";
        }
    }
}

sub tables       { values %{$_[0]->{+TABLES}} }
sub table        { $_[0]->{+TABLES}->{$_[1]} or croak "Table '$_[1]' is not defined" }
sub maybe_table  { return $_[0]->{+TABLES}->{$_[1]} // undef }

sub add_table {
    my $self = shift;
    my ($name, $table) = @_;

    croak "Table '$name' already defined" if $self->{+TABLES}->{$name};

    return $self->{+TABLES}->{$name} = $table;
}

sub merge {
    my $self = shift;
    my ($other, %params) = @_;

    $params{+TABLES}    //= merge_hash_of_objs($self->{+TABLES}, $other->{+TABLES});
    $params{+PLUGINS}   //= $self->{+PLUGINS}->merge($other->{+PLUGINS});
    $params{+NAME}      //= $self->{+NAME};

    return ref($self)->new(%$self, %params);
}

sub clone {
    my $self   = shift;
    my %params = @_;

    $params{+TABLES}    //= [map { $_->clone } $self->tables];
    $params{+NAME}      //= $self->{+NAME};
    $params{+PLUGINS}   //= $self->{+PLUGINS}->clone();

    return ref($self)->new(%$self, %params);
}

1;
