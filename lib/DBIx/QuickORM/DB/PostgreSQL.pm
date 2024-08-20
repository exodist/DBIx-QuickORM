package DBIx::QuickORM::DB::PostgreSQL;
use strict;
use warnings;

use DBD::Pg;

use Carp qw/croak/;

use parent 'DBIx::QuickORM::DB';
use DBIx::QuickORM::Util::HashBase;

sub dbi_driver { 'DBD::Pg' }

sub create_savepoint   { $_[0]->dbh->pg_savepoint($_[1]) }
sub commit_savepoint   { $_[0]->dbh->pg_release($_[1]) }
sub rollback_savepoint { $_[0]->dbh->pg_rollback_to($_[1]) }

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
    my %params = @_;

    my $dbh = $self->dbh;

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
         WHERE table_catalog = ?
           AND table_name    = ?
           AND table_schema  = ?
    EOT

    $sth->execute($self->{+DB_NAME}, $table, 'public');

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

        if (my ($type, $columns, $ftable, $fcolumns) = $spec =~ m/(FOREIGN KEY) \(([^\)]+)\) (?:REFERENCES)\s+(\S+)\(([^\)]+)\)$/gi) {
            my @columns  = split /,\s+/, $columns;
            my @fcolumns = split /,\s+/, $fcolumns;

            push @{$out{fk} //= []} => {columns => \@columns, foreign_table => $ftable, foreign_columns => \@fcolumns};
        }
    }

    return \%out;
}

1;
