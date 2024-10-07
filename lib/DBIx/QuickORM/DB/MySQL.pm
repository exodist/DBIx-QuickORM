package DBIx::QuickORM::DB::MySQL;
use strict;
use warnings;

use Carp qw/croak/;
use DBD::mysql;

use parent 'DBIx::QuickORM::DB';
use DBIx::QuickORM::Util::HashBase;

sub dbi_driver { 'DBD::mysql' }

sub sql_spec_keys { 'mysql' }
sub dsn_socket_field { 'mysql_socket' };

# MySQL/MariaDB do not (currently) support temporary views
sub temp_table_supported { 1 }
sub temp_view_supported  { 0 }
sub quote_index_columns  { 1 }

sub start_txn    { $_[1]->begin_work }
sub commit_txn   { $_[1]->commit }
sub rollback_txn { $_[1]->rollback }

sub create_savepoint   { $_[1]->do("SAVEPOINT $_[2]") }
sub commit_savepoint   { $_[1]->do("RELEASE SAVEPOINT $_[2]") }
sub rollback_savepoint { $_[1]->do("ROLLBACK TO SAVEPOINT $_[2]") }

sub load_schema_sql {
    my $self = shift;
    my ($dbh, $sql) = @_;
    $dbh->do($_) or die "Error loading schema" for split /;/, $sql;
}

my %TABLE_TYPES = (
    'BASE TABLE' => 'table',
    'VIEW'       => 'view',
    'TEMPORARY'  => 'table',
);

my %TEMP_TYPES = (
    'BASE TABLE' => 0,
    'VIEW'       => 0,
    'TEMPORARY'  => 1,
);

sub tables {
    my $self = shift;
    my ($dbh, %params) = @_;

    my $sth = $dbh->prepare('SELECT table_name, table_type FROM information_schema.tables WHERE table_schema = ?');
    $sth->execute($self->{+DB_NAME});

    my @out;
    while (my ($table, $type) = $sth->fetchrow_array) {
        if ($params{details}) {
            push @out => {name => $table, type => $TABLE_TYPES{$type}, temp => $TEMP_TYPES{$type}};
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

    my $sth = $dbh->prepare('SELECT table_name, table_type FROM information_schema.tables WHERE table_schema = ? AND table_name = ?');
    $sth->execute($self->{+DB_NAME}, $name);

    my ($table, $type) = $sth->fetchrow_array;

    return {name => $table, type => $TABLE_TYPES{$type}, temp => $TEMP_TYPES{$type}};
}


sub column_type {
    my $self = shift;
    my ($dbh, $cache, $table, $column) = @_;

    croak "A table name is required" unless $table;
    croak "A column name is required" unless $column;

    return $cache->{$table}->{$column} if $cache->{$table}->{$column};

    my $sth = $dbh->prepare(<<"    EOT");
        SELECT column_name        AS name,
               data_type          AS data_type,
               column_type        AS sql_type,
               datetime_precision AS is_datetime
          FROM information_schema.columns
         WHERE table_name   = ?
           AND column_name  = ?
           AND table_schema = ?
    EOT

    $sth->execute($table, $column, $self->{+DB_NAME});

    return $cache->{$table}->{$column} = $sth->fetchrow_hashref;
}

sub columns {
    my $self = shift;
    my ($dbh, $cache, $table) = @_;

    croak "A table name is required" unless $table;

    my $sth = $dbh->prepare(<<"    EOT");
        SELECT column_name         AS name,
               data_type           AS data_type,
               column_type         AS sql_type,
               datetime_precision  AS is_datetime
          FROM information_schema.columns
         WHERE table_name    = ?
           AND table_schema  = ?
    EOT

    $sth->execute($table, $self->{+DB_NAME});

    my @out;
    while (my $col = $sth->fetchrow_hashref) {
        $cache->{$table}->{$col->{name}} = { %$col };
        push @out => $col;
    }

    return @out;
}

sub indexes {
    my $self = shift;
    my ($dbh, $table) = @_;

    my $sth = $dbh->prepare(<<"    EOT");
        SELECT index_name,
               column_name,
               non_unique,
               index_type
          FROM INFORMATION_SCHEMA.STATISTICS
         WHERE table_name = ?
           AND table_schema = ?
      ORDER BY index_name, seq_in_index
    EOT

    $sth->execute($table, $self->{+DB_NAME});

    my %out;

    while (my ($name, $col, $nu, $type) = $sth->fetchrow_array) {
        my $idx = $out{$name} //= {name => $name, unique => $nu ? 0 : 1, type => $type, columns => []};
        push @{$idx->{columns}} => $col;
    }

    return values %out;
}

sub db_keys {
    my $self = shift;
    my ($dbh, $table) = @_;

    croak "A table name is required" unless $table;

    my $sth = $dbh->prepare(<<"    EOT");
        SELECT tco.constraint_name          AS con,
               tco.constraint_type          AS type,
               kcu.column_name              AS col,
               kcu.referenced_table_name    AS ftab,
               kcu.referenced_column_name   AS fcol
          FROM information_schema.table_constraints tco
          JOIN information_schema.key_column_usage  kcu
            ON tco.constraint_schema = kcu.constraint_schema
           AND tco.constraint_name   = kcu.constraint_name
           AND tco.table_name        = kcu.table_name
         WHERE tco.table_schema NOT IN ('sys','information_schema', 'mysql', 'performance_schema')
           AND tco.table_name        = ?
           AND tco.table_schema      = ?
      ORDER BY tco.table_schema, tco.table_name, tco.constraint_name, kcu.ordinal_position
    EOT

    $sth->execute($table, $self->{+DB_NAME});

    my %keys;
    while (my $row = $sth->fetchrow_hashref) {
        my $item = $keys{$row->{con}} //= {type => lc($row->{type})};

        push @{$item->{columns} //= []} => $row->{col};

        if ($row->{type} eq 'FOREIGN KEY') {
            $item->{foreign_table} //= $row->{ftab};
            push @{$item->{foreign_columns} //= []} => $row->{fcol};
        }
    }

    my %out;
    for my $key (values %keys) {
        my $type = delete $key->{type};
        if ($type eq 'foreign key') {
            push @{$out{fk} //= []} => $key;
        }
        elsif ($type eq 'unique' || $type eq 'primary key') {
            push @{$out{unique} //= []} => $key->{columns};
            $out{pk} = $key->{columns} if $type eq 'primary key';
        }
    }

    return \%out;
}

sub generate_schema_sql_column_serial {
    my $class_or_self = shift;
    my %params        = @_;

    my $col = $params{column};

    return unless $col->serial;
    return 'AUTO_INCREMENT';
}

1;
