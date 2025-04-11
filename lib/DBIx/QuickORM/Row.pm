package DBIx::QuickORM::Row;
use strict;
use warnings;

use Carp qw/confess croak/;
use Scalar::Util qw/reftype blessed/;
use DBIx::QuickORM::Affinity();

our $VERSION = '0.000005';

use DBIx::QuickORM::Util::HashBase qw{
    +stored
    +pending
    +desync
    +invalid
    +connection
    +sqla_source
};

sub track_desync { 1 }

sub sqla_source { $_[0]->{+SQLA_SOURCE}->() }
sub connection  { $_[0]->{+CONNECTION}->() }
sub dialect     { $_[0]->connection->dialect }

sub stored_data   { $_[0]->{+STORED} }
sub pending_data  { $_[0]->{+PENDING} }
sub desynced_data { $_[0]->{+DESYNC} }

sub is_invalid  { $_[0]->{+INVALID} ? 1 : 0 }
sub is_valid    { $_[0]->{+INVALID} ? 0 : 1 }
sub is_stored   { $_[0]->{+STORED}  ? 1 : 0 }
sub is_desynced { $_[0]->{+DESYNC}  ? 1 : 0 }
sub has_pending { $_[0]->{+PENDING} ? 1 : 0 }

sub has_field      { $_[0]->sqla_source->has_field($_[1] // croak "Must specify a field name") }
sub field_affinity { $_[0]->sqla_source->field_affinity($_[1], $_[0]->dialect) }

#<<<
sub primary_key_field_list { @{$_[0]->sqla_source->primary_key // []} }
sub primary_key_value_list { map { $_[0]->raw_stored_field($_) // undef } $_[0]->primary_key_field_list }
sub primary_key_hash       { map { $_ => $_[0]->raw_stored_field($_) // undef } $_[0]->primary_key_field_list }
sub primary_key_hashref    { +{ $_[0]->primary_key_hash } }
#>>>

sub init {
    my $self = shift;

    my $src = $self->{+SQLA_SOURCE} or confess "'sqla_source' is required";
    my $con = $self->{+CONNECTION}  or confess "'connection' is required";

    my ($src_sub, $src_obj);
    if ((reftype($src) // '') eq 'CODE') {
        $src_sub = $src;
        $src_obj = $src_sub->();
    }
    else {
        $src_obj = $src;
        $src_sub = sub { $src_obj };
    }

    croak "'sqla_source' must be either a blessed object that consumes the role 'DBIx::QuickORM::Role::SQLASource', or a coderef that returns such an object"
        unless $src_obj && blessed($src_obj) && $src_obj->DOES('DBIx::QuickORM::Role::SQLASource');

    my ($con_sub, $con_obj);
    if ((reftype($con) // '') eq 'CODE') {
        $con_sub = $con;
        $con_obj = $con_sub->();
    }
    else {
        $con_obj = $con;
        $con_sub = sub { $con_obj };
    }

    croak "'connection' must be either a blessed instance of 'DBIx::QuickORM::Connection', or a coderef that returns such an object"
        unless $con_obj && blessed($con_obj) && $con_obj->isa('DBIx::QuickORM::Connection');

    $self->{+CONNECTION}  = $con_sub;
    $self->{+SQLA_SOURCE} = $src_sub;
}

sub source {
    my $self = shift;

    use DBIx::QuickORM::Util qw/debug/;

    require DBIx::QuickORM::Source;
    return DBIx::QuickORM::Source->new(
        SQLA_SOURCE() => $self->sqla_source,
        CONNECTION()  => $self->connection,
    );
}

############################
# {{{ Manipulation Methods #
############################

sub check_row {
    my $self = shift;

    croak "This row has been invalidated in cache, it needs to be re-fetched" if $self->{+INVALID};
}

sub check_pk {
    my $self = shift;
    return if $self->sqla_source->primary_key;

    croak "Operation not allowed: the table this row is from does not have a primary key";
}

sub check_sync {
    my $self = shift;

    return unless $self->track_desync;

    return unless $self->{+DESYNC};

    croak <<"    EOT";
This row is out of sync, this means it was refreshed while it had pending
changes and the data retrieved from the database does not match what was in
place when the pending changes were set.

To fix such conditions you need to either use row->discard() to clear the
pending changes, or you need to call ->force_sync() to clear the desync flags
allowing you to save the row despite the discrepency.
    EOT

}

sub force_sync {
    my $self = shift;

    delete $self->{+DESYNC};

    return;
}

sub insert_or_save {
    my $self = shift;

    return $self->save(@_)   if $self->{+STORED};
    return $self->insert(@_) if $self->{+PENDING};
}

sub insert {
    my $self = shift;

    $self->check_row;

    croak "This row is already in the database" if $self->{+STORED};
    croak "This row has no data to write" unless $self->{+PENDING} && keys %{$self->{+PENDING}};

    $self->connection->insert($self->sqla_source, $self);

    return $self;
}

sub save {
    my $self = shift;
    my %params = @_;

    $self->check_row;
    $self->check_sync;
    $self->check_pk;

    croak "This row is not in the database yet" unless $self->{+STORED};

    my $pk = $self->sqla_source->primary_key or croak "Cannot use 'save()' on a row with a source that has no primary key";

    return 0 unless $self->{+PENDING};

    $self->connection->update($self->sqla_source, $self);

    return 1;
}

# Fetch new data from the db
sub refresh {
    my $self = shift;

    $self->check_row;
    $self->check_pk;

    croak "This row is not in the database yet" unless $self->{+STORED};

    return $self->connection->first($self->sqla_source, {where => $self->primary_key_hashref, fields => [keys %{$self->{+STORED}}], row => $self});
}

# Remove pending changes (and clear desync)
sub discard {
    my $self = shift;

    $self->_check_row;

    if (@_) {
        for my $field (@_) {
            delete $self->{+DESYNC}->{$field};
            delete $self->{+PENDING}->{$field};
        }

        delete $self->{+DESYNC}  unless keys %{$self->{+DESYNC}};
        delete $self->{+PENDING} unless keys %{$self->{+PENDING}};
    }
    else {
        delete $self->{+DESYNC};
        delete $self->{+PENDING};
    }

    return;
}

sub update {
    my $self = shift;
    my ($changes, %params) = @_;

    $self->check_row;
    $self->check_pk;

    $self->{+PENDING} = { %{$self->{+PENDING} // {}}, %$changes };

    $self->save(%params);
}

sub delete {
    my $self = shift;
    $self->check_row;
    $self->check_pk;

    $self->connection->delete($self->sqla_source, $self);
}

############################
# }}} Manipulation Methods #
############################

#####################
# {{{ Field methods #
#####################

sub field     { shift->_field(_inflated_field => @_) }
sub raw_field { shift->_field(_raw_field      => @_) }

sub fields         { $_[0]->_fields(_field => $_[0]->{+PENDING}, $_[0]->{+STORED}) }
sub stored_field   { $_[0]->_inflated_field($_[0]->{+STORED}, $_[1]) }
sub stored_fields  { $_[0]->_fields(_field => $_[0]->{+STORED}) }
sub pending_field  { $_[0]->_inflated_field($_[0]->{+PENDING}, $_[1]) }
sub pending_fields { $_[0]->_fields(_field => $_[0]->{+PENDING}) }

sub raw_fields         { $_[0]->_fields(_raw_field => $_[0]->{+PENDING}, $_[0]->{+STORED}) }
sub raw_stored_field   { $_[0]->_raw_field($_[0]->{+STORED}, $_[1]) }
sub raw_stored_fields  { $_[0]->_fields(_raw_field => $_[0]->{+STORED}) }
sub raw_pending_field  { $_[0]->_raw_field($_[0]->{+PENDING}, $_[1]) }
sub raw_pending_fields { $_[0]->_fields(_raw_field => $_[0]->{+PENDING}) }

sub field_is_desynced {
    my $self = shift;
    my ($field) = @_;

    croak "You must specify a field name" unless @_;

    return 0 unless $self->{+DESYNC};
    return $self->{+DESYNC}->{$field} // 0;
}

sub _field {
    my $self = shift;
    my $meth = shift;
    my $field = shift or croak "Must specify a field name";

    croak "This row does not have a '$field' field" unless $self->has_field($field);

    $self->{+PENDING}->{$field} = shift if @_;

    return $self->$meth($self->{+PENDING}, $field) if $self->{+PENDING} && exists $self->{+PENDING}->{$field};

    if (my $st = $self->{+STORED}) {
        unless (exists $st->{$field}) {
            my $data = $self->connection->data_one($self->sqla_source, {where => $self->primary_key_hashref, fields => [$field]});
            $st->{$field} = $data->{$field};
        }

        return $self->$meth($st, $field);
    }

    return undef;
}

sub _fields {
    my $self = shift;
    my $meth = shift;

    my %out;
    for my $hr (@_) {
        next unless $hr;

        for my $field (keys %$hr) {
            $out{$field} //= $self->$meth($hr, $field);
        }
    }

    return \%out;
}

sub _inflated_field {
    my $self = shift;
    my ($from, $field) = @_;

    croak "This row does not have a '$field' field" unless $self->has_field($field);

    return undef unless $from;
    return undef unless exists $from->{$field};

    my $val = $from->{$field};

    return $val if ref($val);    # Inflated already

    if (my $type = $self->sqla_source->field_type($field)) {
        return $from->{$field} = $type->qorm_inflate($val);
    }

    return $from->{$field};
}

sub _raw_field {
    my $self = shift;
    my ($from, $field) = @_;

    croak "This row does not have a '$field' field" unless $self->has_field($field);

    return undef unless $from;
    return undef unless exists $from->{$field};
    my $val = $from->{$field};

    return $val->qorm_deflate($self->field_affinity($field))
        if blessed($val) && $val->can('qorm_deflate');

    if (my $type = $self->sqla_source->field_type($field)) {
        return $type->qorm_deflate($val, $self->field_affinity($field));
    }

    return $val;
}

#####################
# }}} Field methods #
#####################

1;
