package DBIx::QuickORM::ORM;
use strict;
use warnings;

use Carp qw/confess croak/;

require DBIx::QuickORM::Schema;
require DBIx::QuickORM::Source;

use DBIx::QuickORM::Util::HashBase qw{
    <name
    <db
    +connection
    <schema
    +con_schema  <con_sources
    +temp_schema <temp_sources
    <autofill
};

use DBIx::QuickORM::Util::Has qw/Plugins Created/;

sub temp_table_supported { $_[0]->connection->temp_table_supported }
sub temp_view_supported  { $_[0]->connection->temp_view_supported }

sub init {
    my $self = shift;

    my $name = $self->{+NAME} //= $self->created;
    my $db   = $self->{+DB}   or croak "'db' is a required attribute";

    $self->{+AUTOFILL}     //= 1;
    $self->{+TEMP_SOURCES} //= {};
    $self->{+CON_SOURCES}  //= {};

    croak "You must either provide the 'schema' attribute or enable 'autofill'"
        unless $self->{+SCHEMA} || $self->{+AUTOFILL};
}

sub clone {
    my $self = shift;
    my (%params) = @_;

    my $type = blessed($self);

    return $type->new(
        name     => $self->{+NAME},
        db       => $self->{+DB},
        schema   => $self->{+SCHEMA},
        autofill => $self->{+AUTOFILL},

        %params,
    );
}

sub con_schema {
    my $self = shift;

    return $self->{+CON_SCHEMA} if $self->{+CON_SCHEMA};

    $self->{+CON_SCHEMA} = DBIx::QuickORM::Schema->new(name => $self->{+NAME});

    if (my $schema = $self->{+SCHEMA}) {
        $self->{+CON_SCHEMA} = $self->{+CON_SCHEMA}->merge($schema);
    }

    $self->{+CON_SCHEMA} = $self->{+CON_SCHEMA}->merge($self->connection->generate_schema)
        if $self->{+AUTOFILL};

    return $self->{+CON_SCHEMA};
}

sub temp_schema {
    my $self = shift;
    return $self->{+TEMP_SCHEMA} //= DBIx::QuickORM::Schema->new(name => "TEMP $self->{+NAME}");
}

sub reconnect {
    my $self = shift;
    delete $self->{+CONNECTION};

    $self->{+CON_SOURCES}  = {};
    $self->{+TEMP_SOURCES} = {};

    delete $self->{+TEMP_SCHEMA};
    delete $self->{+CON_SCHEMA};

    return $self->connection;
}

sub connection {
    my $self = shift;
    return $self->{+CONNECTION} //= $self->{+DB}->connect;
}

sub _table {
    my $self = shift;
    my ($name) = @_;

    my ($schema, $table);

    for my $meth (qw/ temp_schema con_schema /) {
        $schema = $self->$meth()              or next;
        $table  = $schema->maybe_table($name) or next;
        return ($schema, $table);
    }

    return;
}

sub table {
    my $self = shift;
    my ($name) = @_;

    my ($schema, $table) = $self->_table($name);

    return $table;
}

sub source {
    my $self = shift;
    my ($name) = @_;

    return $self->{+TEMP_SOURCES}->{$name} if $self->{+TEMP_SOURCES}->{$name};
    return $self->{+CON_SOURCES}->{$name}  if $self->{+CON_SOURCES}->{$name};

    my ($schema, $table) = $self->_table($name);

    croak "'$name' is not defined in the schema as a table/view, or temporary table/view"
        unless $schema && $table;

    return $self->{+CON_SOURCES}->{$name} = DBIx::QuickORM::Source->new(
        connection => $self->connection,
        schema     => $schema,
        table      => $table,
        orm        => $self,
    );
}

sub load_schema_sql { shift->connection->load_schema_sql(@_) }

sub create_temp_table { shift->_create_temp(table => @_) }
sub create_temp_view  { shift->_create_temp(view  => @_) }

sub _create_temp {
    my $self = shift;
    my ($type, $name, %params) = @_;

    my $supported = "temp_${type}_supported";
    my $create    = "create_temp_${type}";

    my $from   = $params{from}   or croak "Must provide a 'from' source to build the $type";
    my $select = $params{select} or croak "Must provide a 'select' to build the $type";

    my $con    = $self->connection;
    my $schema = $self->temp_schema;

    croak "The current database '" . ref($self->{+DB}) . "' does not support temporary ${type}s"
        unless $con->$supported;

    croak "There is already a temporary table or view named '$name'"
        if $schema->maybe_table($name) || $self->{+TEMP_SOURCES}->{$name};

    $from = $self->source($from) unless blessed($from) && $from->isa('DBIx::QuickORM::Source');

    my ($sql, $bind) = $from->sql_for_select(@$select);

    $con->$create($name, $sql, $bind);

    my $table;
    if ($table = $params{table}) {
        if (ref($table) eq 'CODE') {
            require DBIx::QuickORM;
            $table = DBIx::QuickORM::rogue_table($name => $table);
        }

        $table = $table->merge($con->generate_table_schema($name)) if $params{autofill};
    }
    elsif ($params{autofill}) {
        $table = $con->generate_table_schema($name);
    }
    else {
        croak "Must specify either a 'table' specification, or set the `autofill => 1` parameter";
    }

    # Might get cloned and modified
    $table = $schema->add_table($name => $table);

    return $self->{+TEMP_SOURCES}->{$name} = DBIx::QuickORM::Source->new(
        connection => $con,
        schema     => $schema,
        table      => $table,
    );
}

sub drop_temp_source {
    my $self = shift;
    my ($name) = @_;

    my $source = $self->source($name) or croak "No such source '$name'";
    my $table  = $source->table;
    croak "'$name' is not temporary" unless $table->is_temp;
    $source->drop;

    delete $self->{TEMP_SOURCES}->{$name};

    return;
}

sub drop_temp_table {
    my $self = shift;
    my ($name) = @_;

    my $source = $self->source($name) or croak "No such table '$name'";
    croak "'$name' is a view, not a table" if $source->table->is_view;

    return $self->drop_temp_source($name);
}

sub drop_temp_view {
    my $self = shift;
    my ($name) = @_;

    my $source = $self->source($name) or croak "No such view '$name'";
    croak "'$name' is a view, not a table" if $source->table->is_view;

    return $self->drop_temp_source($name);
}

sub with_temp_view  { shift->_with_temp(view  => @_) }
sub with_temp_table { shift->_with_temp(table => @_) }

sub _with_temp {
    my $self = shift;
    my ($type, $name, $select, $code) = @_;

    my $create = "create_temp_$type";
    my $drop   = "drop_temp_$type";

    my $source = $self->$create($name, @$select);

    my $out;
    my $ok  = eval { $out = $code->($source); 1 };
    my $err = $@;

    $self->$drop($name);

    return $out if $ok;
    die $err;
}

sub generate_and_load_schema {
    my $self = shift;
    my $sql = $self->generate_schema_sql();
    return $self->load_schema_sql($sql);
}

sub generate_schema_sql {
    my $self = shift;
    $self->{+DB}->generate_schema_sql(schema => $self->{+SCHEMA});
}

1;
