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

    field_db_name
    field_orm_name
    field_type
    field_affinity

    has_field

    db_fields_to_fetch
    db_fields_to_omit
    db_fields_list_all
    orm_fields_to_fetch
    orm_fields_to_omit
    orm_fields_list_all
    fields_map_db_to_orm
    fields_map_orm_to_db
    fields_remap_db_to_orm
    fields_remap_orm_to_db
};

1;

__END__

+ sqla_source               sqla_db_name
+ X                         sqla_orm_name
+ sqla_fields               db_fields_to_fetch
+ sqla_all_fields           db_fields_list_all
+ X                         db_fields_to_omit
+ X                         orm_fields_to_fetch
+ X                         orm_fields_list_all
+ X                         orm_fields_to_omit
+ rename_db_to_orm_map      fields_map_db_to_orm
+ rename_orm_to_db_map      fields_map_orm_to_db
+ column                    X
+ column_db_names           X
+ column_orm_names          X
+ column_can_conflate       X
+ column_affinity           field_affinity
+ column_type               field_type
+ column_db_name            field_db_name
+ column_orm_name           field_orm_name
+ remap_db_to_orm           fields_remap_db_to_orm
+ remap_orm_to_db           fields_remap_orm_to_db
