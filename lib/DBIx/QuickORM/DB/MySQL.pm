package DBIx::QuickORM::DB::MySQL;
use strict;
use warnings;

use Carp qw/croak/;
use DBD::mysql;

use parent 'DBIx::QuickORM::DB';
use DBIx::QuickORM::Util::HashBase;

sub dbi_driver { 'DBD::mysql' }

# MySQL/MariaDB do not (currently) support temporary views

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
    my %params = @_;

    my $dbh = $self->dbh;

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

sub columns {
    my $self = shift;
    my ($table) = @_;

    croak "A table name is required" unless $table;

    my $dbh = $self->dbh;

    my $sth = $dbh->prepare(<<"    EOT");
        SELECT column_name          AS name,
               data_type            AS type,
               datetime_precision   AS is_datetime
          FROM information_schema.columns
         WHERE table_name    = ?
           AND table_schema  = ?
    EOT

    $sth->execute($table, $self->{+DB_NAME});

    my @out;
    while (my $col = $sth->fetchrow_hashref) {
        $col->{is_datetime} = $col->{is_datetime} ? 1 : 0;
        push @out => $col;
    }

    return @out;
}

sub keys {
    my $self = shift;
    my ($table) = @_;

    croak "A table name is required" unless $table;

    my $dbh = $self->dbh;

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

1;
