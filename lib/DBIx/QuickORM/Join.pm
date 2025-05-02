package DBIx::QuickORM::Join;
use strict;
use warnings;

use Carp qw/croak/;

use Role::Tiny::With qw/with/;
with 'DBIx::QuickORM::Role::SQLASource';

use DBIx::QuickORM::Util::HashBase qw{
    <schema
    <primary_source
    <links
    <tables
    <aliases
    <order
    <join_as
};

use constant THIS => 'this';

sub prefetch { my $self = shift; sub { $self->_prefetch(@_) } }

sub init {
    my $self = shift;
    croak "'schema' is required"         unless $self->{+SCHEMA};
    croak "'primary_source' is required" unless $self->{+PRIMARY_SOURCE};

    $self->{+LINKS}   //= {};
    $self->{+TABLES}  //= {THIS() => $self->{+PRIMARY_SOURCE}};
    $self->{+ALIASES} //= {$self->{+PRIMARY_SOURCE}->name => THIS()};

    $self->{+ORDER} //= [];

    $self->{+JOIN_AS} = 'a';
}

sub join {
    my $self = shift;
    my ($link, $as, $from, $type);
    if (@_ == 1) {
        $link = shift;
    }
    else {
        my %params = @_;
        $link = $params{from};
        $as   = $params{as};
        $from = $params{from};
        $type = $params{type};
    }

    until ($as) {
        my $try = $self->{+JOIN_AS}++;
        next if $self->{+LINKS}->{$as};
        next if $self->{+TABLES}->{$as};
        $as = $try;
    }

    croak "A join has already been made using the identifier '$as'" if $self->{+LINKS}->{$as};

    if ($from) {
        croak "'$from' is not defined" unless $self->{+LINKS}->{$from};
    }
    else {
        my $lt = $link->local_table;
        if ($lt eq $self->{+PRIMARY_SOURCE}->name) {
            $from = 'this';
        }
        elsif (my $n = $self->{+ALIASES}->{$lt}) {
            croak "Table '$lt' has been joined multiple times, you must specify which name to use in the join" if @$n > 1;
            $from = $n->[0]->{as}
        }
        else {
            croak "Table '$lt' is not yet in the join";
        }
    }

    push @{$self->{+ORDER}} => $as;
    $self->{+LINKS}->{$as} = {as => $as, link => $link, from => $from, type => $type};
    $self->{+TABLES}->{$as} = $self->schema->table($link->other_table);
    push @{$self->{+ALIASES}->{$link->other_table}} => $as;
}

sub sqla_orm_name   { 'join' }
sub row_class       { $_[0]->{+PRIMARY_SOURCE}->row_class }
sub primary_key     { $_[0]->{+PRIMARY_SOURCE}->primary_key }

sub sqla_db_name {
    my $self = shift;

    my $tables = $self->{+TABLES};
    my $links  = $self->{+LINKS};
    my $aliases = $self->{+ALIASES};

    my $out = $_[0]->{+PRIMARY_SOURCE}->db_name . " AS " . THIS();
    for my $alias (@{$self->{+ORDER}}) {
        my $set = $links->{$alias};
        my $link = $set->{link};
        my $from = $set->{from};
        my $type = $set->{type};

        my $lc = $link->local_columns;
        my $oc = $link->other_columns;

        my @cols;
        for (my $i = 0; $i < @$lc; $i++) {
            push @cols => "$alias.`$lc->[$i]` = $from.`$oc->[$i]`";
        }

        $out .= $type ? ($type =~ m/join/i ? $type : "$type JOIN " ) : " JOIN ";
        $out .= "`" . $tables->{$alias}->sqla_name . "` AS $alias ON (" . CORE::join(' AND ' => @cols) . ")";
    }

    return \$out;
}

sub _field_source {
    my $self = shift;
    my ($proto, %params) = @_;
    my ($field, $from) = reverse split /\./, $proto;

    if ($from) {
        my $t = $self->{+TABLES}->{$from} or croak "'$from' is not an alias in this join";
        return ($from, $t, $field);
    }

    for my $alias (THIS(), @{$self->{+ORDER}}) {
        my $t = $self->{+TABLES}->{$alias};
        next unless $t->has_field($field);
        return ($from, $t, $field);
    }

    return undef if $params{no_fatal};
    croak "This join does not have a '$field' field";
}

sub field_type {
    my $self = shift;
    my ($proto) = @_;
    my ($from, $t, $field) = $self->_field_source($proto);
    return $t->field_type($field);
}

sub field_affinity {
    my $self = shift;
    my ($proto, $dialect) = @_;
    my ($from, $t, $field) = $self->_field_source($proto);
    return $t->field_affinity($field, $dialect);
}

sub has_field {
    my $self = shift;
    my ($proto) = @_;
    my ($from, $t, $field) = $self->_field_source($proto, no_fatal => 1);
    return $t->has_field($field);
}

sub fields_to_fetch {
    my $self = shift;

    my @fields;

    for my $alias (THIS(), @{$self->{+ORDER}}) {
        my $t = $self->{+TABLES}->{$alias};
        push @fields => map { "$alias.`$_`" } @{$t->fields_to_fetch};
    }

    return CORE::join(', ' => @fields);
}

sub fields_to_omit { }

sub fields_list_all { croak "Not Supported" }

sub _prefetch {
    my $self = shift;
    my ($data) = @_;
}

1;
