package DBIx::QuickORM::Schema::Table;
use strict;
use warnings;

our $VERSION = '0.000005';

use Carp qw/croak/;
use Scalar::Util qw/blessed/;
use Role::Tiny::With qw/with/;
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

    +sqla_fields
    +sqla_all_fields
    +rename_db_to_orm_map
    +rename_orm_to_db_map
};

with 'DBIx::QuickORM::Role::SQLASource';

sub is_view     { 0 }
sub sqla_source { $_[0]->{+DB_NAME} }

sub name    { $_[0]->{+NAME}    //= $_[0]->{+DB_NAME} }
sub db_name { $_[0]->{+DB_NAME} //= $_[0]->{+NAME} }

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

sub sqla_fields {
    my $self = shift;

    return $self->{+SQLA_FIELDS} if $self->{+SQLA_FIELDS};

    my @out = map { $_->db_name } grep { !$_->omit } values %{$self->{+COLUMNS}};

    return $self->{+SQLA_FIELDS} = \@out;
}

sub sqla_all_fields {
    my $self = shift;

    return $self->{+SQLA_ALL_FIELDS} if $self->{+SQLA_ALL_FIELDS};

    my @out = map { $_->db_name } values %{$self->{+COLUMNS}};

    return $self->{+SQLA_ALL_FIELDS} = \@out;
}

sub rename_db_to_orm_map {
    my $self = shift;

    return $self->{+RENAME_DB_TO_ORM_MAP} if $self->{+RENAME_DB_TO_ORM_MAP};

    my %out = map { ($_->db_name, $_->name) } grep { $_->db_name ne $_->name } values %{$self->{+COLUMNS}};

    return $self->{+RENAME_DB_TO_ORM_MAP} = \%out;
}

sub rename_orm_to_db_map {
    my $self = shift;

    return $self->{+RENAME_ORM_TO_DB_MAP} if $self->{+RENAME_ORM_TO_DB_MAP};

    my %out = map { ($_->name, $_->db_name) } grep { $_->db_name ne $_->name } values %{$self->{+COLUMNS}};

    return $self->{+RENAME_ORM_TO_DB_MAP} = \%out;
}

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

1;
