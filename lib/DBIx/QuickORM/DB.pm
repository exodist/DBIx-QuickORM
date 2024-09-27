package DBIx::QuickORM::DB;
use strict;
use warnings;

use Carp qw/confess croak/;
use List::Util qw/first/;
use Scalar::Util qw/blessed/;
use DBIx::QuickORM::Util qw/alias/;

require DBIx::QuickORM::Connection;
require DBIx::QuickORM::Util::SchemaBuilder;

use DBIx::QuickORM::Util::HashBase qw{
    +connect
    <attributes
    <db_name
    +dsn
    <host
    <name
    <pid
    <port
    <socket
    <user
    password
};

use DBIx::QuickORM::Util::Has qw/Plugins Created SQLSpec/;

sub start_txn          { croak "$_[0]->start_txn() is not implemented" }
sub commit_txn         { croak "$_[0]->commit_txn() is not implemented" }
sub rollback_txn       { croak "$_[0]->rollback_txn() is not implemented" }
sub create_savepoint   { croak "$_[0]->create_savepoint() is not implemented" }
sub commit_savepoint   { croak "$_[0]->commit_savepoint() is not implemented" }
sub rollback_savepoint { croak "$_[0]->rollback_savepoint() is not implemented" }

sub dbi_driver { croak "$_[0]->dbi_driver() is not implemented" }

sub tables      { croak "$_[0]->tables() is not implemented" }
sub table       { croak "$_[0]->table() is not implemented" }
sub column_type { croak "$_[0]->column_type() is not implemented" }
sub columns     { croak "$_[0]->columns() is not implemented" }
sub db_keys     { croak "$_[0]->db_keys() is not implemented" }
sub indexes     { croak "$_[0]->indexes() is not implemented" }

sub load_schema_sql { croak "$_[0]->load_schema_sql() is not implemented" }

sub create_temp_view  { croak "$_[0]->create_temp_view() is not implemented" }
sub create_temp_table { croak "$_[0]->create_temp_table() is not implemented" }
sub drop_temp_view    { croak "$_[0]->drop_temp_table() is not implemented" }
sub drop_temp_table   { croak "$_[0]->drop_temp_table() is not implemented" }

sub quote_index_columns               { 1 }
sub generate_schema_sql_header        { () }
sub generate_schema_sql_footer        { () }
sub generate_schema_sql_column_serial { croak "$_[0]->generate_schema_sql_column_serial() is not implemented" }

sub sql_spec_keys {}

sub temp_table_supported { 0 }
sub temp_view_supported  { 0 }

sub insert_returning_supported { 0 }
sub update_returning_supported { 0 }

sub init {
    my $self = shift;

    croak "${ \__PACKAGE__ } cannot be used directly, use a subclass" if blessed($self) eq __PACKAGE__;

    $self->{+ATTRIBUTES} //= {};

    $self->{+ATTRIBUTES}->{RaiseError}          //= 1;
    $self->{+ATTRIBUTES}->{PrintError}          //= 1;
    $self->{+ATTRIBUTES}->{AutoCommit}          //= 1;
    $self->{+ATTRIBUTES}->{AutoInactiveDestroy} //= 1;

    croak "Cannot provide both a socket and a host" if $self->{+SOCKET} && $self->{+HOST};
}

sub dsn {
    my $self = shift;
    return $self->{+DSN} if $self->{+DSN};

    my $driver = $self->dbi_driver;
    my $db_name = $self->db_name;

    my $dsn = "dbi:${driver}:database=${db_name};";

    if (my $socket = $self->socket) {
        $dsn .= "host=$socket;";
    }
    elsif (my $host = $self->host) {
        $dsn .= "host=$host;";
        if (my $port = $self->port) {
            $dsn .= "port=$port;";
        }
    }
    else {
        croak "Cannot construct dsn without a host or socket";
    }

    return $self->{+DSN} = $dsn;
}

sub connect {
    my $self = shift;

    my $dbh;
    if ($self->{+CONNECT}) {
        $dbh = $self->{+CONNECT}->();
    }
    else {
        require DBI;
        $dbh = DBI->connect($self->dsn, $self->username, $self->password, $self->attributes // {AutoInactiveDestroy => 1, AutoCommit => 1});
    }

    return DBIx::QuickORM::Connection->new(
        dbh => $dbh,
        db  => $self,
    );
}

sub generate_and_load_schema {
    my $class_or_self = shift;
    my ($dbh, %params) = @_;

    my $sql = $class_or_self->generate_schema_sql(%params);
    return $class_or_self->load_schema_sql($sql);
}

sub generate_schema_sql {
    my $class_or_self = shift;
    my %params        = @_;

    my $schema  = $params{schema} or croak "'schema' must be provided";
    my $plugins = $params{plugins};
    my $specs   = $params{sql_spec};

    if (blessed($class_or_self)) {
        $plugins //= $class_or_self->plugins;
        $specs   //= $class_or_self->{+SQL_SPEC};
    }

    my @out;

    push @out => $class_or_self->_generate_schema_sql_header(sql_spec => $specs, plugins => $plugins, schema => $schema);

    my %deps;
    for my $r ($schema->relations) {
        my ($referer, $referee);
        for my $m ($r->members) {
            if ($m->{reference}) {
                croak "Cannot handle circular reference" if $referer;
                $referer = $m->{table};
            }
            else {
                $referee = $m->{table};
            }
        }

        if ($referer && $referee && $referer ne $referee) {
            $deps{$referer}{$referee} //= 1;
        }
    }

    # Sort for consistency of output, but note that dep tree traversal will re-order by deps where necessary
    my @todo = sort { $b->name cmp $a->name } $schema->tables;

    my %table_done;
    while (my $t = shift @todo) {
        my $tname = $t->name;
        next if $table_done{$tname};

        if (my $deps = $deps{$tname}) {
            if (first { !$table_done{$_} } keys %$deps) {
                push @todo => $t; # Do it later, a dep table has not been handled yet
                next;
            }
        }

        push @out => $class_or_self->generate_schema_sql_table(table => $t, schema => $schema, plugins => $plugins);
        push @out => $class_or_self->generate_schema_sql_indexes_for_table(table => $t, schema => $schema, plugins => $plugins);
        $table_done{$tname} = 1;
    }

    push @out => $class_or_self->_generate_schema_sql_footer(sql_spec => $specs, schema => $schema, plugins => $plugins);

    return join "\n" => @out;
}

sub _generate_schema_sql_header {
    my $class_or_self = shift;
    my %params        = @_;

    my $specs   = $params{sql_spec} or return;
    my $plugins = $params{plugins};
    my $schema  = $params{schema};

    my @out;

    if (my $val = $specs->get_spec('pre_header_sql', $class_or_self->sql_spec_keys)) { push @out => $val }
    push @out => $class_or_self->generate_schema_sql_header(%params);
    if (my $val = $specs->get_spec('post_header_sql', $class_or_self->sql_spec_keys)) { push @out => $val }

    return @out;
}

sub _generate_schema_sql_footer {
    my $class_or_self = shift;
    my %params        = @_;

    my $specs   = $params{sql_spec} or return;
    my $plugins = $params{plugins};
    my $schema  = $params{schema};

    my @out;

    if (my $val = $specs->get_spec('pre_footer_sql', $class_or_self->sql_spec_keys)) { push @out => $val }
    push @out => $class_or_self->generate_schema_sql_footer(%params);
    if (my $val = $specs->get_spec('post_footer_sql', $class_or_self->sql_spec_keys)) { push @out => $val }

    return @out;
}

sub generate_schema_sql_table {
    my $class_or_self = shift;
    my %params        = @_;

    my $table   = $params{table} or croak "A table is required";
    my $plugins = $params{plugins};
    my $schema  = $params{schema};

    my $specs = $table->sql_spec;

    if (my $sql = $specs->get_spec(table_sql =>  $class_or_self->sql_spec_keys)) {
        return $sql;
    };

    my $table_name = $table->name;

    my @out;

    my @columns = sort {$a->{primary_key} ? -1 : $b->{primary_key} ? 1 : $a->{order} <=> $b->{order}} values %{$table->columns};

    for my $col (@columns) {
        push @out => $class_or_self->generate_schema_sql_column_sql(column => $col, %params);
    }

    my %uniq_seen;
    if (my $pk = $table->primary_key) {
        $uniq_seen{join(', ' => @$pk)}++;
        push @out => $class_or_self->generate_schema_sql_primary_key(key => $pk, columns => \@columns);
    }

    for my $uniq (values %{$table->unique // {}}) {
        next if $uniq_seen{join(', ' => @$uniq)}++;
        push @out => $class_or_self->generate_schema_sql_unique(@$uniq);
    }

    my @rels;
    for my $rel ($schema->relation_set->table_relations($table_name)) {
        push @rels => $class_or_self->generate_schema_sql_foreign_key(relation => $rel, %params);
    }

    my %seen;
    push @out => grep { !$seen{$_}++ } @rels;

    return (
        "CREATE TABLE $table_name(",
        (join ",\n" => map { "    $_" } @out),
        ");",
    );
}

sub generate_schema_sql_column_sql {
    my $class_or_self = shift;
    my %params        = @_;

    my $col = $params{column} or croak "column is required";

    my $specs = $col->sql_spec;
    $params{sql_spec} = $specs;

    if (my $sql = $specs->get_spec(column_sql =>  $class_or_self->sql_spec_keys)) {
        return $sql;
    };

    my $name = $col->name or croak "Columns must have names";

    my $type    = $class_or_self->generate_schema_sql_column_type(%params);
    my $null    = $class_or_self->generate_schema_sql_column_null(%params);
    my $default = $class_or_self->generate_schema_sql_column_default(%params);
    my $serial  = $class_or_self->generate_schema_sql_column_serial(%params);

    return join ' ' => $name, $type, grep { $_ } $null, $serial, $default;
}

sub generate_schema_sql_foreign_key {
    my $class_or_self = shift;
    my %params = @_;

    my $rel   = $params{relation};
    my $table = $params{table};

    my @members = $rel->members;

    # Self-reference conditions
    return if @members == 1;
    return if $members[0]->{table} eq $members[1]->{table};

    my $tb_name = $table->name;
    my ($me, $f) = sort { $a->{table} eq $tb_name ? -1 : $b->{table} eq $tb_name ? 1 : 0} @members;

    return unless $me->{reference};

    my $out = 'FOREIGN KEY(' . join(', ' => @{$me->{columns}} ) . ') REFERENCES ' . $f->{table} . '(' . join(', ' => @{$f->{columns}}) . ')';

    $out .= " ON DELETE $me->{on_delete}" if $me->{on_delete};

    return $out;
}

sub generate_schema_sql_primary_key {
    my $class_or_self = shift;
    my %params        = @_;
    my $key           = $params{key};
    my $cols          = $params{columns};

    return unless $key && @$key;
    return "PRIMARY KEY(" . join(', ' => @$key) . ")";
}

sub generate_schema_sql_unique {
    my $class_or_self = shift;
    my @cols = @_;
    return unless @cols;
    return "UNIQUE(" . join(', ' => @cols) . ")";
}

sub generate_schema_sql_column_null {
    my $class_or_self = shift;
    my %params = @_;

    my $col = $params{column};

    my $nullable = $col->nullable // 1;

    return "" if $nullable;
    return "NOT NULL";
}

sub generate_schema_sql_indexes_for_table {
    my $class_or_self = shift;
    my %params        = @_;

    my $table   = $params{table} or croak "A table is required";
    my $plugins = $params{plugins};
    my $schema  = $params{schema};

    my @out;

    my $table_name = $table->name;
    for my $idx (values %{$table->indexes}) {
        my @names = @{$idx->{columns}};
        @names = map { "`$_`" } @names if $class_or_self->quote_index_columns;
        push @out => "CREATE INDEX $idx->{name} ON $table_name(" . join(', ' => @names) . ");";
    }

    return @out;
}

sub generate_schema_sql_column_type {
    my $class_or_self = shift;
    my %params        = @_;

    my $specs = $params{sql_spec};

    my $t = $params{table}->name;
    my $c = $params{column}->name;

    my $type = $specs->get_spec(type => $class_or_self->sql_spec_keys) or croak "No 'type' key found in SQL specs for column $c in table $t";

    return $type;
}

sub generate_schema_sql_column_default {
    my $class_or_self = shift;
    my %params        = @_;

    my $specs = $params{sql_spec};

    return $specs->get_spec(default => $class_or_self->sql_spec_keys);
}

1;
