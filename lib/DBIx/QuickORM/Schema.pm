package DBIx::QuickORM::Schema;
use strict;
use warnings;

use DBIx::QuickORM::Table;
use DBIx::QuickORM::Meta::Table;
use DBIx::QuickORM::Meta::RelationSet;

use Carp qw/croak/;
use Scalar::Util qw/blessed/;
use DBIx::QuickORM::Util qw/mod2file/;

use DBIx::QuickORM::HashBase qw{
    <name
    <db
    +table_class
    <meta_tables
    <tables

    <auto_fill

    <compiled
    <filled

    <relations
};

sub clone {
    my $self = shift;
    my ($name, %params) = @_;

    my $class     = delete($params{class})     // blessed($self);
    my $relations = delete($params{relations}) // $self->{+RELATIONS}->clone;

    return $class->new(
        name => $name // "Copy of " . $self->{+NAME},

        table_class => $self->table_class,
        relations   => $relations,
        meta_tables => [map { $_->clone(relations => $relations) } @{$self->{+META_TABLES}}],

        db        => $self->{+DB},
        filled    => $self->{+FILLED},
        compiled  => $self->{+COMPILED},
        auto_fill => $self->{+AUTO_FILL},

        %params,
    );
}

sub init {
    my $self = shift;

    unless ($self->{+NAME}) {
        my @caller = caller(1);
        $self->{+NAME} = ref($self) . " created at $caller[1] line $caller[2]";
    }

    $self->{+META_TABLES} //= {};
    $self->{+RELATIONS} //= DBIx::QuickORM::Meta::RelationSet->new();

    return $self;
}

sub set_auto_fill { $_[0]->{+AUTO_FILL} = 1 }
sub clear_cache   { $_[0]->{+TABLES}    = {} }
sub table_class   { $_[0]->{+TABLE_CLASS} //= 'DBIx::QuickORM::Table' }

sub relation     { shift->{+RELATIONS}->relation(@_) }
sub add_relation { $_[0]->{+RELATIONS}->add_relation($_[1]) }

sub set_db {
    my $self = shift;
    my ($db) = @_;

    croak "Database has already been set" if $self->{+DB};

    $self->{+DB} = $db;

    return $db;
}

sub set_table_class {
    my $self = shift;
    my ($class) = @_;

    eval { require(mod2file($class)); 1 } or croak "Could not load table class '$class': $@";
    croak "'$class' is not a subclass of 'DBIx::QuickORM::Table'" unless $class->isa('DBIx::QuickORM::Table');

    $self->{+TABLE_CLASS} = $class;

    for my $table (values %{$self->{+TABLES}}) {
        $class->reclass($table);
    }

    return $class;
}

sub table {
    my $self = shift;
    my ($name) = @_;

    return $self->{+TABLES}->{$name} if $self->{+TABLES}->{$name};

    my $db = $self->{+DB} or croak "No database defined";

    my $meta = $self->meta_table($name) or croak "Invalid table name '$name'";

    return $self->{+TABLES}->{$name} = $self->table_class->new(
        meta_table => $meta,
        schema     => $self,
        db         => $db,
    );
}

sub meta_table {
    my $self = shift;
    my ($name, %params) = @_;

    $self->recompile if !$self->{+COMPILED} || ($self->db && !$self->{+FILLED});

    return $self->{+META_TABLES}->{$name};
}

sub add_table {
    my $self = shift;
    my ($meta_table) = @_;

    my $name = $meta_table->name;
    croak "Table '$name' is already defined" if $self->{+META_TABLES}->{$name};

    $self->{+RELATIONS}->merge_in($meta_table->relations);
    $meta_table = $meta_table->clone(relations => $self->relations);

    $self->{+META_TABLES}->{$name} = $meta_table;
    $self->do_fill($name) if $self->{+FILLED};

    return $meta_table;
}

sub recompile {
    my $self = shift;

    if ($self->{+DB} && $self->{+AUTO_FILL} && !$self->{+FILLED}) {
        $self->_do_auto_fill();
    }

    $_->recompile(schema => $self) for values %{$self->{+META_TABLES}};

    $self->{+COMPILED} = 1;
}

sub _do_auto_fill {
    my $self = shift;

    my $tables = $self->db->get_tables;

    $self->_do_fill($_ => $tables->{$_}) for keys %$tables;

    $self->{+COMPILED} = 1;
    $self->{+FILLED} = 1;
}

sub _do_fill {
    my $self = shift;
    my ($name, $from_db) = @_;

    $from_db //= $self->db->get_table($name);

    my $meta;
    if ($meta = $self->{+META_TABLES}->{$name}) {
        $meta->fill(schema => $self, from_db => $from_db);
    }
    else {
        $self->add_table($from_db);
    }
}

sub clone_for_db {
    my $self = shift;
    my ($db) = @_;

    croak "This schema has already been compled for a DB. clone_for_db() can only be used on an uncompiled schema" if $self->db;

    my $new = $self->clone;
    $new->set_db($db);
    $new->recompile;

    return $new;
}

1;
