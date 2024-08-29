package DBIx::QuickORM::Util::SchemaBuilder;
use strict;
use warnings;

use DBIx::QuickORM qw{
    column
    columns
    conflate
    default
    index
    member
    omit
    primary_key
    relation
    references
    table
    unique
    schema
    sql_spec
    is_temp
    is_view
    rogue_table
};

my %AUTO_CONFLATE = (
    uuid => 'DBIx::QuickORM::Conflator::UUID',
    json => 'DBIx::QuickORM::Conflator::JSON',
    jsonb => 'DBIx::QuickORM::Conflator::JSON',

    map {$_ => 'DBIx::QuickORM::Conflator::DateTime'} qw/timestamp date time timestamptz datetime year/,
);

sub _conflate {
    my $class = shift;
    my ($type) = @_;

    $type = lc($type);
    $type =~ s/\(.*$//g;

    return $AUTO_CONFLATE{$type} if $AUTO_CONFLATE{$type};
    return 'DBIx::QuickORM::Conflator::DateTime' if $type =~ m/(time|date|stamp|year)/;
}

sub generate_schema {
    my $class = shift;
    my ($con, $plugins) = @_;

    my $schema = schema $con->db->name, sub {
        for my $table ($con->tables(details => 1)) {
            my $name = $table->{name};

            table $name => sub {
                $class->_build_table($con, $table, $plugins);
            };
        }
    };
}

sub generate_table {
    my $class = shift;
    my ($con, $table, $plugins) = @_;

    return rogue_table $table->{name} => sub {
        $class->_build_table($con, $table, $plugins);
    };
}

sub _build_table {
    my $class = shift;
    my ($con, $table, $plugins) = @_;

    my $name = $table->{name};

    is_view() if $table->{type} eq 'view';
    is_temp() if $table->{temp};

    for my $col ($con->columns($name)) {
        column $col->{name} => sub {
            my $dtype = lc($col->{data_type});
            my $stype = lc($col->{sql_type});

            if (my $conflate = $class->_conflate($dtype) // $class->_conflate($stype)) {
                conflate($conflate);

                if ($conflate eq 'DBIx::QuickORM::Conflator::JSON') {
                    omit();
                }
            }
            elsif ($col->{is_datetime}) {
                conflate('DBIx::QuickORM::Conflator::DateTime');
            }
            elsif ($col->{name} =~ m/uuid$/ && ($stype eq 'binary(16)' || $stype eq 'char(32)')) {
                conflate('DBIx::QuickORM::Conflator::UUID');
            }

            primary_key() if $col->{is_pk};

            sql_spec type => $col->{sql_type};
        };
    }

    my $keys = $con->db_keys($name);

    if (my $pk = $keys->{pk}) {
        primary_key(@$pk);
    }

    for my $u (@{$keys->{unique} // []}) {
        unique(@$u);
    }

    for my $fk (@{$keys->{fk} // []}) {
        relation sub {
            columns $fk->{columns};
            references {table => $fk->{foreign_table}, columns => $fk->{foreign_columns}};
        };
    }

    for my $idx ($con->indexes($name)) {
        unique(@{$idx->{columns}}) if $idx->{unique};
        index $idx;
    }
}

1;
