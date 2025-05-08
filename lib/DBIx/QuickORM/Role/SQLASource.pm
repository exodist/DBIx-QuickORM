package DBIx::QuickORM::Role::SQLASource;
use strict;
use warnings;

use Carp qw/croak confess/;

use Role::Tiny;

requires qw{
    sqla_db_name
    sqla_orm_name

    row_class
    primary_key

    field_type
    field_affinity

    has_field

    fields_to_fetch
    fields_to_omit
    fields_list_all
};

sub prefetch { }

sub cacheable { $_[0]->{sqlas_cacheable} //= $_[0]->_cacheable }

sub _cacheable {
    my $pk = $_[0]->primary_key or return 0;
    return 1 if @$pk;
    return 0;
}

1;
