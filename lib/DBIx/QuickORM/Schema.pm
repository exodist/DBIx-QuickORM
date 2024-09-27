package DBIx::QuickORM::Schema;
use strict;
use warnings;

use Carp qw/confess croak/;
use Scalar::Util qw/blessed/;

use DBIx::QuickORM::Util qw/merge_hash_of_objs/;

use DBIx::QuickORM::Schema::RelationSet;

use DBIx::QuickORM::Util::HashBase qw{
    <name
    +tables
    +relations
};

use DBIx::QuickORM::Util::Has qw/Created Plugins/;

sub init {
    my $self = shift;

    croak "'name' is a required attribute" unless $self->{+NAME};

    $self->{+RELATIONS} //= DBIx::QuickORM::Schema::RelationSet->new();

    for my $r ($self->{+RELATIONS}->all) {
        for my $tname ($r->table_names) {
            my $table = $self->{+TABLES}->{$tname} or croak "Relation refers to table '$tname', but no such table exists in this schema.";

            $table = $table->clone;
            $self->{+TABLES}->{$tname} = $table;

            for my $accessor ($r->accessors_for_table($tname)) {
                $table->add_relation($accessor => $r);
            }
        }
    }
}

sub relation_set { $_[0]->{+RELATIONS} }
sub relations    { $_[0]->{+RELATIONS}->all }
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
    $params{+RELATIONS} //= $self->{+RELATIONS}->merge($other->{+RELATIONS});
    $params{+PLUGINS}   //= $self->{+PLUGINS}->merge($other->{+PLUGINS});
    $params{+NAME}      //= $self->{+NAME};

    return ref($self)->new(%$self, %params);
}

sub clone {
    my $self   = shift;
    my %params = @_;

    $params{+TABLES}    //= [map { $_->clone } $self->tables];
    $params{+RELATIONS} //= $self->{+RELATIONS}->clone;
    $params{+NAME}      //= $self->{+NAME};
    $params{+PLUGINS}   //= $self->{+PLUGINS}->clone();

    return ref($self)->new(%$self, %params);
}

1;
