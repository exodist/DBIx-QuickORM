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
    table
    unique
    schema
    sql_spec
    is_temp
    is_view
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

    return $AUTO_CONFLATE{$type} if $AUTO_CONFLATE{$type};
    return 'DBIx::QuickORM::Conflator::DateTime' if $type =~ m/(time|date|stamp|year)/;
}

sub generate {
    my $class = shift;
    my ($db, $plugins) = @_;

    my $schema = schema $db->name, sub {
        for my $table ($db->tables(details => 1)) {
            my $name = $table->{name};
            my $type = $table->{type};

            table $name => sub {
                is_view() if $table->{type} eq 'view';
                is_temp() if $table->{temp};

                for my $col ($db->columns($name)) {
                    column $col->{name} => sub {
                        my $type = lc($col->{type});
                        if(my $conflate = $class->_conflate($type)) {
                            conflate($conflate);

                            if ($conflate eq 'DBIx::QuickORM::Conflator::JSON') {
                                omit();
                            }
                        }
                        elsif ($col->{is_datetime}) {
                            conflate('DBIx::QuickORM::Conflator::DateTime');
                        }
                        elsif ($col->{name} =~ m/uuid$/ && ($type eq 'binary' || $type eq 'char')) {
                            conflate('DBIx::QuickORM::Conflator::UUID');
                        }

                        primary_key() if $col->{is_pk};

                        sql_spec type => $col->{type};
                    };
                }

                my $keys = $db->keys($name);

                if (my $pk = $keys->{pk}) {
                    primary_key(@$pk);
                }

                for my $u (@{$keys->{unique} // []}) {
                    unique(@$u);
                }

                for my $fk (@{$keys->{fk} // []}) {
                    relation "${table} -> $fk->{foreign_table}" => sub {
                        member {table => $name, name => $fk->{foreign_table}, columns => $fk->{columns}};
                        member {table => $fk->{foreign_table}, name => $name, columns => $fk->{foreign_columns}};
                    };
                }
            };
        }
    };
}
