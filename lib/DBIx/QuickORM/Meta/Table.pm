package DBIx::QuickORM::Meta::Table;
use strict;
use warnings;
use feature 'state';

use DBIx::QuickORM::Meta::Column;
use DBIx::QuickORM::Meta::RelationSet;

use Scalar::Util qw/blessed/;
use Carp qw/croak/;

use DBIx::QuickORM::HashBase qw{
    <name
    <columns
    <relations
    <primary_key
    <primary_key_key
    +unique

    row_class

    <compiled
    <filled
};

sub clone {
    my $self = shift;
    my ($name, %params) = @_;

    my $class     = delete($params{class})     // blessed($self);
    my $relations = delete($params{relations}) // $self->{+RELATIONS}->clone;

    return $class->new(
        name            => $self->{+NAME},
        row_class       => $self->{+ROW_CLASS},
        primary_key_key => $self->{+PRIMARY_KEY_KEY},

        relations   => $relations,
        primary_key => [@{$self->{+PRIMARY_KEY}}],
        unique      => {%{$self->{+UNIQUE}}},
        columns     => {map { ($_->name() => $_->clone) } values %{$self->{+COLUMNS}}},

        %params,
    );
}

sub init {
    my $self = shift;

    croak "Table 'name' is a required attribute"    unless $self->{+NAME};
    croak "Table 'columns' is a required attribute" unless $self->{+COLUMNS};

    if (my $pk = $self->{+PRIMARY_KEY}) {
        $self->{+PRIMARY_KEY}     = [$pk] unless ref $pk;
        @$pk                      = sort @$pk;
        $self->{+PRIMARY_KEY_KEY} = join ',' => @$pk;
    }

    $self->{+UNIQUE}    //= {};
    $self->{+RELATIONS} //= DBIx::QuickORM::Meta::RelationSet->new;
}

sub add_relation { $_[0]->{+RELATIONS}->add_relation($_[1]) }

sub relation {
    my $self = shift;
    my ($name) = @_;

    return $self->{+RELATIONS}->relation($self->{+NAME}, $name);
}

sub column {
    my $self = shift;
    my ($col, %params) = @_;

    return $self->{+COLUMNS}->{$col};
}

sub column_names   { keys %{$_[0]->{+COLUMNS}} }
sub relation_names { $_[0]->{+RELATIONS}->names }

sub is_unique {
    my $self = shift;
    my (@cols) = @_;

    @cols = sort @cols;
    my $key = join ',' => @cols;

    return 1 if $self->{+PRIMARY_KEY_KEY} && $key eq $self->{+PRIMARY_KEY_KEY};
    return $self->{+UNIQUE}->{$key} ? 1 : 0;
}

sub add_column {
    my $self = shift;
    my ($col) = @_;

    my $name = $col->name;

    croak "Column '$name' already defined"         if $self->{+COLUMNS}->{$name};
    croak "Relation '$name' conflicts with column" if $self->{+RELATIONS}->{$name};

    $self->{+COLUMNS}->{$name} = $col->clone;
}

sub add_unique {
    my $self = shift;
    my (@cols) = @_;

    @cols = sort @cols;
    my $key = join ',' => @cols;

    $self->{+UNIQUE}->{$key} = \@cols;
}

sub fill {
    my $self   = shift;
    my %params = @_;

    return if $self->{+FILLED}++;

    my $name    = $self->{+NAME};
    my $schema  = $params{schema}                                   or croak "'schema' is a required argument";
    my $from_db = $params{from_db} // $schema->db->get_table($name) or croak "Database does not appear to have a '$name' table";

    $self->{+RELATIONS}->merge_missing_in($from_db->relations);

    for my $col (values %{$from_db->{+COLUMNS}}) {
        my $name = $col->name;
        if (my $x = $self->{+COLUMNS}->{$col}) {
            $x->fill(%params, from_db => $col, table => $name);
        }
        else {
            $self->add_column($col->clone);
        }
    }
}

sub recompile {
    my $self   = shift;
    my %params = @_;
    my $schema = $params{schema} or croak "'schema' is a required argument";

    my %pk = (map { $_ => 1 } @{$self->{+PRIMARY_KEY} // []});
    my $pk = [];

    for my $cname (sort keys %{$self->{+COLUMNS}}) {
        my $col = $self->{+COLUMNS}->{$cname};

        $col->set_primary_key(1) if $pk{$cname};
        $col->set_unique(1)      if $self->{+UNIQUE}->{$cname};

        $col->recompile(%params);

        push @$pk => $cname if $col->primary_key;
        $self->{+UNIQUE}->{$cname} = [$cname] if $col->unique;
    }

    $self->{+PRIMARY_KEY}     = $pk;
    $self->{+PRIMARY_KEY_KEY} = join ',' => @$pk;

    for my $ref (values %{$self->{+RELATIONS}}) {
        $ref->recompile(%params);
    }

    $self->inject_methods if $self->{+ROW_CLASS};

    $self->{+COMPILED} = 1;
}

sub inject_methods {
    my $self = shift;
    my (@list) = @_;

    my $class = $self->{+ROW_CLASS};
    return if $class eq 'DBIx::QuickORM::Row';

    my %meths = $self->generate_methods;

    @list = keys %meths unless @list;

    for my $meth (keys %meths) {
        croak "'$meth' is not defined for this meta table" unless $meths{$meth};

        no strict 'refs';
        next if *{"$class\::$meth"}{CODE};
        *{"$class\::$meth"} = $meths{$meth};
    }

    return;
}

sub generate_methods {
    my $self = shift;
    return (
        $self->generate_all_relation_methods,
        $self->generate_all_column_methods,
    );
}

sub generate_all_relation_methods {
    my $self = shift;
    return map { $self->generate_relation_method($_) } $self->{+RELATIONS}->for_table($self->name);
}

sub generate_relation_method {
    my $self = shift;
    my ($name) = @_;
    state %CACHE;
    return $CACHE{$name} //= sub { $_[0]->relation($name) };
}

sub generate_all_column_methods {
    my $self = shift;
    return map { $self->generate_column_methods($_) } keys %{$self->{+COLUMNS}};
}

sub generate_column_methods {
    my $self = shift;
    my ($name) = @_;
    state %CACHE;
    return %{$CACHE{$name} //= $self->_generate_column_methods($name) };
}

sub generate_column_method {
    my $self = shift;
    my ($col, $type) = @_;
    my $name = $type ? "${col}_${type}" : $col;

    my %meths = $self->generate_column_methods($col);
    return $meths{$name} // croak "Could not generate '$name' method";
}

sub _generate_column_methods {
    my $self = shift;
    my ($name) = @_;

    return {
        $name => sub {
            my $self = shift;
            return $self->cols_set($name => @_) if @_;
            return $self->col_inflated($name);
        },
        "${name}_inflated" => sub { $_[0]->col_inflated($name) },
        "${name}_stored"   => sub { $_[0]->col_stored($name) },
        "${name}_raw"      => sub { $_[0]->col_raw($name) },
    };
}

1;
