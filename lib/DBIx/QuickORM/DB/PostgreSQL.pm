package DBIx::QuickORM::DB::PostgreSQL;
use strict;
use warnings;

use DBD::Pg;

use Carp qw/croak/;

use parent 'DBIx::QuickORM::DB';
use DBIx::QuickORM::Util::HashBase;

sub dbi_driver { 'DBD::Pg' }

sub sql_spec_keys { 'postgresql' }

sub temp_table_supported { 1 }
sub temp_view_supported  { 1 }
sub quote_index_columns  { 0 }

sub start_txn    { $_[1]->begin_work }
sub commit_txn   { $_[1]->commit }
sub rollback_txn { $_[1]->rollback }

sub create_savepoint   { $_[1]->pg_savepoint($_[2]) }
sub commit_savepoint   { $_[1]->pg_release($_[2]) }
sub rollback_savepoint { $_[1]->pg_rollback_to($_[2]) }

sub update_returning_supported { 1 }
sub insert_returning_supported { 1 }

sub load_schema_sql {
    my $self = shift;
    my ($dbh, $sql) = @_;
    $dbh->do($sql) or die "Failed to load schema";
}

# As far as I can tell postgres does not let us know if it is a temp view or a
# temp table, and appears to treat them identically?

my %TABLE_TYPES = (
    'BASE TABLE'      => 'table',
    'VIEW'            => 'view',
    'LOCAL TEMPORARY' => 'table',
);

my %TEMP_TYPES = (
    'BASE TABLE'      => 0,
    'VIEW'            => 0,
    'LOCAL TEMPORARY' => 1,
);

sub tables {
    my $self = shift;
    my ($dbh, %params) = @_;

    my $sth = $dbh->prepare(<<"    EOT");
        SELECT table_name, table_type
          FROM information_schema.tables
         WHERE table_catalog = ?
           AND table_schema  NOT IN ('pg_catalog', 'information_schema')
    EOT

    $sth->execute($self->{+DB_NAME});

    my @out;
    while (my ($table, $type) = $sth->fetchrow_array) {
        if ($params{details}) {
            push @out => {name => $table, type => $TABLE_TYPES{$type}, temp => $TEMP_TYPES{$type} // 0};
        }
        else {
            push @out => $table;
        }
    }

    return @out;
}

sub table {
    my $self = shift;
    my ($dbh, $name, %params) = @_;

    my $sth = $dbh->prepare(<<"    EOT");
        SELECT table_name, table_type
          FROM information_schema.tables
         WHERE table_catalog = ?
           AND table_name    = ?
           AND table_schema  NOT IN ('pg_catalog', 'information_schema')
    EOT

    $sth->execute($self->{+DB_NAME}, $name);

    my ($table, $type) = $sth->fetchrow_array or croak "'$name' does not appear to be a table or view in this database";

    return {name => $table, type => $TABLE_TYPES{$type}, temp => $TEMP_TYPES{$type} // 0};
}

sub indexes {
    my $self = shift;
    my ($dbh, $table) = @_;

    my $sth = $dbh->prepare(<<"    EOT");
        SELECT indexname AS name,
               indexdef  AS def
          FROM pg_indexes
         WHERE tablename = ?
      ORDER BY name
    EOT

    $sth->execute($table);

    my @out;

    while (my ($name, $def) = $sth->fetchrow_array) {
        $def =~ m/CREATE(?: (UNIQUE))? INDEX \Q$name\E ON \S+ USING ([^\(]+) \((.+)\)$/ or warn "Could not parse index: $def" and next;
        my ($unique, $type, $col_list) = ($1, $2, $3);
        my @cols = split /,\s*/, $col_list;
        push @out => {name => $name, type => $type, columns => \@cols, sql_spec => {postgresql => {def => $def}}, unique => $unique ? 1 : 0};
    }

    return @out;
}

sub column_type {
    my $self = shift;
    my ($dbh, $cache, $table, $column) = @_;

    croak "A table name is required" unless $table;
    croak "A column name is required" unless $column;

    return $cache->{$table}->{$column} if $cache->{$table}->{$column};

    my $sth = $dbh->prepare(<<"    EOT");
        SELECT column_name          AS name,
               udt_name             AS sql_type,
               data_type            AS data_type,
               datetime_precision   AS is_datetime
          FROM information_schema.columns
         WHERE table_catalog = ?
           AND table_name    = ?
           AND column_name   = ?
           AND table_schema  NOT IN ('pg_catalog', 'information_schema')
    EOT

    $sth->execute($self->{+DB_NAME}, $table, $column);

    return $cache->{$table}->{$column} = $sth->fetchrow_hashref;
}

sub columns {
    my $self = shift;
    my ($dbh, $cache, $table) = @_;

    croak "A table name is required" unless $table;

    my $sth = $dbh->prepare(<<"    EOT");
        SELECT column_name          AS name,
               udt_name             AS sql_type,
               data_type            AS data_type,
               datetime_precision   AS is_datetime
          FROM information_schema.columns
         WHERE table_catalog = ?
           AND table_name    = ?
           AND table_schema  NOT IN ('pg_catalog', 'information_schema')
    EOT

    $sth->execute($self->{+DB_NAME}, $table);

    my @out;
    while (my $col = $sth->fetchrow_hashref) {
        $cache->{$table}->{$col->{name}} //= {type => $col->{type}, is_datetime => $col->{is_datetime}};
        push @out => $col;
    }

    return @out;
}

sub db_keys {
    my $self = shift;
    my ($dbh, $table) = @_;

    croak "A table name is required" unless $table;

    my $sth = $dbh->prepare(<<"    EOT");
        SELECT pg_get_constraintdef(oid)
          FROM pg_constraint
         WHERE connamespace = 'public'::regnamespace AND conrelid::regclass::text = ?
    EOT

    $sth->execute($table);

    my %out;
    while (my ($spec) = $sth->fetchrow_array) {
        if (my ($type, $columns) = $spec =~ m/^(UNIQUE|PRIMARY KEY) \(([^\)]+)\)$/gi) {
            my @columns = split /,\s+/, $columns;

            push @{$out{unique} //= []} => \@columns;
            $out{pk} = \@columns if $type eq 'PRIMARY KEY';
        }

        if (my ($type, $columns, $ftable, $fcolumns) = $spec =~ m/(FOREIGN KEY) \(([^\)]+)\) (?:REFERENCES)\s+(\S+)\(([^\)]+)\)/gi) {
            my @columns  = split /,\s+/, $columns;
            my @fcolumns = split /,\s+/, $fcolumns;

            push @{$out{fk} //= []} => {columns => \@columns, foreign_table => $ftable, foreign_columns => \@fcolumns};
        }
    }

    return \%out;
}

sub generate_schema_sql_header {
    my $class_or_self = shift;
    my %params        = @_;

    my $specs   = $params{sql_spec} or return;
    my $plugins = $params{plugins};
    my $schema  = $params{schema};

    my @out;

    my $exts = $specs->get_spec(extensions => $class_or_self->sql_spec_keys) // [];
    for my $ext (@$exts) {
        push @out => qq{CREATE EXTENSION "$ext";};
    }

    my $types = $specs->get_spec(types => $class_or_self->sql_spec_keys) // [];
    for my $set (@$types) {
        my ($name, $type, @vals) = @$set;
        croak "Only enum types are supported currently (got '$type')" unless lc($type) eq 'enum';

        push @out => "CREATE TYPE $name AS ENUM(" . join(', ' => map { "'$_'" } @vals) . ");";
    }

    return @out;
}

# Postgresql uses serial types instead of auto-increment
sub generate_schema_sql_column_serial { }

sub generate_schema_sql_column_type {
    my $class_or_self = shift;
    my %params        = @_;

    my $type = $class_or_self->SUPER::generate_schema_sql_column_type(%params);

    my $col = $params{column};

    return $type unless $col->serial;

    $type =~ s/int(eger)?/serial/;
    $type =~ s/INT(EGER)?/SERIAL/;
    $type =~ s/Int(eger)?/Serial/;
    $type =~ s/int(eger)?/serial/i; # Catchall

    return $type;
}

1;
