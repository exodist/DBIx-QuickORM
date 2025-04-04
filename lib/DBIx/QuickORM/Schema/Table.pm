package DBIx::QuickORM::Schema::Table;
use strict;
use warnings;

our $VERSION = '0.000005';

use Carp qw/croak/;
use Scalar::Util qw/blessed/;
use DBIx::QuickORM::Util qw/column_key merge_hash_of_objs clone_hash_of_objs/;

use DBIx::QuickORM::Util::HashBase qw{
    +name
    +db_name
    +columns
    +db_columns
    <unique
    <primary_key
    <row_class
    <created
    <compiled
    <is_temp
    +_links
    +links
    <links_by_alias
    <indexes
};

sub is_view  { 0 }
sub name     { $_[0]->{+NAME}    //= $_[0]->{+DB_NAME} }
sub db_name  { $_[0]->{+DB_NAME} //= $_[0]->{+NAME} }

sub init {
    my $self = shift;

    $self->{+DB_NAME} //= $self->{+NAME};
    $self->{+NAME}    //= $self->{+DB_NAME};
    croak "The 'name' attribute is required" unless $self->{+NAME};

    my $debug = $self->{+CREATED} ? " (defined in $self->{+CREATED})" : "";

    my $cols = $self->{+COLUMNS} //= {};
    croak "The 'columns' attribute must be a hashref${debug}" unless ref($cols) eq 'HASH';

    $self->{+DB_COLUMNS} = { map {$_->db_name => $_} values %$cols };

    for my $cname (sort keys %$cols) {
        my $cval = $cols->{$cname} or croak "Column '$cname' is empty${debug}";
        croak "Columns '$cname' is not an instance of 'DBIx::QuickORM::Schema::Table::Column', got: '$cval'$debug" unless blessed($cval) && $cval->isa('DBIx::QuickORM::Schema::Table::Column');
    }

    $self->{+UNIQUE} //= {};
    $self->{+LINKS} //= {};
    $self->{+LINKS_BY_ALIAS} //= {};
    $self->{+INDEXES} //= [];
}

sub merge {
    my $self = shift;
    my ($other, %params) = @_;

    $params{+COLUMNS}        //= merge_hash_of_objs($self->{+COLUMNS}, $other->{+COLUMNS})               if $self->{+COLUMNS}        || $other->{+COLUMNS};
    $params{+UNIQUE}         //= merge_hash_of_objs($self->{+UNIQUE}, $other->{+UNIQUE})                 if $self->{+UNIQUE}         || $other->{+UNIQUE};
    $params{+LINKS}          //= merge_hash_of_objs($self->{+LINKS}, $other->{+LINKS})                   if $self->{+LINKS}          || $other->{+LINKS};
    $params{+LINKS_BY_ALIAS} //= merge_hash_of_objs($self->{+LINKS_BY_ALIAS}, $other->{+LINKS_BY_ALIAS}) if $self->{+LINKS_BY_ALIAS} || $other->{+LINKS_BY_ALIAS};
    $params{+INDEXES}        //= [@{$self->{+INDEXES}}, @{$other->{+INDEXES}}]                           if $self->{+INDEXES}        || $other->{+INDEXES};
    $params{+PRIMARY_KEY}    //= [@{$self->{+PRIMARY_KEY}}]                                              if $self->{+PRIMARY_KEY}    || $other->{+PRIMARY_KEY};

    return blessed($self)->new(%$self, %$other, %params);
}

sub clone {
    my $self = shift;
    my (%params) = @_;

    $params{+COLUMNS}        //= clone_hash_of_objs($self->{+COLUMNS})        if $self->{+COLUMNS};
    $params{+UNIQUE}         //= clone_hash_of_objs($self->{+UNIQUE})         if $self->{+UNIQUE};
    $params{+LINKS}          //= clone_hash_of_objs($self->{+LINKS})          if $self->{+LINKS};
    $params{+LINKS_BY_ALIAS} //= clone_hash_of_objs($self->{+LINKS_BY_ALIAS}) if $self->{+LINKS_BY_ALIAS};
    $params{+INDEXES}        //= [@{$self->{+INDEXES}}]                       if $self->{+INDEXES};
    $params{+PRIMARY_KEY}    //= [@{$self->{+PRIMARY_KEY}}]                   if $self->{+PRIMARY_KEY};

    return blessed($self)->new(%$self, %params);
}

sub _links { delete $_[0]->{+_LINKS} }

sub links_by_table { $_[0]->{+LINKS} }

sub links {
    my $self = shift;
    my ($table) = @_;

    my @tables = $table ? ($table) : keys %{ $self->{+LINKS} };

    return map { values %{ $self->{+LINKS}->{$_} // {}} } @tables;
}

sub link {
    my $self = shift;
    my %params = @_;

    if (my $table = $params{table}) {
        my $links = $self->{+LINKS}->{$table} or return undef;

        if (my $cols = $params{columns} // $params{cols}) {
            my $key = column_key(@$cols);
            return $links->{$key} // undef;
        }

        for my $key (sort keys %$links) {
            return $links->{$key} // undef;
        }

        return undef;
    }
    elsif (my $alias = $params{name}) {
        return $self->{+LINKS_BY_ALIAS}->{$alias} // undef;
    }

    croak "Need a link name or table";
}

sub columns          { values %{$_[0]->{+COLUMNS}} }
sub column_names     { sort keys %{$_[0]->{+COLUMNS}} }
sub column_orm_names { sort keys %{$_[0]->{+COLUMNS}} }
sub column_db_names  { sort keys %{$_[0]->{+DB_COLUMNS}} }

sub column {
    my $self = shift;
    my ($cname) = @_;

    return $self->{+COLUMNS}->{$cname} // undef;
}

sub db_column {
    my $self = shift;
    my ($cname) = @_;

    return $self->{+DB_COLUMNS}->{$cname} // undef;
}

# SQLASource role implementation
{
    use Role::Tiny::With qw/with/;
    with 'DBIx::QuickORM::Role::SQLASource';

    use DBIx::QuickORM::Util::HashBase qw{
        +db_fields_to_fetch
        +db_fields_to_omit
        +db_fields_list_all
        +orm_fields_to_fetch
        +orm_fields_to_omit
        +orm_fields_list_all
        +fields_map_db_to_orm
        +fields_map_orm_to_db
    };

    sub sqla_db_name  { $_[0]->{+DB_NAME} }
    sub sqla_orm_name { $_[0]->{+NAME} }

    # row_class     # In HashBase at top of file
    # primary_key   # In HashBase at top of file

    sub field_db_name {
        my $self = shift;
        my ($field) = @_;
        $self->fields_map_orm_to_db->{$field} // undef;
    }

    sub field_orm_name {
        my $self = shift;
        my ($field) = @_;
        $self->fields_map_db_to_orm->{$field} // undef;
    }

    sub field_type {
        my $self = shift;
        my ($field) = @_;
        my $col = $self->{+COLUMNS}->{$field} or croak "No column '$field' in table '$self->{+NAME}' ($self->{+DB_NAME})";
        my $type = $col->type or return undef;
        return undef if ref($type);
        return $type if $type->DOES('DBIx::QuickORM::Role::Type');
        return undef;
    }

    sub field_affinity {
        my $self = shift;
        my ($field, $dialect) = @_;
        my $col = $self->{+COLUMNS}->{$field} or croak "No column '$field' in table '$self->{+NAME}' ($self->{+DB_NAME})";
        return $col->affinity($dialect);
    }

    sub has_field { $_[0]->{+COLUMNS}->{$_[1]} ? 1 : 0 }

    sub db_fields_to_fetch  { $_[0]->{+DB_FIELDS_TO_FETCH}  //= [ map { $_->db_name } grep { !$_->omit } values %{$_[0]->{+COLUMNS}} ] }
    sub db_fields_to_omit   { $_[0]->{+DB_FIELDS_TO_OMIT}   //= [ map { $_->db_name } grep { $_->omit }  values %{$_[0]->{+COLUMNS}} ] }
    sub db_fields_list_all  { $_[0]->{+DB_FIELDS_LIST_ALL}  //= [ map { $_->db_name }                    values %{$_[0]->{+COLUMNS}} ] }
    sub orm_fields_to_fetch { $_[0]->{+ORM_FIELDS_TO_FETCH} //= [ map { $_->name }    grep { !$_->omit } values %{$_[0]->{+COLUMNS}} ] }
    sub orm_fields_to_omit  { $_[0]->{+ORM_FIELDS_TO_OMIT}  //= [ map { $_->name }    grep { $_->omit }  values %{$_[0]->{+COLUMNS}} ] }
    sub orm_fields_list_all { $_[0]->{+ORM_FIELDS_LIST_ALL} //= [ map { $_->name }                       values %{$_[0]->{+COLUMNS}} ] }

    sub fields_map_db_to_orm { $_[0]->{+FIELDS_MAP_DB_TO_ORM} //= { map {($_->db_name => $_->name)} values %{$_[0]->{+COLUMNS}} } }
    sub fields_map_orm_to_db { $_[0]->{+FIELDS_MAP_ORM_TO_DB} //= { map {($_->name => $_->db_name)} values %{$_[0]->{+COLUMNS}} } }

    sub fields_remap_db_to_orm {
        my $self = shift;
        my ($hash) = @_;

        return $hash if $hash->{__REMAPPED_DB_TO_ORM};

        my $map = $self->fields_map_db_to_orm;

        # In case orm and db keys conflict, we put all keeps into an array, then squash it to a hash later.
        my @keep;
        for my $db (keys %$hash) {
            next if $db =~ m/^__REMAPPED_(DB|ORM)_TO_(DB|ORM)$/;
            my $orm = $map->{$db} or croak "unknown db field '$db'";
            push @keep => ($orm => $hash->{$db}) if exists $hash->{$db};
        }

        return {__REMAPPED_DB_TO_ORM => 1, @keep};
    }

    sub fields_remap_orm_to_db {
        my $self = shift;
        my ($hash) = @_;

        return $hash if $hash->{__REMAPPED_ORM_TO_DB};

        my $map = $self->fields_map_orm_to_db;

        # In case orm and db keys conflict, we put all keeps into an array, then squash it to a hash later.
        my @keep;
        for my $orm (keys %$hash) {
            next if $orm =~ m/^__REMAPPED_(DB|ORM)_TO_(DB|ORM)$/;
            my $db = $map->{$orm} or croak "unknown orm field '$orm'";
            push @keep => ($db => $hash->{$orm}) if exists $hash->{$orm};
        }

        return {__REMAPPED_ORM_TO_DB => 1, @keep};
    }
}

1;
