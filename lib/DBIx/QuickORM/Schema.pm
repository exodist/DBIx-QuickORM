package DBIx::QuickORM::Schema;
use strict;
use warnings;

use Carp qw/confess croak/;
use Scalar::Util qw/blessed/;

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
                $table->add_accessor($accessor => $r);
            }
        }
    }
}

sub relation_set { $_[0]->{+RELATIONS} }
sub relations { $_[0]->{+RELATIONS}->all }
sub tables    { values %{$_[0]->{+TABLES}} }

sub clone       { }
sub merge       { }
sub add_table   { }
sub table       { }
sub maybe_table { }

1;
